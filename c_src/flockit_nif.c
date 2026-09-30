// flockit_nif.c - advisory file locks via flock(2).
//
// Locks are only ever attempted with LOCK_NB, so no thread ever blocks in
// flock(). A caller that has to wait registers its lock for release
// notifications and retries whenever the kernel reports that the file may
// have been unlocked:
//
//   macOS  kqueue EVFILT_VNODE / NOTE_FUNLOCK, raised whenever a flock lock
//          on the file is released, including by close() and process exit.
//   Linux  inotify IN_CLOSE_WRITE / IN_CLOSE_NOWRITE, raised whenever a
//          descriptor for the file is closed, including at process exit. An
//          explicit LOCK_UN that keeps the descriptor open raises nothing.
//
// One notify descriptor serves the whole VM. The Flockit.Notifier process
// watches it with enif_select. Watched locks are grouped into one watch per
// kernel watch id; an event marks its watch pending, and each drain call
// messages a bounded number of the pending watches' locks, resuming where it
// left off on the next call. Callers also retry on a fallback timer, so
// notifications only ever affect latency, never correctness.
//
// The notifier also closes descriptors for locks ended by an owner exiting
// or a handle being garbage collected, so that unlocking, which can take a
// network round trip, never runs in those callbacks on a normal scheduler.
//
// Everything that outlives a call is in one state_t, so that a new version
// of the library, loaded over a running one as a separate instance, can adopt
// it in upgrade and take over both resource types. The notifier, its select,
// the registry and the close queue carry on unchanged.
//
// Locking order: lock_t.mtx before registry_mtx.

#define _GNU_SOURCE
#include <erl_nif.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#if defined(__APPLE__)
#define NOTIFY_KQUEUE 1
#include <sys/event.h>
#elif defined(__linux__)
#define NOTIFY_INOTIFY 1
#include <sys/inotify.h>
#endif

// Work per drain call, bounding time spent on a normal scheduler and holding
// registry_mtx: kernel events read, and steps (locks visited or hash slots
// scanned) spent delivering them.
#define DRAIN_EVENTS 64
#define DRAIN_STEPS 256
#if defined(NOTIFY_INOTIFY)
// Watches are on files, so events carry no name; the slack still fits one
// named event, which would otherwise make read() fail with EINVAL.
#define INOTIFY_BUF (DRAIN_EVENTS * sizeof(struct inotify_event) + NAME_MAX + 1)
#endif

// Descriptors closed per close_pending call.
#define CLOSE_BATCH 64

typedef enum {
    ST_OPEN,      // fd open, lock not held
    ST_HELD,      // fd holds the lock
    ST_RELEASED,  // fd closed
} lock_state_t;

typedef struct closing {
    int fd;
    struct closing* next;
} closing_t;

typedef struct lock lock_t;
typedef struct watch watch_t;
typedef struct kind kind_t;

struct lock {
    ErlNifMutex* mtx;  // guards fd, state and monitored
    int fd;
    int op;  // LOCK_EX or LOCK_SH
    lock_state_t state;
    int monitored;
    ErlNifPid owner;  // immutable once set
    ErlNifMonitor mon;
    closing_t* spare;  // close queue entry for a descriptor ended in a callback
    kind_t* kind;      // the lock's resource type

    // Guarded by registry_mtx. A watched lock is on its watch's list, and the
    // registry holds a reference to it.
    watch_t* watch;
    lock_t* wprev;
    lock_t* wnext;
    int notified;  // a flockit_released message is outstanding
};

// The locks sharing one kernel watch id: on Linux all locks on one file, on
// macOS a single lock. Guarded by registry_mtx.
struct watch {
    intptr_t id;
    lock_t* locks;
    lock_t* cursor;  // next lock to message while pending
    int pending;     // on the pending queue
    int rescan;      // another event arrived mid-pass
    int dead;        // no locks left; freed when it leaves the queue
    watch_t* hnext;  // hash chain
    watch_t* qnext;  // pending queue
};

typedef struct {
    int fd;
} notifier_t;

// A lock resource type and its live locks. Reloading the module after a purge
// opens a new type, but locks of the old one live on, so each type is kept
// until its last lock is gone. Guarded by registry_mtx.
struct kind {
    ErlNifResourceType* type;
    size_t locks;
    kind_t* next;
};

// Bump whenever the layout or meaning of state_t, or of anything it reaches,
// changes. An upgrade only adopts the state of a library with the same layout
// version, and otherwise refuses, leaving the old version running.
// Overridable only so that tests can build a library with another layout.
#ifndef LAYOUT_VERSION
#define LAYOUT_VERSION 1
#endif

// Everything that must outlive one instance of this library. An upgrade loads
// the new library as a separate instance with fresh globals and hands this
// over as priv_data, so nothing here may point into the library itself.
typedef struct {
    unsigned version;  // LAYOUT_VERSION; stays the first member in every layout
    ErlNifMutex* registry_mtx;

    // Everything below is guarded by registry_mtx.
    kind_t* kinds;                      // newest first
    notifier_t* anchor;                 // never released, see acquire_nif
    notifier_t* notifier;               // created once, kept for the life of the VM
    ErlNifResourceType* notifier_kind;  // the type notifier was created with
    watch_t** table;                    // hash of watches by id
    size_t table_size;
    size_t nwatches;
    watch_t* queue_head;  // pending watches, oldest first
    watch_t* queue_tail;
    int overflowed;  // every watch must be marked pending
    size_t overflow_slot;
    int nwatched;
    intptr_t next_watch_id;  // kqueue only

    // Descriptors waiting for the notifier to close them, oldest first.
    closing_t* closing;
    closing_t* closing_tail;
    int close_signalled;
    int attached;
    ErlNifPid attached_pid;
} state_t;

// The state, shared by every instance of this library in the VM, and this
// instance's resource types.
static state_t* st = NULL;
static ErlNifResourceType* lock_type = NULL;
static kind_t* lock_kind = NULL;
static ErlNifResourceType* notifier_type = NULL;
static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_busy;
static ERL_NIF_TERM atom_more;
static ERL_NIF_TERM atom_flock_released;
static ERL_NIF_TERM atom_flock_close;
static ERL_NIF_TERM atom_true;
static ERL_NIF_TERM atom_false;
static ERL_NIF_TERM atom_noproc;
static ERL_NIF_TERM atom_unavailable;
static ERL_NIF_TERM atom_undefined;

static const char* errno_name(int err) {
    switch (err) {
    case EACCES: return "eacces";
    case EAGAIN: return "eagain";
#if EWOULDBLOCK != EAGAIN
    case EWOULDBLOCK: return "eagain";
#endif
    case EBADF: return "ebadf";
    case EDEADLK: return "edeadlk";
    case EDQUOT: return "edquot";
    case EEXIST: return "eexist";
    case EFBIG: return "efbig";
    case EINTR: return "eintr";
    case EINVAL: return "einval";
    case EIO: return "eio";
    case EISDIR: return "eisdir";
    case ELOOP: return "eloop";
    case EMFILE: return "emfile";
    case ENAMETOOLONG: return "enametoolong";
    case ENFILE: return "enfile";
    case ENOENT: return "enoent";
    case ENOLCK: return "enolck";
    case ENOMEM: return "enomem";
    case ENOSPC: return "enospc";
    case ENOTDIR: return "enotdir";
    case ENOTSUP: return "enotsup";
#if EOPNOTSUPP != ENOTSUP
    case EOPNOTSUPP: return "enotsup";
#endif
    case ENXIO: return "enxio";
    case EOVERFLOW: return "eoverflow";
    case EPERM: return "eperm";
    case EROFS: return "erofs";
    case ETXTBSY: return "etxtbsy";
    default: return "unknown";
    }
}

static ERL_NIF_TERM make_errno(ErlNifEnv* env, int err) {
    return enif_make_tuple2(env, atom_error, enif_make_atom(env, errno_name(err)));
}

static void unlock_fd(int fd) {
    if (fd >= 0) {
        flock(fd, LOCK_UN);
        close(fd);
    }
}

// Closing

// Under registry_mtx. Queues fd, with its preallocated entry c, for unlocking
// and closing on a dirty scheduler, and tells the notifier if it is not
// already busy with the queue. Never blocks, so it is safe in resource
// callbacks. Without a notifier the queue is emptied by the next attach, or a
// little at a time by the library's own dirty calls (see close_some).
static void queue_close(ErlNifEnv* env, int fd, closing_t* c) {
    c->fd = fd;
    c->next = NULL;
    if (st->closing_tail != NULL) {
        st->closing_tail->next = c;
    } else {
        st->closing = c;
    }
    st->closing_tail = c;
    if (st->attached && !st->close_signalled && env != NULL) {
        if (enif_send(env, &st->attached_pid, NULL, atom_flock_close)) {
            st->close_signalled = 1;
        } else {
            st->attached = 0;  // the notifier has gone; its successor re-attaches
        }
    }
}

static void dispose_fd(ErlNifEnv* env, int fd, closing_t* c) {
    enif_mutex_lock(st->registry_mtx);
    queue_close(env, fd, c);
    enif_mutex_unlock(st->registry_mtx);
}

// Unlocks and closes up to max queued descriptors, oldest first. Returns
// whether any remain. Call only on a dirty scheduler.
static int close_some(int max) {
    int fds[CLOSE_BATCH];
    int count = 0;
    if (max > CLOSE_BATCH) max = CLOSE_BATCH;

    enif_mutex_lock(st->registry_mtx);
    while (st->closing != NULL && count < max) {
        closing_t* c = st->closing;
        st->closing = c->next;
        if (st->closing == NULL) st->closing_tail = NULL;
        fds[count++] = c->fd;
        enif_free(c);
    }
    int more = st->closing != NULL;
    if (!more) st->close_signalled = 0;
    enif_mutex_unlock(st->registry_mtx);

    for (int i = 0; i < count; i++) unlock_fd(fds[i]);
    return more;
}

// From the library's dirty calls: with no notifier to empty the close queue,
// each call takes a small share of it.
static void help_close(void) {
    enif_mutex_lock(st->registry_mtx);
    int unattended = !st->attached && st->closing != NULL;
    enif_mutex_unlock(st->registry_mtx);
    if (unattended) close_some(8);
}

// Watch table

static size_t slot_of(intptr_t id, size_t size) {
    return ((uint64_t)id * 0x9E3779B97F4A7C15ull) >> 32 & (size - 1);
}

static watch_t* find_watch(intptr_t id) {
    if (st->table == NULL) return NULL;
    for (watch_t* w = st->table[slot_of(id, st->table_size)]; w != NULL; w = w->hnext) {
        if (w->id == id) return w;
    }
    return NULL;
}

static int grow_table(void) {
    size_t size = st->table_size == 0 ? 64 : st->table_size * 2;
    watch_t** grown = enif_alloc(size * sizeof(watch_t*));
    if (grown == NULL) return 0;
    memset(grown, 0, size * sizeof(watch_t*));
    for (size_t i = 0; i < st->table_size; i++) {
        for (watch_t *w = st->table[i], *next; w != NULL; w = next) {
            next = w->hnext;
            size_t s = slot_of(w->id, size);
            w->hnext = grown[s];
            grown[s] = w;
        }
    }
    if (st->table != NULL) enif_free(st->table);
    st->table = grown;
    st->table_size = size;
    st->overflow_slot = 0;  // slots moved; rescan from the start
    return 1;
}

static watch_t* add_to_watch(intptr_t id) {
    watch_t* w = find_watch(id);
    if (w != NULL) return w;
    if (st->nwatches >= st->table_size && !grow_table()) return NULL;
    if ((w = enif_alloc(sizeof(watch_t))) == NULL) return NULL;
    memset(w, 0, sizeof(watch_t));
    w->id = id;
    size_t s = slot_of(id, st->table_size);
    w->hnext = st->table[s];
    st->table[s] = w;
    st->nwatches++;
    return w;
}

static void unhash_watch(watch_t* w) {
    watch_t** p = &st->table[slot_of(w->id, st->table_size)];
    while (*p != w) p = &(*p)->hnext;
    *p = w->hnext;
    st->nwatches--;
}

// Marks w for delivery. A watch already being delivered gets another full
// pass afterwards, so every lock is visited after every event.
static void mark_pending(watch_t* w) {
    if (w->pending) {
        w->rescan = 1;
        return;
    }
    w->pending = 1;
    w->cursor = w->locks;
    w->qnext = NULL;
    if (st->queue_tail != NULL) {
        st->queue_tail->qnext = w;
    } else {
        st->queue_head = w;
    }
    st->queue_tail = w;
}

static watch_t* dequeue(void) {
    watch_t* w = st->queue_head;
    st->queue_head = w->qnext;
    if (st->queue_head == NULL) st->queue_tail = NULL;
    w->pending = 0;
    return w;
}

// Registration

// Under l->mtx (l->fd is open) and registry_mtx.
static int add_watch(lock_t* l) {
    if (st->notifier == NULL) return 0;
    intptr_t id;
#if defined(NOTIFY_KQUEUE)
    struct kevent ev;
    id = st->next_watch_id++;
    EV_SET(&ev, l->fd, EVFILT_VNODE, EV_ADD | EV_CLEAR, NOTE_FUNLOCK, 0, (void*)id);
    if (kevent(st->notifier->fd, &ev, 1, NULL, 0, NULL) != 0) return 0;
#elif defined(NOTIFY_INOTIFY)
    // Watching the open descriptor's /proc link pins the watch to the file we
    // opened, even if the path has since been renamed or replaced.
    char link[64];
    snprintf(link, sizeof(link), "/proc/self/fd/%d", l->fd);
    int wd = inotify_add_watch(st->notifier->fd, link, IN_CLOSE_WRITE | IN_CLOSE_NOWRITE);
    if (wd < 0) return 0;
    id = wd;
#else
    return 0;
#endif

    watch_t* w = add_to_watch(id);
    if (w == NULL) {
#if defined(NOTIFY_KQUEUE)
        EV_SET(&ev, l->fd, EVFILT_VNODE, EV_DELETE, 0, 0, NULL);
        kevent(st->notifier->fd, &ev, 1, NULL, 0, NULL);
#elif defined(NOTIFY_INOTIFY)
        // A missing watch means no other lock shares the kernel watch.
        inotify_rm_watch(st->notifier->fd, wd);
#endif
        return 0;
    }
    // Added ahead of any pass in progress: the caller's next attempt covers
    // releases before now.
    l->watch = w;
    l->wprev = NULL;
    l->wnext = w->locks;
    if (w->locks != NULL) w->locks->wprev = l;
    w->locks = l;
    l->notified = 0;
    st->nwatched++;
    return 1;
}

// Under l->mtx (l->fd is open) and registry_mtx. Returns whether l was
// watched, in which case the caller must drop the registry's reference to l
// once both mutexes are released.
static int remove_watch(lock_t* l) {
    watch_t* w = l->watch;
    if (w == NULL) return 0;

    if (w->cursor == l) w->cursor = l->wnext;
    if (l->wprev != NULL) {
        l->wprev->wnext = l->wnext;
    } else {
        w->locks = l->wnext;
    }
    if (l->wnext != NULL) l->wnext->wprev = l->wprev;
    l->watch = NULL;
    l->wprev = l->wnext = NULL;
    st->nwatched--;

#if defined(NOTIFY_KQUEUE)
    struct kevent ev;
    EV_SET(&ev, l->fd, EVFILT_VNODE, EV_DELETE, 0, 0, NULL);
    kevent(st->notifier->fd, &ev, 1, NULL, 0, NULL);
#endif
    if (w->locks == NULL) {
#if defined(NOTIFY_INOTIFY)
        inotify_rm_watch(st->notifier->fd, (int)w->id);
#endif
        unhash_watch(w);
        if (w->pending) {
            w->dead = 1;
        } else {
            enif_free(w);
        }
    }
    return 1;
}

// Under l->mtx.
static int unwatch(lock_t* l) {
    enif_mutex_lock(st->registry_mtx);
    int had = remove_watch(l);
    enif_mutex_unlock(st->registry_mtx);
    return had;
}

// Ends l for good: unregisters it and closes its descriptor. Safe to call
// more than once and from any thread. From a resource callback the
// descriptor goes to the notifier, since unlocking may block.
static void end_lock(ErlNifEnv* env, lock_t* l, int in_callback) {
    enif_mutex_lock(l->mtx);
    int had = unwatch(l);
    int fd = l->fd;
    l->fd = -1;
    l->state = ST_RELEASED;
    int monitored = l->monitored;
    l->monitored = 0;
    closing_t* spare = NULL;
    if (in_callback && fd >= 0) {
        spare = l->spare;
        l->spare = NULL;
    }
    enif_mutex_unlock(l->mtx);

    if (in_callback) {
        if (fd >= 0) dispose_fd(env, fd, spare);
    } else {
        unlock_fd(fd);
        if (monitored) enif_demonitor_process(env, l, &l->mon);
    }
    if (had) enif_release_resource(l);
}

// Lock types

// Under registry_mtx. Makes type the one new locks are created with.
static kind_t* adopt_kind(ErlNifResourceType* type) {
    kind_t* newest = st->kinds;
    if (newest != NULL && newest->type == type) return newest;  // taken over
    kind_t* k = enif_alloc(sizeof(kind_t));
    if (k == NULL) return NULL;
    k->type = type;
    k->locks = 0;
    k->next = newest;
    st->kinds = k;
    if (newest != NULL && newest->locks == 0) {
        k->next = newest->next;
        enif_free(newest);
    }
    return k;
}

// Under registry_mtx. Drops a lock of kind k, and k itself once it is
// superseded and has no locks left, before ERTS frees its type.
static void release_kind(kind_t* k) {
    if (--k->locks > 0 || k == st->kinds) return;
    kind_t** p = &st->kinds;
    while (*p != k) p = &(*p)->next;
    *p = k->next;
    enif_free(k);
}

// Resource callbacks

static void lock_dtor(ErlNifEnv* env, void* obj) {
    lock_t* l = obj;
    if (l->mtx != NULL) enif_mutex_destroy(l->mtx);
    if (l->fd < 0 && l->spare != NULL) enif_free(l->spare);

    // The registry holds a reference while l is watched, so it is not here.
    enif_mutex_lock(st->registry_mtx);
    if (l->fd >= 0) queue_close(env, l->fd, l->spare);
    if (l->kind != NULL) release_kind(l->kind);
    enif_mutex_unlock(st->registry_mtx);
}

static void lock_down(ErlNifEnv* env, void* obj, ErlNifPid* pid, ErlNifMonitor* mon) {
    // The VM holds its own reference to obj for the duration of the callback.
    end_lock(env, obj, 1);
}

static void notifier_stop(ErlNifEnv* env, void* obj, ErlNifEvent event, int is_direct_call) {
    // The notifier is never deselected, so this does not run in practice.
}

// NIFs

static int get_bool(ERL_NIF_TERM term, int* out) {
    if (enif_is_identical(term, atom_true)) {
        *out = 1;
        return 1;
    }
    if (enif_is_identical(term, atom_false)) {
        *out = 0;
        return 1;
    }
    return 0;
}

static int get_lock(ErlNifEnv* env, ERL_NIF_TERM term, lock_t** l) {
    if (enif_get_resource(env, term, lock_type, (void**)l)) return 1;

    // Locks from before a purge and reload of the module have an older type.
    // Each kind in the list has live locks, so its type has not been freed.
    int found = 0;
    enif_mutex_lock(st->registry_mtx);
    for (kind_t* k = st->kinds; k != NULL && !found; k = k->next) {
        found = k->type != lock_type && enif_get_resource(env, term, k->type, (void**)l);
    }
    enif_mutex_unlock(st->registry_mtx);
    return found;
}

// Drops a lock that acquire_nif could not finish setting up. This runs on a
// dirty scheduler, so the descriptor is closed here rather than queued.
static void abandon(lock_t* l) {
    unlock_fd(l->fd);
    l->fd = -1;
    enif_release_resource(l);
}

// acquire(Path, Exclusive) -> {ok, Lock} | {busy, Lock} | {error, Reason}
//
// Opens Path and makes one non-blocking attempt. A busy Lock keeps the file
// open for further attempts with try/1.
static ERL_NIF_TERM acquire_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary path;
    int exclusive;
    if (argc != 2 || !enif_inspect_binary(env, argv[0], &path) || !get_bool(argv[1], &exclusive)) {
        return enif_make_badarg(env);
    }
    help_close();
    if (memchr(path.data, '\0', path.size) != NULL) return make_errno(env, EINVAL);

    char* cpath = enif_alloc(path.size + 1);
    if (cpath == NULL) return make_errno(env, ENOMEM);
    memcpy(cpath, path.data, path.size);
    cpath[path.size] = '\0';

    // Exclusive locks open for writing because NFS emulates flock() with
    // byte-range locks, which require it. O_NONBLOCK stops opening a FIFO
    // from waiting for a peer; it has no effect on flock().
    int oflags = (exclusive ? O_RDWR : O_RDONLY) | O_CREAT | O_CLOEXEC | O_NOCTTY | O_NONBLOCK;
    int fd;
    do {
        fd = open(cpath, oflags, 0666);
    } while (fd < 0 && errno == EINTR);
    int err = errno;
    enif_free(cpath);
    if (fd < 0) return make_errno(env, err);

    // Only regular files are lockable. Linux refuses O_CREAT on a directory
    // but macOS does not, so directories are rejected explicitly too.
    struct stat sb;
    if (fstat(fd, &sb) != 0) {
        err = errno;
        close(fd);
        return make_errno(env, err);
    }
    if (!S_ISREG(sb.st_mode)) {
        close(fd);
        return make_errno(env, S_ISDIR(sb.st_mode) ? EISDIR : EINVAL);
    }

    int op = exclusive ? LOCK_EX : LOCK_SH;
    int rc;
    do {
        rc = flock(fd, op | LOCK_NB);
    } while (rc != 0 && errno == EINTR);
    if (rc != 0 && errno != EWOULDBLOCK) {
        err = errno;
        close(fd);
        return make_errno(env, err);
    }

    // Allocated now so that ending the lock in a callback never allocates.
    closing_t* spare = enif_alloc(sizeof(closing_t));
    if (spare == NULL) {
        close(fd);
        return make_errno(env, ENOMEM);
    }

    lock_t* l = enif_alloc_resource(lock_type, sizeof(lock_t));
    memset(l, 0, sizeof(lock_t));
    l->fd = fd;
    l->op = op;
    l->state = rc == 0 ? ST_HELD : ST_OPEN;
    l->spare = spare;
    enif_mutex_lock(st->registry_mtx);
    l->kind = lock_kind;
    lock_kind->locks++;
    // A resource of a type with callbacks keeps the library loaded. Once a
    // lock exists, this one ensures a purge never unloads the library, and st
    // with it, while descriptors may still be queued for closing, even when
    // there is no notifier.
    if (st->anchor == NULL) {
        st->anchor = enif_alloc_resource(notifier_type, sizeof(notifier_t));
        st->anchor->fd = -1;
    }
    enif_mutex_unlock(st->registry_mtx);

    l->mtx = enif_mutex_create("flockit_lock");
    if (l->mtx == NULL) {
        abandon(l);
        return make_errno(env, ENOMEM);
    }
    if (!enif_self(env, &l->owner)) {
        abandon(l);
        return enif_make_badarg(env);
    }
    // A dirty NIF can outlive a kill of its caller; don't hand a lock to a
    // process that is already exiting.
    if (enif_monitor_process(env, l, &l->owner, &l->mon) != 0) {
        abandon(l);
        return enif_make_tuple2(env, atom_error, atom_noproc);
    }
    l->monitored = 1;

    ERL_NIF_TERM handle = enif_make_resource(env, l);
    enif_release_resource(l);
    return enif_make_tuple2(env, rc == 0 ? atom_ok : atom_busy, handle);
}

// try(Lock) -> ok | {error, Reason}
//
// Another non-blocking attempt on a busy Lock. Success unregisters it, so
// once this returns no further {flockit_released, Lock} message will be sent.
static ERL_NIF_TERM try_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    lock_t* l;
    if (argc != 1 || !get_lock(env, argv[0], &l)) return enif_make_badarg(env);
    help_close();

    int rc, err = 0, had = 0;
    enif_mutex_lock(l->mtx);

    // Re-enable notifications before attempting, so that a release after
    // this attempt fails still produces a message.
    enif_mutex_lock(st->registry_mtx);
    l->notified = 0;
    enif_mutex_unlock(st->registry_mtx);

    if (l->state == ST_HELD) {
        rc = 0;
    } else if (l->state == ST_RELEASED) {
        rc = -1;
        err = EBADF;
    } else {
        do {
            rc = flock(l->fd, l->op | LOCK_NB);
        } while (rc != 0 && errno == EINTR);
        err = rc != 0 ? errno : 0;
        if (rc == 0) {
            l->state = ST_HELD;
            had = unwatch(l);
        }
    }
    enif_mutex_unlock(l->mtx);

    if (had) enif_release_resource(l);
    return rc == 0 ? atom_ok : make_errno(env, err);
}

// watch(Lock) -> ok | unavailable
//
// Registers a busy Lock so that its owner is sent {flockit_released, Lock}
// whenever the file may have been unlocked. unavailable means only the
// caller's fallback retries will notice a release.
static ERL_NIF_TERM watch_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    lock_t* l;
    if (argc != 1 || !get_lock(env, argv[0], &l)) return enif_make_badarg(env);

    int ok = 0;
    enif_mutex_lock(l->mtx);
    if (l->state == ST_OPEN) {
        enif_mutex_lock(st->registry_mtx);
        ok = l->watch != NULL;
        if (!ok && add_watch(l)) {
            enif_keep_resource(l);
            ok = 1;
        }
        enif_mutex_unlock(st->registry_mtx);
    }
    enif_mutex_unlock(l->mtx);
    return ok ? atom_ok : atom_unavailable;
}

// release(Lock) -> ok. Idempotent, and may be called from any process.
static ERL_NIF_TERM release_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    lock_t* l;
    if (argc != 1 || !get_lock(env, argv[0], &l)) return enif_make_badarg(env);
    help_close();
    end_lock(env, l, 0);  // argv[0] keeps l alive
    return atom_ok;
}

// notifier() -> {ok, Notifier} | {error, Reason}
//
// The VM-wide notify descriptor, created on first use and never closed.
static ERL_NIF_TERM notifier_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
#if defined(NOTIFY_KQUEUE) || defined(NOTIFY_INOTIFY)
    ERL_NIF_TERM result;
    enif_mutex_lock(st->registry_mtx);
    if (st->notifier == NULL) {
#if defined(NOTIFY_KQUEUE)
        int fd = kqueue();
        if (fd >= 0) fcntl(fd, F_SETFD, FD_CLOEXEC);
#else
        int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
#endif
        if (fd < 0) {
            int err = errno;
            enif_mutex_unlock(st->registry_mtx);
            return make_errno(env, err);
        }
        // The reference from enif_alloc_resource is never released.
        st->notifier = enif_alloc_resource(notifier_type, sizeof(notifier_t));
        st->notifier->fd = fd;
        st->notifier_kind = notifier_type;
    }
    result = enif_make_tuple2(env, atom_ok, enif_make_resource(env, st->notifier));
    enif_mutex_unlock(st->registry_mtx);
    return result;
#else
    return make_errno(env, ENOTSUP);
#endif
}

// Under registry_mtx. Reads one batch of kernel events, marking their
// watches pending. Returns whether the batch was full.
static int read_events(notifier_t* n) {
#if defined(NOTIFY_KQUEUE)
    struct kevent evs[DRAIN_EVENTS];
    struct timespec zero = {0, 0};
    int count = kevent(n->fd, NULL, 0, evs, DRAIN_EVENTS, &zero);
    for (int i = 0; i < count; i++) {
        watch_t* w = find_watch((intptr_t)evs[i].udata);
        if (w != NULL) mark_pending(w);
    }
    return count == DRAIN_EVENTS;
#elif defined(NOTIFY_INOTIFY)
    char buf[INOTIFY_BUF] __attribute__((aligned(__alignof__(struct inotify_event))));
    ssize_t len;
    do {
        len = read(n->fd, buf, sizeof(buf));
    } while (len < 0 && errno == EINTR);
    for (char* p = buf; len > 0 && p < buf + len;) {
        struct inotify_event* ev = (struct inotify_event*)p;
        if (ev->mask & IN_Q_OVERFLOW) {
            // Events were lost, so any watched file may have been released.
            st->overflowed = 1;
            st->overflow_slot = 0;
        } else {
            // IN_IGNORED means a watch went away; its locks are woken to fall
            // back to retrying.
            watch_t* w = find_watch(ev->wd);
            if (w != NULL) mark_pending(w);
        }
        p += sizeof(struct inotify_event) + ev->len;
    }
    return len >= (ssize_t)(DRAIN_EVENTS * sizeof(struct inotify_event));
#else
    return 0;
#endif
}

// Under registry_mtx. Spends up to DRAIN_STEPS marking watches pending after
// an overflow and messaging the locks of pending watches. Returns whether
// work remains.
static int deliver(ErlNifEnv* env) {
    int steps = DRAIN_STEPS;

    while (st->overflowed && steps > 0) {
        if (st->overflow_slot >= st->table_size) {
            st->overflowed = 0;
            break;
        }
        for (watch_t* w = st->table[st->overflow_slot]; w != NULL; w = w->hnext) mark_pending(w);
        st->overflow_slot++;
        steps--;
    }

    while (st->queue_head != NULL && steps > 0) {
        watch_t* w = st->queue_head;
        if (w->dead) {
            enif_free(dequeue());
            steps--;
            continue;
        }
        while (w->cursor != NULL && steps > 0) {
            lock_t* l = w->cursor;
            w->cursor = l->wnext;
            steps--;
            if (l->notified) continue;
            l->notified = 1;
            ERL_NIF_TERM msg = enif_make_tuple2(env, atom_flock_released, enif_make_resource(env, l));
            enif_send(env, &l->owner, NULL, msg);
        }
        if (w->cursor != NULL) break;  // out of steps mid-watch
        dequeue();
        if (w->rescan) {
            w->rescan = 0;
            mark_pending(w);  // another pass, behind the other watches
        }
    }

    return st->overflowed || st->queue_head != NULL;
}

// Records the caller as the process that drains notifications and closes
// descriptors, and tells it about any closes already queued.
static void attach(ErlNifEnv* env) {
    enif_self(env, &st->attached_pid);
    st->attached = 1;
    if (st->closing != NULL) {
        st->close_signalled = 1;
        enif_send(env, &st->attached_pid, NULL, atom_flock_close);
    }
}

// attach() -> ok. Makes the caller the closer when there are no notifications.
static ERL_NIF_TERM attach_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    enif_mutex_lock(st->registry_mtx);
    attach(env);
    enif_mutex_unlock(st->registry_mtx);
    return atom_ok;
}

// detach() -> ok. From now on descriptors are closed where their lock ends.
static ERL_NIF_TERM detach_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    enif_mutex_lock(st->registry_mtx);
    st->attached = 0;
    enif_mutex_unlock(st->registry_mtx);
    return atom_ok;
}

// drain(Notifier) -> ok | more
//
// Does one bounded share of the pending work. more means drain should be
// called again; ok means the select has been re-armed, so the calling
// process will be sent {select, Notifier, undefined, ready_input} when
// further events arrive.
static ERL_NIF_TERM drain_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    // The notifier keeps the type it was created with, even across a purge
    // and reload, and that type lives as long as the notifier.
    notifier_t* n;
    enif_mutex_lock(st->registry_mtx);
    if (argc != 1 || st->notifier_kind == NULL ||
        !enif_get_resource(env, argv[0], st->notifier_kind, (void**)&n)) {
        enif_mutex_unlock(st->registry_mtx);
        return enif_make_badarg(env);
    }
    if (!st->attached) attach(env);
    int full = read_events(n);
    int remaining = deliver(env);
    enif_mutex_unlock(st->registry_mtx);

    if (full || remaining) return atom_more;
    int rc = enif_select(env, (ErlNifEvent)n->fd, ERL_NIF_SELECT_READ, n, NULL, atom_undefined);
    return rc < 0 ? enif_make_tuple2(env, atom_error, enif_make_int(env, rc)) : atom_ok;
}

// close_pending() -> ok | more
//
// Unlocks and closes up to CLOSE_BATCH queued descriptors, oldest first, so
// a steady stream of new ones cannot hold up an earlier release. more means
// some are left and close_pending should be called again.
static ERL_NIF_TERM close_pending_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    return close_some(CLOSE_BATCH) ? atom_more : atom_ok;
}

// kind_count() -> integer(). Lock types still tracked, for tests.
static ERL_NIF_TERM kind_count_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    int count = 0;
    enif_mutex_lock(st->registry_mtx);
    for (kind_t* k = st->kinds; k != NULL; k = k->next) count++;
    enif_mutex_unlock(st->registry_mtx);
    return enif_make_int(env, count);
}

// watch_count() -> integer(). Registered locks, for tests.
static ERL_NIF_TERM watch_count_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    enif_mutex_lock(st->registry_mtx);
    int count = st->nwatched;
    enif_mutex_unlock(st->registry_mtx);
    return enif_make_int(env, count);
}

static state_t* new_state(void) {
    state_t* s = enif_alloc(sizeof(state_t));
    if (s == NULL) return NULL;
    memset(s, 0, sizeof(state_t));
    s->version = LAYOUT_VERSION;
    s->next_watch_id = 1;
    s->registry_mtx = enif_mutex_create("flockit_registry");
    if (s->registry_mtx == NULL) {
        enif_free(s);
        return NULL;
    }
    return s;
}

// Sets up this instance once st is in place. Resource types are taken over
// from the previous instance, if any, so its resources get this instance's
// callbacks and it can be unloaded.
static int init(ErlNifEnv* env) {
    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atom_busy = enif_make_atom(env, "busy");
    atom_more = enif_make_atom(env, "more");
    atom_flock_released = enif_make_atom(env, "flockit_released");
    atom_flock_close = enif_make_atom(env, "flockit_close");
    atom_true = enif_make_atom(env, "true");
    atom_false = enif_make_atom(env, "false");
    atom_noproc = enif_make_atom(env, "noproc");
    atom_unavailable = enif_make_atom(env, "unavailable");
    atom_undefined = enif_make_atom(env, "undefined");

    ErlNifResourceFlags flags = ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER;
    ErlNifResourceTypeInit lock_init = {.dtor = lock_dtor, .down = lock_down};
    ErlNifResourceType* lt = enif_open_resource_type_x(env, "flockit_lock", &lock_init, flags, NULL);
    ErlNifResourceTypeInit notifier_init = {.stop = notifier_stop};
    ErlNifResourceType* nt =
        enif_open_resource_type_x(env, "flockit_notifier", &notifier_init, flags, NULL);
    if (lt == NULL || nt == NULL) return 1;

    enif_mutex_lock(st->registry_mtx);
    kind_t* k = adopt_kind(lt);
    enif_mutex_unlock(st->registry_mtx);
    if (k == NULL) return 1;

    // Only now, since reloading the same file shares these with running code
    // that must keep working if the load fails.
    lock_type = lt;
    notifier_type = nt;
    lock_kind = k;
    return 0;
}

static int load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info) {
    // The anchor keeps this library loaded, so a reload after a purge finds
    // st intact and carries on with it.
    if (st == NULL && (st = new_state()) == NULL) return 1;
    *priv_data = st;
    return init(env);
}

// Loading a new version over a running one. The new library is usually a
// separate instance, with st still NULL, but reloading the same file finds
// the running instance itself.
static int upgrade(ErlNifEnv* env, void** priv_data, void** old_priv_data, ERL_NIF_TERM load_info) {
    state_t* old = *old_priv_data;
    // Version 1.0.0 kept its state in globals, out of reach.
    if (old == NULL || old->version != LAYOUT_VERSION) return 1;
    if (st != NULL && st != old) return 1;
    st = old;
    *priv_data = st;
    return init(env);
}

static ErlNifFunc nif_funcs[] = {
    {"acquire", 2, acquire_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"try", 1, try_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"watch", 1, watch_nif, 0},
    // Unlocking can involve a round trip on network filesystems.
    {"release", 1, release_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"close_pending", 0, close_pending_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"notifier", 0, notifier_nif, 0},
    {"drain", 1, drain_nif, 0},
    {"attach", 0, attach_nif, 0},
    {"detach", 0, detach_nif, 0},
    {"watch_count", 0, watch_count_nif, 0},
    {"kind_count", 0, kind_count_nif, 0},
};

ERL_NIF_INIT(Elixir.Flockit.NIF, nif_funcs, load, NULL, upgrade, NULL)

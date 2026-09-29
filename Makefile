# Builds the Flock NIF. Invoked by elixir_make, which sets MIX_APP_PATH and
# ERTS_INCLUDE_DIR.
#
# Targets:
#   all      build $(MIX_APP_PATH)/priv/flock_nif.so
#   analyze  run the clang static analyzer over the NIF source
#   clean    remove build products

PREFIX = $(MIX_APP_PATH)/priv
BUILD = $(MIX_APP_PATH)/obj
NIF = $(PREFIX)/flock_nif.so
SRC = c_src/flock_nif.c
OBJ = $(BUILD)/flock_nif.o

ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~ts/erts-~ts/include", [code:root_dir(), erlang:system_info(version)]), halt().')

CFLAGS ?= -O2
CFLAGS += -std=gnu11 -fPIC -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter
CFLAGS += -I"$(ERTS_INCLUDE_DIR)"

ifeq ($(shell uname -s),Darwin)
	LDFLAGS += -dynamiclib -undefined dynamic_lookup
else
	LDFLAGS += -shared
endif

all: $(NIF)

$(OBJ): $(SRC) | $(BUILD)
	$(CC) -c $(CFLAGS) -o $@ $<

$(NIF): $(OBJ) | $(PREFIX)
	$(CC) -o $@ $^ $(LDFLAGS)

$(PREFIX) $(BUILD):
	mkdir -p $@

analyze:
	clang --analyze -Xanalyzer -analyzer-werror $(CFLAGS) $(SRC) -o /dev/null

clean:
	$(RM) $(NIF) $(OBJ)

.PHONY: all analyze clean

defmodule FlockitReloadTest do
  # Synchronous: reloading the NIF module affects every other test.
  use ExUnit.Case, async: false

  alias Flockit.NIF

  @moduletag :tmp_dir

  setup do
    previous = Application.get_env(:flockit, :max_poll_interval)
    on_exit(fn -> Application.put_env(:flockit, :max_poll_interval, previous) end)
    eventually(fn -> NIF.watch_count() == 0 end)
    :ok
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> true
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  # So slow that any prompt wake-up must have come from a notification.
  defp disable_fallback, do: Application.put_env(:flockit, :max_poll_interval, 60_000)

  defp holder(path) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, lock} = Flockit.lock(path)
        send(parent, {:held, self()})
        receive do: (:unlock -> Flockit.unlock(lock))
        receive do: (:stop -> :ok)
      end)

    assert_receive {:held, ^pid}, 1_000
    pid
  end

  defp timed_lock(path, opts \\ []) do
    Task.async(fn ->
      result = Flockit.lock(path, opts)
      {result, System.monotonic_time(:millisecond)}
    end)
  end

  # Loads Flockit.NIF again, which loads its NIF library again:
  #
  #   :upgrade  over the running version, from the same file, which finds the
  #             running library instance;
  #   :copy     over the running version, from a copy of the library, which
  #             loads a separate instance, as a release upgrade does;
  #   :purge    after deleting and purging the running version, which leaves
  #             the library loaded but its resource types retired.
  defp reload(:upgrade, _dir), do: load_module()

  defp reload(:copy, dir) do
    lib = :code.lib_dir(:flockit)
    copy = Path.join(dir, "flockit")
    File.mkdir_p!(copy)
    File.cp_r!(Path.join(lib, "ebin"), Path.join(copy, "ebin"))
    File.cp_r!(Path.join(lib, "priv"), Path.join(copy, "priv"))
    true = :code.replace_path(:flockit, String.to_charlist(Path.join(copy, "ebin")))

    try do
      load_module()
    after
      true = :code.replace_path(:flockit, String.to_charlist(Path.join(lib, "ebin")))
    end

    # Upgrade back to the original library: a later purge and reload finds
    # that file, and a new instance of it would not see the copy's state.
    on_exit(&load_module/0)
  end

  defp reload(:purge, _dir) do
    object_code = :code.get_object_code(NIF)
    purge()
    true = :code.delete(NIF)
    purge()
    load_binary(object_code)
  end

  defp load_module do
    object_code = :code.get_object_code(NIF)
    purge()
    load_binary(object_code)
    purge()
  end

  defp load_binary({NIF, binary, file}) do
    assert {:module, NIF} = :code.load_binary(NIF, file, binary)
  end

  defp purge, do: eventually(fn -> :code.soft_purge(NIF) end)

  for mode <- [:upgrade, :copy, :purge] do
    describe "after a reload (#{mode})" do
      test "a waiter from before is still notified", %{tmp_dir: dir} do
        disable_fallback()
        path = Path.join(dir, "lock")
        {:ok, held} = Flockit.lock(path)
        started = System.monotonic_time(:millisecond)
        task = timed_lock(path)
        eventually(fn -> NIF.watch_count() == 1 end)

        reload(unquote(mode), dir)

        # Between fallback retries at 630ms and 1270ms.
        Process.sleep(max(700 - (System.monotonic_time(:millisecond) - started), 0))
        unlocked_at = System.monotonic_time(:millisecond)
        assert Flockit.unlock(held) == :ok

        assert {{:ok, lock}, locked_at} = Task.await(task)
        assert locked_at - unlocked_at < 200
        assert NIF.watch_count() == 0
        Flockit.unlock(lock)
      end

      test "a lock from before is released when its owner exits", %{tmp_dir: dir} do
        path = Path.join(dir, "lock")
        pid = holder(path)

        reload(unquote(mode), dir)

        assert Flockit.try_lock(path) == {:error, :eagain}
        Process.exit(pid, :kill)
        assert {:ok, lock} = Flockit.lock(path, timeout: 2_000)
        Flockit.unlock(lock)
      end

      test "locks from before and after coexist", %{tmp_dir: dir} do
        before = Path.join(dir, "before")
        {:ok, old} = Flockit.lock(before, mode: :shared)

        reload(unquote(mode), dir)

        {:ok, new} = Flockit.lock(before, mode: :shared)
        assert Flockit.try_lock(before) == {:error, :eagain}
        assert Flockit.unlock(old) == :ok
        assert Flockit.unlock(old) == :ok
        assert Flockit.try_lock(before) == {:error, :eagain}
        assert Flockit.unlock(new) == :ok
        assert {:ok, lock} = Flockit.try_lock(before)
        Flockit.unlock(lock)
      end
    end
  end
end

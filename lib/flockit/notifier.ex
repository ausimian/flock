defmodule Flockit.Notifier do
  @moduledoc false

  # Pumps the VM-wide release notifications: the NIF selects the notify
  # descriptor for this process, and each ready message drains the pending
  # events in bounded batches, messaging the owners of affected locks, before
  # re-arming the select. Waiters retry on a timer as well, so while this
  # process is restarting, or if notifications cannot be set up, they are
  # only slower to notice a release.
  #
  # It also closes the descriptors of locks ended by an owner exiting or a
  # handle being garbage collected, on a dirty scheduler, since unlocking can
  # block.

  use GenServer

  require Logger

  alias Flockit.NIF

  @retry_interval 5_000

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :attach, true), do: :ok = NIF.attach()

    state = %{
      open: Keyword.get(opts, :open, &NIF.notifier/0),
      retry_interval: Keyword.get(opts, :retry_interval, @retry_interval),
      notifier: nil
    }

    {:ok, open(state)}
  end

  @impl true
  def handle_info({:select, notifier, :undefined, :ready_input}, %{notifier: notifier} = state) do
    drain(notifier)
    {:noreply, state}
  end

  def handle_info(:drain, %{notifier: notifier} = state) do
    drain(notifier)
    {:noreply, state}
  end

  def handle_info(:flockit_close, state) do
    if NIF.close_pending() == :more, do: send(self(), :flockit_close)
    {:noreply, state}
  end

  def handle_info(:open, %{notifier: nil} = state), do: {:noreply, open(state)}

  defp open(state) do
    case state.open.() do
      {:ok, notifier} ->
        drain(notifier)
        %{state | notifier: notifier}

      {:error, :enotsup} ->
        state

      {:error, reason} ->
        Logger.warning(
          "Flockit could not set up release notifications (#{inspect(reason)}); " <>
            "waiters will rely on timed retries until it can"
        )

        Process.send_after(self(), :open, state.retry_interval)
        state
    end
  end

  # One bounded share of the work per message, so other work interleaves
  # with a long stream of events.
  defp drain(notifier) do
    case NIF.drain(notifier) do
      :ok -> :ok
      :more -> send(self(), :drain)
    end
  end
end

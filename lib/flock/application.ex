defmodule Flock.Application do
  @moduledoc false

  use Application

  alias Flock.NIF

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Flock.Notifier], strategy: :one_for_one, name: Flock.Supervisor)
  end

  # With the notifier gone, locks ending from now on close their own
  # descriptors, and any it had not yet closed are closed here.
  @impl true
  def stop(_state) do
    :ok = NIF.detach()
    close_all()
  end

  defp close_all do
    case NIF.close_pending() do
      :ok -> :ok
      :more -> close_all()
    end
  end
end

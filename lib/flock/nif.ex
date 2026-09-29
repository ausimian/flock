defmodule Flock.NIF do
  @moduledoc false

  @on_load :load_nif

  def load_nif do
    :flock
    |> :code.priv_dir()
    |> :filename.join(~c"flock_nif")
    |> :erlang.load_nif(0)
  end

  def acquire(_path, _exclusive), do: :erlang.nif_error(:nif_not_loaded)
  def try(_lock), do: :erlang.nif_error(:nif_not_loaded)
  def watch(_lock), do: :erlang.nif_error(:nif_not_loaded)
  def release(_lock), do: :erlang.nif_error(:nif_not_loaded)
  def notifier, do: :erlang.nif_error(:nif_not_loaded)
  def drain(_notifier), do: :erlang.nif_error(:nif_not_loaded)
  def close_pending, do: :erlang.nif_error(:nif_not_loaded)
  def attach, do: :erlang.nif_error(:nif_not_loaded)
  def detach, do: :erlang.nif_error(:nif_not_loaded)
  def watch_count, do: :erlang.nif_error(:nif_not_loaded)
end

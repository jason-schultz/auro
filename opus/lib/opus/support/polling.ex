defmodule Opus.Support.Polling do
  @moduledoc """
  Shared polling helpers for GenServers that run periodic :poll cycles.
  """

  @spec schedule(pid(), non_neg_integer(), atom()) :: reference()
  def schedule(pid, interval_ms, message \\ :poll)
      when is_integer(interval_ms) and interval_ms > 0 and is_atom(message) do
    Process.send_after(pid, message, interval_ms)
  end
end

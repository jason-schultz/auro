defmodule OpusWeb.Format do
  @moduledoc """
  Number formatting for templates: money with thousands separators and a
  true minus sign, percentages, and short clock times.
  """

  @doc """
  Formats a CAD amount: `money(1234.5)` → `"$1,234.50"`, `money(-38.0)` → `"−$38.00"`.
  `nil` renders as an em dash.
  """
  @spec money(number() | nil) :: String.t()
  def money(nil), do: "—"

  def money(amount) when is_number(amount) do
    sign = if amount < 0, do: "−", else: ""
    cents = amount |> abs() |> Kernel.*(100) |> round()
    whole = div(cents, 100)
    fraction = rem(cents, 100)

    "#{sign}$#{group_thousands(whole)}.#{String.pad_leading(Integer.to_string(fraction), 2, "0")}"
  end

  @doc "Formats a share of one: `pct(0.6452)` → `\"64.5%\"`."
  @spec pct(float() | nil) :: String.t()
  def pct(nil), do: "—"
  def pct(share), do: "#{:erlang.float_to_binary(share * 100, decimals: 1)}%"

  @doc "Formats a share count: whole numbers without decimals, fractional with up to four."
  @spec shares(number()) :: String.t()
  def shares(count) when is_number(count) do
    if count == trunc(count) do
      group_thousands(trunc(count))
    else
      count |> :erlang.float_to_binary(decimals: 4) |> String.trim_trailing("0")
    end
  end

  @doc "Local wall-clock time, e.g. `17:31`."
  @spec clock(DateTime.t()) :: String.t()
  def clock(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M")

  defp group_thousands(whole) when is_integer(whole) do
    whole
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end

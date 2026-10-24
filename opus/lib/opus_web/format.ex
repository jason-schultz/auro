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

  @doc "Day and clock time, e.g. `Oct 23 17:31`; `nil` renders as an em dash."
  @spec stamp(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def stamp(nil), do: "—"
  def stamp(at), do: Calendar.strftime(at, "%b %-d %H:%M")

  @doc """
  A traded price with the decimals its size suggests and grouped thousands:
  `price(29206.7)` → `"29,206.7"`, `price(1.08543)` → `"1.08543"`.
  """
  @spec price(number() | nil) :: String.t()
  def price(nil), do: "—"

  def price(value) when is_number(value) do
    decimals =
      cond do
        abs(value) >= 1000 -> 1
        abs(value) >= 10 -> 2
        true -> 5
      end

    sign = if value < 0, do: "−", else: ""
    text = value |> abs() |> :erlang.float_to_binary(decimals: decimals)
    [whole, fraction] = String.split(text, ".")
    sign <> group_thousands(String.to_integer(whole)) <> "." <> fraction
  end

  @doc "A signed percentage from a share of one: `signed_pct(0.0069)` → `\"+0.7%\"`."
  @spec signed_pct(number() | nil) :: String.t()
  def signed_pct(nil), do: "—"
  def signed_pct(share) when share < 0, do: "−" <> pct(abs(share))
  def signed_pct(share), do: "+" <> pct(share)

  @doc "How long between two instants, e.g. `5h 30m`; the end defaults to now."
  @spec held(DateTime.t() | nil, DateTime.t() | nil) :: String.t()
  def held(nil, _to), do: "—"

  def held(from, to) do
    minutes = DateTime.diff(to || DateTime.utc_now(), from, :minute)

    cond do
      minutes >= 2880 -> "#{div(minutes, 1440)}d"
      minutes >= 60 -> "#{div(minutes, 60)}h #{rem(minutes, 60)}m"
      true -> "#{minutes}m"
    end
  end

  @doc "A ratio such as a Sharpe: `num(1.0345)` → `\"1.03\"`; `nil` renders as an em dash."
  @spec num(number() | nil, non_neg_integer()) :: String.t()
  def num(value, decimals \\ 2)
  def num(nil, _decimals), do: "—"
  def num(value, _decimals) when is_integer(value), do: Integer.to_string(value)

  def num(value, decimals) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: decimals)

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

defmodule Opus.Accounts.IndexExposure do
  @moduledoc """
  The volatility rule adopted from research round 4
  (`research/round4_preregistration.md`, Moreira & Muir 2017, no leverage):
  hold min(1, 0.16² ÷ last month's realized variance) of an index this month,
  the rest in cash. Tested on the S&P 500 only, so that is all it reports.

  Daily closes come from the S&P 500 CFD's stored daily bars. A bar is
  stamped at its open, the previous New York afternoon, so its close falls on
  the next calendar day.
  """

  import Ecto.Query

  alias Opus.Repo

  @target_vol 0.16
  @trading_days 252
  @instrument "SPX500_USD"

  @type t :: %{
          label: String.t(),
          month: Date.t(),
          realized_vol: float(),
          exposure: float()
        }

  @doc "This month's S&P 500 exposure, from last month's bars; nil without them."
  @spec current(Date.t()) :: t() | nil
  def current(today \\ Date.utc_today()) do
    month = today |> Date.beginning_of_month() |> Date.shift(month: -1)

    with %{} = result <- for_month(closes(month), month) do
      Map.put(result, :label, "S&P 500")
    end
  end

  @doc """
  Realized volatility and exposure for `month` from `{date, close}` pairs in
  date order: the month's closes plus the last close before it.
  """
  @spec for_month([{Date.t(), float()}], Date.t()) :: map() | nil
  def for_month(closes, month) do
    returns =
      closes
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn [_, {date, _}] -> same_month?(date, month) end)
      |> Enum.map(fn [{_, prev}, {_, close}] -> close / prev - 1 end)

    case returns do
      [] ->
        nil

      returns ->
        variance = Enum.sum_by(returns, &(&1 * &1)) / length(returns) * @trading_days

        %{
          month: month,
          realized_vol: :math.sqrt(variance),
          exposure: min(1.0, @target_vol * @target_vol / variance)
        }
    end
  end

  defp same_month?(date, month), do: Date.beginning_of_month(date) == month

  defp closes(month) do
    month_end = Date.end_of_month(month)

    rows =
      from(c in "candles",
        where:
          c.instrument == ^@instrument and c.granularity == "D" and c.complete and
            c.timestamp < ^DateTime.new!(Date.add(month_end, 1), ~T[00:00:00]),
        order_by: [desc: c.timestamp],
        limit: 40,
        select: {type(c.timestamp, :utc_datetime_usec), c.close}
      )
      |> Repo.all()
      |> Enum.reverse()
      |> Enum.map(fn {opened, close} -> {opened |> DateTime.to_date() |> Date.add(1), close} end)

    # The month's closes plus the one before it.
    {before, during} = Enum.split_with(rows, fn {date, _} -> Date.before?(date, month) end)
    Enum.take(before, -1) ++ Enum.filter(during, fn {date, _} -> same_month?(date, month) end)
  end
end

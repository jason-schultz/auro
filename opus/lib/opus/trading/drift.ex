defmodule Opus.Trading.Drift do
  @moduledoc """
  Is a live strategy behaving like its backtest? Three checks, each with a
  verdict and a sentence that says what to do:

  - **Returns.** The live trades' summed return against the same number of
    trades drawn at random from the backtest, many times over (a
    bootstrap). Worse than 19 in 20 draws is `:off`: luck rarely does that.
    The bottom 15% is `:watch`. Needs 5 closed live trades.
  - **How often it trades.** Live trades since it went live against the
    backtest's rate over the same time (a Poisson count). Far fewer than
    expected is `:off`: it may be switched off, short of prices, or blocked.
    Far more is `:watch`. Needs about 3 expected trades to judge.
  - **Fills.** What live fills cost beyond the backtest's assumed fills, per
    round trip (`Opus.Trading.ExecutionQuality`), against the backtest's
    average trade: more than half of it is `:watch`, all of it `:off`.
    Needs 5 measured fills.

  The overall verdict is the worst of them; `:too_early` when none can
  judge yet. Pure: the trades in, the verdict out. The bootstrap is seeded,
  so the same trades always read the same way.
  """

  @draws 2_000
  @min_trades 5
  @min_expected 3.0

  @type verdict :: :fine | :watch | :off | :too_early
  @type finding :: %{check: String.t(), verdict: verdict(), words: String.t()}

  @doc """
  The checks for `live` (closed live trades, `%{pnl}` as fractions) traded
  since `since`, against `backtest` (`%{trades: [%{pnl}], from, to}`) and
  `fills` (an `ExecutionQuality.summarize/1` row, or nil).
  """
  @spec check([map()], DateTime.t(), map(), map() | nil, DateTime.t()) :: %{
          verdict: verdict(),
          live_trades: non_neg_integer(),
          findings: [finding()]
        }
  def check(live, since, backtest, fills, now \\ DateTime.utc_now()) do
    findings = [
      returns(live, backtest),
      frequency(length(live), since, now, backtest),
      fills(fills, backtest)
    ]

    %{verdict: overall(findings), live_trades: length(live), findings: findings}
  end

  @order [:off, :watch, :fine, :too_early]

  defp overall(findings),
    do:
      findings
      |> Enum.map(& &1.verdict)
      |> Enum.min_by(&Enum.find_index(@order, fn v -> v == &1 end))

  # --- returns -------------------------------------------------------------

  defp returns(_live, %{trades: []}),
    do: finding("returns", :too_early, "Its backtest made no trades to compare with.")

  defp returns(live, _backtest) when length(live) < @min_trades do
    finding(
      "returns",
      :too_early,
      "#{length(live)} closed live #{trades(length(live))} so far; the comparison starts at #{@min_trades}."
    )
  end

  defp returns(live, %{trades: bt}) do
    n = length(live)
    total = Enum.sum_by(live, & &1.pnl) / 1
    share = worse_share(total, Enum.map(bt, & &1.pnl), n)
    made = "Its #{n} live trades made #{signed(total)} in total."

    cond do
      share < 0.05 ->
        finding(
          "returns",
          :off,
          "#{made} Its backtest does that badly in fewer than 1 in 20 stretches of #{n} trades, " <>
            "so it isn't behaving like its backtest. Look at what changed before trusting it with more."
        )

      share < 0.15 ->
        finding(
          "returns",
          :watch,
          "#{made} That's in the bottom #{round(share * 100)}% of what its backtest does over #{n} trades. " <>
            "Ordinary bad luck can do this; keep watching."
        )

      true ->
        finding(
          "returns",
          :fine,
          "#{made} Normal for its backtest: about #{round(share * 100)}% of stretches of #{n} trades do worse."
        )
    end
  end

  # Share of random draws of `n` backtest trades that sum to `total` or less.
  defp worse_share(total, pnls, n) do
    pool = List.to_tuple(pnls)
    size = tuple_size(pool)
    seed = :rand.seed_s(:exsss, {n, size, 2026})

    {worse, _seed} =
      Enum.reduce(1..@draws, {0, seed}, fn _, {worse, state} ->
        {sum, state} =
          Enum.reduce(1..n, {0.0, state}, fn _, {sum, s} ->
            {i, s} = :rand.uniform_s(size, s)
            {sum + elem(pool, i - 1), s}
          end)

        {if(sum <= total, do: worse + 1, else: worse), state}
      end)

    worse / @draws
  end

  # --- frequency -----------------------------------------------------------

  defp frequency(_count, _since, _now, %{trades: []}),
    do:
      finding(
        "frequency",
        :too_early,
        "Its backtest made no trades, so there's no rate to compare with."
      )

  defp frequency(count, since, now, %{trades: bt, from: from, to: to}) do
    per_day = length(bt) / max(DateTime.diff(to, from, :day), 1)
    days = max(DateTime.diff(now, since, :day), 0)
    expected = per_day * days

    about =
      "#{count} #{trades(count)} since #{OpusWeb.Format.day(since)}; its backtest averages about #{round1(expected)} over that time"

    cond do
      expected < @min_expected ->
        finding(
          "frequency",
          :too_early,
          "#{about}, too few to judge how often it trades yet."
        )

      poisson_at_most(count, expected) < 0.05 ->
        finding(
          "frequency",
          :off,
          "#{about}. It's trading far less than it should: check it's switched on, getting prices " <>
            "and not held by a safety rule (its page says)."
        )

      poisson_at_least(count, expected) < 0.05 ->
        finding(
          "frequency",
          :watch,
          "#{about}. It's trading more than its backtest did; the market may suit it, or it may be firing on noise."
        )

      true ->
        finding("frequency", :fine, "#{about}. That's normal.")
    end
  end

  @doc false
  def poisson_at_most(k, lambda) do
    {total, _term} =
      Enum.reduce(0..k//1, {0.0, :math.exp(-lambda)}, fn i, {total, term} ->
        {total + term, term * lambda / (i + 1)}
      end)

    min(total, 1.0)
  end

  @doc false
  def poisson_at_least(0, _lambda), do: 1.0
  def poisson_at_least(k, lambda), do: 1.0 - poisson_at_most(k - 1, lambda)

  # --- fills ---------------------------------------------------------------

  defp fills(%{entries_measured: measured} = f, %{trades: [_ | _] = bt})
       when measured >= @min_trades do
    cost = (f.mean_entry_slippage_bp || 0.0) + (f.mean_exit_slippage_bp || 0.0)
    edge = Enum.sum_by(bt, & &1.pnl) / length(bt) * 10_000
    costs = "Live fills cost #{round1(cost)} bp a trade more than the backtest assumed"

    cond do
      edge <= 0 ->
        finding(
          "fills",
          :too_early,
          "#{costs}; its backtest's average trade isn't positive to compare with."
        )

      cost > edge ->
        finding(
          "fills",
          :off,
          "#{costs}, more than its whole average trade of #{round1(edge)} bp. At these fills it loses money."
        )

      cost > edge / 2 ->
        finding(
          "fills",
          :watch,
          "#{costs}, more than half its average trade of #{round1(edge)} bp."
        )

      true ->
        finding(
          "fills",
          :fine,
          "#{costs}; its average trade is #{round1(edge)} bp, so that's fine."
        )
    end
  end

  defp fills(_fills, _backtest),
    do: finding("fills", :too_early, "Fewer than #{@min_trades} live fills measured so far.")

  defp finding(check, verdict, words), do: %{check: check, verdict: verdict, words: words}

  defp trades(1), do: "trade"
  defp trades(_n), do: "trades"

  defp signed(share) when share < 0, do: "−#{round1(abs(share) * 100)}%"
  defp signed(share), do: "+#{round1(share * 100)}%"

  defp round1(x), do: :erlang.float_to_binary(x / 1, decimals: 1)
end

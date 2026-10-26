defmodule Opus.Options.Paper.Pick do
  @moduledoc """
  Contract choice and fills shared by every paper book
  (research/options_paper_engine.md): a quote can be traded only with a bid
  and a spread no wider than 10% of the mid; positions are marked at the
  mid; a new contract is the one 30–45 days out whose delta is nearest a
  target, ties going to the later expiry.
  """

  @dte_min 30
  @dte_max 45
  @max_spread 0.10
  @multiplier 100

  @spec multiplier() :: pos_integer()
  def multiplier, do: @multiplier

  @doc "A quote can be traded: it has a bid, and a spread no wider than 10% of the mid."
  @spec fillable?(map() | nil) :: boolean()
  def fillable?(%{bid: bid, ask: ask})
      when is_number(bid) and is_number(ask) and bid > 0 and ask >= bid,
      do: (ask - bid) / ((ask + bid) / 2) <= @max_spread

  def fillable?(_quote), do: false

  @spec mid(map() | nil) :: float() | nil
  def mid(%{bid: bid, ask: ask}) when is_number(bid) and is_number(ask), do: (bid + ask) / 2
  def mid(_quote), do: nil

  @doc """
  From chain rows (`kind`, `strike`, `expiration`, `dte`, `delta`, `bid`,
  `ask`): the fillable contract of `kind` 30–45 days out whose delta is
  nearest `target` and which `allowed?` accepts.
  """
  @spec nearest([map()], String.t(), float(), (map() -> boolean())) :: map() | nil
  def nearest(chain, kind, target, allowed? \\ fn _ -> true end) do
    chain
    |> Enum.filter(
      &(&1.kind == kind and &1.dte in @dte_min..@dte_max and is_number(&1.delta) and
          fillable?(&1) and allowed?.(&1))
    )
    |> Enum.min_by(&{abs(&1.delta - target), -&1.dte}, fn -> nil end)
  end
end

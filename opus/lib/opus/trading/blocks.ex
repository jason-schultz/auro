defmodule Opus.Trading.Blocks do
  @moduledoc """
  The signal blocks a strategy is built from, explained for someone who
  isn't a trader: which question each one answers (`group`), what it
  watches in one sentence, what each setting does, and what to draw so the
  builder's preview can show the indicator itself.

  The settings, defaults and outputs mirror the Rust components
  (`auro_be/src/engine/<component>.rs`); the plain-words rules each output
  becomes are in `Opus.Trading.StrategyWords`.

  `draw` lists the values the engine reports for the block
  (`Signaler::series`): `place: :price` draws a line on the candles;
  `place: :panel` draws its own small chart underneath, with `levels`
  (a setting's key, or a fixed number) as dashed reference lines and an
  optional fixed `range`.
  """

  @groups [
    {"Trend", "Is it going up or down?"},
    {"Stretch", "Has it gone too far, too fast?"},
    {"Breakout", "Is it escaping its usual range?"},
    {"Momentum", "Is it speeding up or slowing down?"},
    {"Volatility", "Is the market calm or wild?"},
    {"Levels", "Where is the price against key prices?"}
  ]

  @blocks [
    %{
      type: "MaFilter",
      name: "Moving average",
      group: "Trend",
      key: "t",
      watches:
        "The average price over a number of bars. Price above it usually means an uptrend; below it, a downtrend.",
      params: [
        %{
          key: "period",
          label: "Bars",
          kind: :int,
          default: 100,
          help: "More bars make a slower, smoother line that only shows the big trend."
        },
        %{
          key: "ma_type",
          label: "Kind",
          kind: {:select, [{"Simple", "sma"}, {"Exponential", "ema"}]},
          default: "sma",
          help: "Exponential reacts faster to recent prices; simple weighs every bar the same."
        }
      ],
      ports: ~w(above below),
      draw: [%{key: "ma", label: "Average", place: :price}]
    },
    %{
      type: "TrendFollowing",
      name: "Average crossover",
      group: "Trend",
      key: "tf",
      watches:
        "Two averages, a fast one and a slow one. Fast above slow means the trend is up; the moment they cross is when the trend changes.",
      params: [
        %{
          key: "fast_period",
          label: "Fast (bars)",
          kind: :int,
          default: 50,
          help: "Fewer bars react sooner, but give more false starts."
        },
        %{
          key: "slow_period",
          label: "Slow (bars)",
          kind: :int,
          default: 200,
          help: "The longer-term trend the fast average is compared with."
        },
        %{
          key: "ma_type",
          label: "Kind",
          kind: {:select, [{"Simple", "sma"}, {"Exponential", "ema"}]},
          default: "sma",
          help: "Exponential reacts faster to recent prices; simple weighs every bar the same."
        }
      ],
      ports: ~w(bullish bearish bullish_cross bearish_cross),
      draw: [
        %{key: "fast", label: "Fast average", place: :price},
        %{key: "slow", label: "Slow average", place: :price}
      ]
    },
    %{
      type: "RsiReversion",
      name: "RSI",
      group: "Stretch",
      key: "r",
      watches:
        "How hard the price has been pushed one way lately, from 0 to 100. Very low means it fell hard (oversold); very high means it rose hard (overbought).",
      params: [
        %{
          key: "rsi_period",
          label: "Bars to look at",
          kind: :int,
          default: 2,
          help: "Fewer bars give a quicker, jumpier reading. 2 is very short-term."
        },
        %{
          key: "oversold",
          label: "Oversold below",
          kind: :float,
          default: 20,
          help: "Lower means fewer, more extreme dips count."
        },
        %{
          key: "overbought",
          label: "Overbought above",
          kind: :float,
          default: 80,
          help: "Higher means fewer, more extreme spikes count."
        }
      ],
      ports: ~w(long short exit_long exit_short),
      draw: [
        %{
          key: "rsi",
          label: "RSI",
          place: :panel,
          range: {0, 100},
          levels: ["oversold", 50, "overbought"]
        }
      ]
    },
    %{
      type: "MeanReversion",
      name: "Stretch from average",
      group: "Stretch",
      key: "mr",
      watches:
        "How far the price has strayed from its average, measured in its normal wobble (standard deviations), with RSI as a second opinion. Prices that stray far often snap back.",
      params: [
        %{
          key: "ma_period",
          label: "Average over (bars)",
          kind: :int,
          default: 20,
          help: "The average the stretch is measured from."
        },
        %{
          key: "entry_z_threshold",
          label: "Stretch to enter",
          kind: :float,
          default: 2.0,
          help: "In normal wobbles. Higher means only bigger stretches count."
        },
        %{
          key: "stop_z_threshold",
          label: "Stretch to give up",
          kind: :float,
          default: 3.0,
          help: "If it stretches this far instead of snapping back, the trade closes."
        },
        %{
          key: "rsi_period",
          label: "RSI bars",
          kind: :int,
          default: 14,
          help: "The bars RSI looks at for its second opinion."
        },
        %{
          key: "rsi_oversold",
          label: "RSI oversold",
          kind: :float,
          default: 30,
          help: "RSI has to be below this to buy."
        },
        %{
          key: "rsi_overbought",
          label: "RSI overbought",
          kind: :float,
          default: 70,
          help: "RSI has to be above this to sell short."
        }
      ],
      ports: ~w(long short exit_long exit_short),
      draw: [
        %{key: "ma", label: "Average", place: :price},
        %{
          key: "z",
          label: "Stretch (normal wobbles)",
          place: :panel,
          levels: [
            {:neg, "stop_z_threshold"},
            {:neg, "entry_z_threshold"},
            0,
            "entry_z_threshold",
            "stop_z_threshold"
          ]
        }
      ]
    },
    %{
      type: "Donchian",
      name: "Breakout channel",
      group: "Breakout",
      key: "dc",
      watches:
        "The highest high and lowest low of recent bars. Breaking above that high, or below that low, is a classic breakout.",
      params: [
        %{
          key: "entry_period",
          label: "Breakout over (bars)",
          kind: :int,
          default: 20,
          help: "More bars mean only bigger breakouts count, so fewer trades."
        },
        %{
          key: "exit_period",
          label: "Exit over (bars)",
          kind: :int,
          default: 10,
          help: "Fewer bars exit sooner when the move fades."
        }
      ],
      ports: ~w(breakout_long breakout_short exit_long exit_short),
      draw: [
        %{key: "upper", label: "Channel high", place: :price},
        %{key: "lower", label: "Channel low", place: :price}
      ]
    },
    %{
      type: "NoiseArea",
      name: "Noise band",
      group: "Breakout",
      key: "na",
      watches:
        "How far the price usually moves from the US open by this time of day. Moving past that usual range suggests a real move, not noise. Intraday bars only.",
      params: [
        %{
          key: "lookback_sessions",
          label: "Sessions to average",
          kind: :int,
          default: 14,
          help: "More sessions make a steadier band."
        },
        %{
          key: "band_mult",
          label: "Band width ×",
          kind: :float,
          default: 1.0,
          help: "Wider means only bigger breakouts count."
        }
      ],
      ports: ~w(long short exit_long exit_short session_close),
      draw: [
        %{key: "upper", label: "Band top", place: :price},
        %{key: "lower", label: "Band bottom", place: :price},
        %{key: "vwap", label: "Day's average price (VWAP)", place: :price}
      ]
    },
    %{
      type: "Macd",
      name: "MACD",
      group: "Momentum",
      key: "m",
      watches:
        "The gap between a fast and a slow average (MACD), and a smoothed copy of it (the signal line). MACD crossing above its signal line means momentum is turning up.",
      params: [
        %{
          key: "fast_period",
          label: "Fast",
          kind: :int,
          default: 12,
          help: "Bars for the fast average."
        },
        %{
          key: "slow_period",
          label: "Slow",
          kind: :int,
          default: 26,
          help: "Bars for the slow average."
        },
        %{
          key: "signal_period",
          label: "Signal",
          kind: :int,
          default: 9,
          help: "Bars to smooth MACD into its signal line. Fewer reacts sooner."
        }
      ],
      ports: ~w(bullish bearish bullish_cross bearish_cross),
      draw: [
        %{key: "macd", label: "MACD", place: :panel, levels: [0], with: "signal"}
      ]
    },
    %{
      type: "Momentum",
      name: "Momentum",
      group: "Momentum",
      key: "mo",
      watches: "Whether the price is higher or lower than it was a number of bars ago.",
      params: [
        %{
          key: "lookback",
          label: "Bars back",
          kind: :int,
          default: 20,
          help: "More bars look at a longer-term direction."
        }
      ],
      ports: ~w(up down),
      draw: [%{key: "roc", label: "Change from then (%)", place: :panel, levels: [0]}]
    },
    %{
      type: "AdxFilter",
      name: "Trend strength (ADX)",
      group: "Trend",
      key: "adx",
      watches:
        "How strong the current trend is, from 0 to 100, whichever way it points. Above about 25 is a real trend; below it the price is mostly drifting sideways. Use it with a block that says which way.",
      params: [
        %{
          key: "period",
          label: "Bars",
          kind: :int,
          default: 14,
          help: "Fewer bars react sooner but jump around more."
        },
        %{
          key: "threshold",
          label: "Strong trend at",
          kind: :float,
          default: 25,
          help: "Higher means only the strongest trends count."
        }
      ],
      ports: ~w(trending ranging),
      draw: [%{key: "adx", label: "Trend strength (ADX)", place: :panel, levels: ["threshold"]}]
    },
    %{
      type: "Bollinger",
      name: "Bollinger bands",
      group: "Stretch",
      key: "bb",
      watches:
        "A band around the average price, as wide as the price's normal wobble. Closing outside the band means it has stretched further than usual; the middle line is the average it often returns to.",
      params: [
        %{
          key: "period",
          label: "Bars",
          kind: :int,
          default: 20,
          help: "The average and the wobble are measured over this many bars."
        },
        %{
          key: "std_dev_mult",
          label: "Band width",
          kind: :float,
          default: 2.0,
          help:
            "In normal wobbles (standard deviations). Wider means only bigger stretches count."
        }
      ],
      ports: ~w(below_band above_band above_middle below_middle),
      draw: [
        %{key: "upper", label: "Band top", place: :price},
        %{key: "middle", label: "Band middle (average)", place: :price},
        %{key: "lower", label: "Band bottom", place: :price}
      ]
    },
    %{
      type: "Stochastic",
      name: "Stochastic",
      group: "Stretch",
      key: "st",
      watches:
        "Where the price closed within its recent high-to-low range, from 0 (at the low) to 100 (at the high), plus a smoothed copy of that line. Near the bottom of its range for a while often means it's stretched down.",
      params: [
        %{
          key: "period",
          label: "Bars",
          kind: :int,
          default: 14,
          help: "The range is the high and low of this many bars."
        },
        %{
          key: "signal_period",
          label: "Smoothing",
          kind: :int,
          default: 3,
          help: "Bars to average into the second line. More is smoother but slower."
        },
        %{
          key: "oversold",
          label: "Oversold below",
          kind: :float,
          default: 20,
          help: "Lower means fewer, more extreme dips count."
        },
        %{
          key: "overbought",
          label: "Overbought above",
          kind: :float,
          default: 80,
          help: "Higher means fewer, more extreme spikes count."
        }
      ],
      ports: ~w(oversold overbought cross_up cross_down),
      draw: [
        %{
          key: "k",
          label: "Stochastic",
          place: :panel,
          range: {0, 100},
          levels: ["oversold", "overbought"],
          with: "d"
        }
      ]
    },
    %{
      type: "OpeningRange",
      name: "Opening range",
      group: "Breakout",
      key: "or",
      watches:
        "The high and low of the first minutes after the US open (09:30 New York). Breaking out of that early range often sets the direction for the day. Intraday bars only.",
      params: [
        %{
          key: "minutes",
          label: "First minutes",
          kind: :int,
          default: 30,
          help: "Longer makes a wider range, so fewer but bigger breakouts."
        }
      ],
      ports: ~w(breakout_long breakout_short inside session_close),
      draw: [
        %{key: "high", label: "Opening range high", place: :price},
        %{key: "low", label: "Opening range low", place: :price}
      ]
    },
    %{
      type: "Volatility",
      name: "Calm or wild",
      group: "Volatility",
      key: "vol",
      watches:
        "How big the bars have been lately compared with how big they usually are. Some strategies only work in calm markets, others only when things are moving.",
      params: [
        %{
          key: "period",
          label: "Recent (bars)",
          kind: :int,
          default: 14,
          help: "How many recent bars count as now."
        },
        %{
          key: "baseline",
          label: "Usual (bars)",
          kind: :int,
          default: 100,
          help: "How many bars set what's usual."
        }
      ],
      ports: ~w(quieter busier),
      draw: [
        %{
          key: "recent",
          label: "Bar size now vs usual (% of price)",
          place: :panel,
          levels: [],
          with: "usual"
        }
      ]
    },
    %{
      type: "Vwap",
      name: "Day's average price (VWAP)",
      group: "Levels",
      key: "vwap",
      watches:
        "The average price everyone has paid today since the US open, weighted by how much traded. Big traders watch it: above it, buyers are in control; below it, sellers are. Intraday bars only.",
      params: [],
      ports: ~w(above below),
      draw: [%{key: "vwap", label: "Day's average price (VWAP)", place: :price}]
    },
    %{
      type: "PivotPoints",
      name: "Pivot points",
      group: "Levels",
      key: "pv",
      watches:
        "Price levels worked out from the previous session's high, low and close: a middle pivot, a resistance level above it (R1) and a support level below (S1). Traders watch them as places the price may stall or turn.",
      params: [],
      ports: ~w(above_pivot below_pivot above_r1 below_s1),
      draw: [
        %{key: "pivot", label: "Pivot", place: :price},
        %{key: "r1", label: "Resistance (R1)", place: :price},
        %{key: "s1", label: "Support (S1)", place: :price}
      ]
    }
  ]

  @doc "The question groups, in order: `[{name, question}]`."
  @spec groups() :: [{String.t(), String.t()}]
  def groups, do: @groups

  @doc "Every block, in group order."
  @spec all() :: [map()]
  def all, do: @blocks

  @doc "The blocks of each group: `[{name, question, blocks}]`."
  @spec by_group() :: [{String.t(), String.t(), [map()]}]
  def by_group,
    do:
      for(
        {name, question} <- @groups,
        do: {name, question, Enum.filter(@blocks, &(&1.group == name))}
      )

  @doc "The block for a component type, or nil."
  @spec get(String.t()) :: map() | nil
  def get(type), do: Enum.find(@blocks, &(&1.type == type))

  @doc """
  A draw spec's reference lines for a component's settings: setting keys
  become their values, `{:neg, key}` the negated value, numbers stay.
  """
  @spec levels(map(), map()) :: [float()]
  def levels(%{levels: levels}, params) do
    Enum.flat_map(levels, fn
      n when is_number(n) -> [n / 1]
      {:neg, key} -> number(params[key]) |> List.wrap() |> Enum.map(&(-&1))
      key -> number(params[key]) |> List.wrap()
    end)
  end

  def levels(_spec, _params), do: []

  defp number(n) when is_number(n), do: n / 1

  defp number(text) when is_binary(text) do
    case Float.parse(text) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp number(_), do: nil
end

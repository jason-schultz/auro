defmodule Opus.Pipeline.Events do
  @moduledoc """
  Tells open pages when a pipeline stage starts or finishes, so they show
  each result as it lands. One Oban telemetry hook covers every stage
  worker on the `pipeline` queue: a job starting, finishing or crashing
  broadcasts `{:pipeline_stage, config_id}` on Phoenix PubSub, twice:

    * on the topic for the strategy the test belongs to (`subscribe/2`):
      its timeframe and trade settings, the key every page already matches
      results by (`Opus.Trading.Strategies.trade_settings/1`), so a page
      hears about tests of its own strategy only, a test started elsewhere
      with the same settings included;
    * on the topic for every test (`subscribe_all/0`), for pages that list
      them all.

  A page subscribes in mount and reloads in `handle_info/2`.
  """

  import Ecto.Query, only: [from: 2]

  alias Opus.Pipeline.StrategyConfig
  alias Opus.Repo
  alias Opus.Trading.Strategies

  @all "pipeline:stages"
  @events [[:oban, :job, :start], [:oban, :job, :stop], [:oban, :job, :exception]]

  @doc "Hooks the broadcasts onto Oban's job events; called once at startup."
  @spec attach() :: :ok | {:error, :already_exists}
  def attach, do: :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, nil)

  @doc "Subscribes the caller to the stages of one strategy's tests."
  @spec subscribe(map(), String.t()) :: :ok | {:error, term()}
  def subscribe(definition, granularity),
    do: Phoenix.PubSub.subscribe(Opus.PubSub, topic(granularity, definition))

  @doc "Subscribes the caller to the stages of every test."
  @spec subscribe_all() :: :ok | {:error, term()}
  def subscribe_all, do: Phoenix.PubSub.subscribe(Opus.PubSub, @all)

  @doc "Announces that test `config_id`'s stages changed."
  @spec broadcast(String.t()) :: :ok
  def broadcast(config_id) do
    message = {:pipeline_stage, config_id}

    with {granularity, parameters} <- settings(config_id),
         do: Phoenix.PubSub.broadcast(Opus.PubSub, topic(granularity, parameters), message)

    Phoenix.PubSub.broadcast(Opus.PubSub, @all, message)
    :ok
  end

  @doc false
  def handle_event(_event, _measure, %{job: %{queue: "pipeline", args: %{"config_id" => id}}}, _),
    do: broadcast(id)

  def handle_event(_event, _measure, _meta, _config), do: :ok

  defp settings(config_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(config_id) do
      Repo.one(
        from(c in StrategyConfig,
          where: c.id == ^uuid,
          select: {c.granularity, c.parameters}
        )
      )
    else
      _ -> nil
    end
  end

  # A strategy's topic: its timeframe and trade settings, hashed.
  defp topic(granularity, parameters),
    do:
      "pipeline:strategy:" <>
        Integer.to_string(:erlang.phash2({granularity, Strategies.trade_settings(parameters)}))
end

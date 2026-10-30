defmodule Opus.Repo.Migrations.StrategyEvaluationRulesVersion do
  use Ecto.Migration

  @moduledoc """
  The version of the pipeline's rules a stage result was judged by
  (`RULES_VERSION` in `auro_be/src/engine/pipeline.rs`), stamped by the
  tester on every finished stage. Opus reads a result with a lower version,
  or none, as an old test that must be re-run before it counts. NULL is a
  result from before stamping (Oct 30 2026 or earlier); existing rows stay
  NULL on purpose: which rules judged them can't be known for sure.
  """

  def change do
    alter table(:strategy_evaluations) do
      add :rules_version, :integer
    end
  end
end

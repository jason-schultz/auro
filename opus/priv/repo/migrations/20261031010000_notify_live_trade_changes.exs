defmodule Opus.Repo.Migrations.NotifyLiveTradeChanges do
  use Ecto.Migration

  @moduledoc """
  Postgres tells Opus when a live trade opens or closes: `NOTIFY
  live_trades_changed` with the trade's status, from a trigger, so the
  engine (which never calls Opus) needn't know. Opus listens
  (`Opus.Trading.SignalEventListener`) and refreshes the dashboard
  (`Opus.Dashboard.Feed`).
  """

  def up do
    execute """
    CREATE FUNCTION notify_live_trade_change() RETURNS trigger AS $$
    BEGIN
      PERFORM pg_notify('live_trades_changed', NEW.status);
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER live_trades_changed
    AFTER INSERT OR UPDATE OF status ON live_trades
    FOR EACH ROW EXECUTE FUNCTION notify_live_trade_change()
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS live_trades_changed ON live_trades"
    execute "DROP FUNCTION IF EXISTS notify_live_trade_change()"
  end
end

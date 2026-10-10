defmodule Air.Repo.Migrations.AddNotifyTriggersForTaskInstanceAndDagRun do
  use Ecto.Migration

  @moduledoc """
  Replaces the app-level `Repo.query!("SELECT pg_notify(...)")` calls in
  Air.DagRunSimulator with real Postgres triggers, so ANY write to
  task_instance/dag_run (not just the ones the app remembers to notify
  about — direct SQL, a future bulk-update path, psql, etc.) reaches
  Air.DbListener.

  Each trigger fires AFTER INSERT OR UPDATE and emits the same channel
  name / JSON field shape the app-level calls already used, so
  Air.DbListener and the LiveViews that consume its PubSub broadcasts
  don't need to change at all:

    - task_instance -> pg_notify('task_updated', ...) with
      id/task_id/run_id/dag_id/status/reason/start_time/end_time/duration_ms
      (matches Air.DagRunSimulator.notify_task/1's payload exactly)
    - dag_run -> pg_notify('dag_run_updated', ...) with
      run_id/dag_id/status/start_time/end_time/duration_ms
      (matches the payload notify_run_completion/2 built but never sent —
      that call was commented out; this migration is what actually makes
      dag_run completion notifications work)

  The payload is built from an explicit column whitelist (via
  json_build_object), not row_to_json(NEW) — task_instance has free-text
  logs/notes columns that could grow past Postgres's 8000-byte NOTIFY
  payload limit, and the app-level version never included them either.
  """

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION notify_task_instance_change() RETURNS trigger AS $$
    DECLARE
      payload json;
    BEGIN
      payload := json_build_object(
        'id', NEW.id,
        'task_id', NEW.task_id,
        'run_id', NEW.run_id,
        'dag_id', NEW.dag_id,
        'status', NEW.status,
        'reason', NEW.reason,
        'start_time', NEW.start_time,
        'end_time', NEW.end_time,
        'duration_ms', NEW.duration_ms
      );
      PERFORM pg_notify('task_updated', payload::text);
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER task_instance_notify_trigger
    AFTER INSERT OR UPDATE ON task_instance
    FOR EACH ROW
    EXECUTE FUNCTION notify_task_instance_change();
    """)

    execute("""
    CREATE OR REPLACE FUNCTION notify_dag_run_change() RETURNS trigger AS $$
    DECLARE
      payload json;
    BEGIN
      payload := json_build_object(
        'run_id', NEW.run_id,
        'dag_id', NEW.dag_id,
        'status', NEW.status,
        'start_time', NEW.start_time,
        'end_time', NEW.end_time,
        'duration_ms', NEW.duration_ms
      );
      PERFORM pg_notify('dag_run_updated', payload::text);
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER dag_run_notify_trigger
    AFTER INSERT OR UPDATE ON dag_run
    FOR EACH ROW
    EXECUTE FUNCTION notify_dag_run_change();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS dag_run_notify_trigger ON dag_run;")
    execute("DROP FUNCTION IF EXISTS notify_dag_run_change();")
    execute("DROP TRIGGER IF EXISTS task_instance_notify_trigger ON task_instance;")
    execute("DROP FUNCTION IF EXISTS notify_task_instance_change();")
  end
end

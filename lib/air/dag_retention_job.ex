defmodule Air.DagRetentionJob do
  @moduledoc """
  Periodically hard-deletes DAGs that have been soft-deleted (see
  `Air.DAG.deleted_at` / `Air.DagEditorQuery.delete_dag/1`) for longer than
  the retention window — purging a soft-deleted DAG's row along with its
  tasks and run history.

  A plain interval-timer GenServer rather than a cron library (no
  scheduling dependency exists in this project yet) — checks once per
  `@check_interval_ms`, which is far more often than the 30-day retention
  window actually requires, so a missed check (e.g. the app being
  restarted) never meaningfully delays a purge.
  """

  use GenServer
  require Logger

  @retention_days 30
  # Checking hourly is cheap (purge_deleted_dags/1 is a no-op query when
  # nothing is old enough yet) and means a DAG is purged within an hour of
  # crossing the 30-day mark, not up to a full day late.
  @check_interval_ms :timer.hours(1)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:check, state) do
    case Air.DagEditorQuery.purge_deleted_dags(@retention_days) do
      0 -> :ok
      count -> Logger.info("Air.DagRetentionJob: purged #{count} DAG(s) deleted more than #{@retention_days} days ago")
    end

    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval_ms)
  end
end

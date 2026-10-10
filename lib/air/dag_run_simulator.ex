defmodule Air.DagRunSimulator do
  @moduledoc """
  Simulates a DAG run executing step by step in a background process.

  Walks through a run's task instances in order: flips each to `:running`,
  sleeps briefly (`Process.sleep/1`) to simulate work being done, then
  resolves it to `:success` or `:failed` (~10% failure chance). As soon as
  one task fails, every remaining task is marked `:cancelled` instead of
  being executed, since their upstream dependency never completed.

  This module only writes to the database (via plain `Repo` calls) — it does
  NOT notify anyone itself. Every `task_instance`/`dag_run` row change is
  picked up by a Postgres trigger (see migration
  `add_notify_triggers_for_task_instance_and_dag_run`) that calls
  `pg_notify/2` on `task_updated`/`dag_run_updated` automatically, regardless
  of which code path performed the write. `Air.DbListener` subscribes to
  those two channels and rebroadcasts via `Air.PubSub` on a per-run topic as
  `{:tasks_updated, %{...}}` / `{:dag_run_updated, %{...}}` for LiveViews to
  consume. Relying on a trigger instead of calling `pg_notify` from here
  means a future bulk-update, a raw SQL fix, or any other write path can't
  silently forget to notify.
  """

  alias Air.{DagRun, TaskInstance, Repo}

  @failure_rate_percent 10
  @step_delay_range 1000..3000

  @doc """
  Starts the simulation as a supervised background task so a crash can't
  take down the caller (e.g. the LiveView process). `task_instances` must
  already exist in the database with status `:waiting`, ordered the way
  they should execute.
  """
  def start(run_id, task_instances) do
    Task.Supervisor.start_child(Air.TaskSupervisor, fn -> run(run_id, task_instances) end)
  end

  defp run(run_id, task_instances) do
    any_failed? = step_through(run_id, task_instances, false)
    finalize_run(run_id, any_failed?)
  end

  # No tasks left — report failure status.
  defp step_through(_run_id, [], any_failed?) do
    any_failed?
  end

  # An earlier task already failed: mark every remaining task as skipped with
  # reason. A single bulk update instead of looping through each task
  # individually — the AFTER UPDATE trigger on task_instance fires once per
  # affected row regardless, so this still notifies every one of them.
  defp step_through(_run_id, remaining_tasks, true) do
    import Ecto.Query

    remaining_ids = Enum.map(remaining_tasks, & &1.id)

    from(ti in TaskInstance, where: ti.id in ^remaining_ids)
    |> Repo.update_all(set: [status: :skipped, reason: "upstream_failed", updated_at: DateTime.utc_now()])

    true
  end

  # Normal path: run this task, then continue (or start cancelling if it failed).
  defp step_through(run_id, [task | rest], false) do
    start_time = DateTime.utc_now()
    running = set_status!(task, :running, %{start_time: start_time})

    Process.sleep(Enum.random(@step_delay_range))

    failed? = :rand.uniform(100) <= @failure_rate_percent
    end_time = DateTime.utc_now()
    duration_ms = DateTime.diff(end_time, start_time, :millisecond)
    status = if failed?, do: :failed, else: :success

    set_status!(running, status, %{end_time: end_time, duration_ms: duration_ms})

    step_through(run_id, rest, failed?)
  end

  defp set_status!(task_instance, status, extra_attrs) do
    task_instance
    |> TaskInstance.changeset(Map.put(extra_attrs, :status, status))
    |> Repo.update!()
  end

  # Finalizes the run's own status/end_time/duration_ms. The AFTER UPDATE
  # trigger on dag_run (see the migration referenced in the moduledoc) fires
  # pg_notify('dag_run_updated', ...) for this write automatically — no
  # notify call needed here.
  defp finalize_run(run_id, any_failed?) do
    run = Repo.get!(DagRun, run_id)
    end_time = DateTime.utc_now()
    duration_ms = DateTime.diff(end_time, run.start_time, :millisecond)
    status = if any_failed?, do: :failed, else: :success

    run
    |> DagRun.changeset(%{status: status, end_time: end_time, duration_ms: duration_ms})
    |> Repo.update!()
  end
end

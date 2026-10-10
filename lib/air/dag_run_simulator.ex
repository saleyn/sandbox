defmodule Air.DagRunSimulator do
  @moduledoc """
  Simulates a DAG run executing step by step in a background process.

  Walks through a run's task instances in order: flips each to `:running`,
  sleeps briefly (`Process.sleep/1`) to simulate work being done, then
  resolves it to `:success` or `:failed` (~10% failure chance). As soon as
  one task fails, every remaining task is marked `:cancelled` instead of
  being executed, since their upstream dependency never completed.

  Progress is broadcast via `Air.PubSub` on `topic(run_id)` so a LiveView can
  subscribe and update live instead of polling:

    - `{:task_updated, %Air.TaskInstance{}}` — after every status change
    - `{:dag_run_completed, %Air.DagRun{}}` — once the whole run is done
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
    notify_run_completion(run_id, any_failed?)
  end

  # No tasks left — report failure status.
  defp step_through(_run_id, [], any_failed?) do
    any_failed?
  end

  # An earlier task already failed: mark every remaining task as skipped with reason.
  # Do a single bulk update instead of looping through each task individually.
  defp step_through(run_id, remaining_tasks, true) do
    import Ecto.Query

    # Extract IDs of all remaining tasks
    remaining_ids = Enum.map(remaining_tasks, & &1.id)

    IO.inspect(remaining_ids, label: "Remaining task IDs")

    # Single bulk update to set all remaining tasks to :skipped with upstream_failed reason
    from(ti in TaskInstance, where: ti.id in ^remaining_ids)
    |> Repo.update_all(set: [status: :skipped, reason: "upstream_failed", updated_at: DateTime.utc_now()])
    |> IO.inspect(label: "Bulk update result")

    # Fetch the updated tasks and notify them
    updated_tasks = Repo.all(from(ti in TaskInstance, where: ti.id in ^remaining_ids))
    notify_tasks(run_id, updated_tasks)

    # Return true to indicate failure
    true
  end

  # Normal path: run this task, then continue (or start cancelling if it failed).
  defp step_through(run_id, [task | rest], false) do
    start_time = DateTime.utc_now()
    running = set_status!(task, :running, %{start_time: start_time})
    notify_task(running)

    Process.sleep(Enum.random(@step_delay_range))

    failed? = :rand.uniform(100) <= @failure_rate_percent
    end_time = DateTime.utc_now()
    duration_ms = DateTime.diff(end_time, start_time, :millisecond)
    status = if failed?, do: :failed, else: :success

    done = set_status!(running, status, %{end_time: end_time, duration_ms: duration_ms})
    notify_task(done)

    step_through(run_id, rest, failed?)
  end

  # Notify about a single task update
  defp notify_task(task) do
    payload = Jason.encode!(%{
      id: task.id,
      task_id: task.task_id,
      run_id: task.run_id,
      dag_id: task.dag_id,
      status: task.status,
      reason: task.reason,
      start_time: task.start_time,
      end_time: task.end_time,
      duration_ms: task.duration_ms
    })

    # Repo.query! runs raw SQL through the repo's own connection pool, same
    # as any other Ecto call — no need to reach into Postgrex directly.
    # The previous Postgrex.query!(Repo.config()[:conn], ...) crashed every
    # time: Air.Repo's config has no :conn key at all, so that resolved to
    # Postgrex.query!(nil, ...), which DBConnection then tried to check out
    # a connection from a pool literally named `nil` — "no process... the
    # process is not alive" — and the whole simulator task died on the
    # very first task update.
    Repo.query!("SELECT pg_notify('task_updated', $1)", [payload])
  end

  # Notify about multiple task updates
  defp notify_tasks(_run_id, []), do: :ok
  defp notify_tasks(_run_id, tasks) do
    Enum.each(tasks, &notify_task/1)
  end

  defp set_status!(task_instance, status, extra_attrs) do
    task_instance
    |> TaskInstance.changeset(Map.put(extra_attrs, :status, status))
    |> Repo.update!()
  end

  defp notify_run_completion(run_id, any_failed?) do
    run = Repo.get!(DagRun, run_id)
    end_time = DateTime.utc_now()
    duration_ms = DateTime.diff(end_time, run.start_time, :millisecond)
    status = if any_failed?, do: :failed, else: :success

    {:ok, _updated_run} =
      run
      |> DagRun.changeset(%{status: status, end_time: end_time, duration_ms: duration_ms})
      |> Repo.update()

    # Notify via Postgres
    # payload = Jason.encode!(%{
    #   run_id: updated_run.run_id,
    #   dag_id: updated_run.dag_id,
    #   status: updated_run.status,
    #   start_time: updated_run.start_time,
    #   end_time: updated_run.end_time,
    #   duration_ms: updated_run.duration_ms
    # })

    # Repo.query!("SELECT pg_notify('dag_run_updated', $1)", [payload])
  end
end

defmodule Air.DagExecutionQuery do
  @moduledoc """
  Query helpers for fetching DAG execution history data.
  """

  import Ecto.Query
  alias Air.Repo
  alias Air.DagRun
  alias Air.TaskInstance

  @doc """
  Fetches execution history for a specific DAG with task instances.

  Returns a list of executions ordered from oldest to newest, with all related task instances.

  ## Options

  - `:limit` - Maximum number of runs to return (default: 10)
  - `:offset` - Number of runs to skip (default: 0)
  """
  def get_dag_executions(dag_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    offset = Keyword.get(opts, :offset, 0)

    DagRun
    |> where(dag_id: ^dag_id)
    |> order_by(asc: :start_time)
    |> limit(^limit)
    |> offset(^offset)
    |> preload(task_instances: ^task_instances_in_sequence_order())
    |> Repo.all()
    |> Enum.map(&format_execution/1)
  end

  @doc """
  Fetches the most recent N executions for a DAG.
  """
  def get_recent_dag_executions(dag_id, count \\ 5) do
    DagRun
    |> where(dag_id: ^dag_id)
    |> order_by(desc: :start_time)
    |> limit(^count)
    |> preload(task_instances: ^task_instances_in_sequence_order())
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(&format_execution/1)
  end

  @doc """
  Fetches executions for a DAG within a date range.
  """
  def get_dag_executions_in_range(dag_id, from_datetime, to_datetime) do
    DagRun
    |> where(dag_id: ^dag_id)
    |> where([r], r.start_time >= ^from_datetime and r.start_time <= ^to_datetime)
    |> order_by(asc: :start_time)
    |> preload(task_instances: ^task_instances_in_sequence_order())
    |> Repo.all()
    |> Enum.map(&format_execution/1)
  end

  # Orders task instances by their row id (insertion order == the task's
  # position in the DAG's execution sequence) rather than by `start_time`.
  # `start_time` is nil for tasks that haven't started yet (status
  # `:waiting`), and nil sorts before every real timestamp — so sorting by
  # start_time would yank not-yet-run tasks to the front of the list while a
  # run is live, scrambling the display mid-simulation.
  defp task_instances_in_sequence_order, do: from(ti in TaskInstance, order_by: ti.id)

  @doc """
  Fetches execution statistics for a DAG.

  Returns stats like total runs, success rate, etc.
  """
  def get_dag_stats(dag_id) do
    runs_query = from(r in DagRun, where: r.dag_id == ^dag_id)

    total_runs = Repo.aggregate(runs_query, :count, :run_id)

    successful_runs =
      runs_query
      |> where(status: :success)
      |> Repo.aggregate(:count, :run_id)

    failed_runs =
      runs_query
      |> where(status: :failed)
      |> Repo.aggregate(:count, :run_id)

    avg_duration_ms =
      runs_query
      |> select([r], avg(r.duration_ms))
      |> Repo.one()
      |> case do
        nil -> 0
        decimal -> decimal |> Decimal.to_float() |> round()
      end

    %{
      total_runs: total_runs || 0,
      successful_runs: successful_runs || 0,
      failed_runs: failed_runs || 0,
      success_rate: calculate_success_rate(successful_runs, total_runs),
      avg_duration_ms: avg_duration_ms
    }
  end

  @doc """
  Fetches task instance details for a specific task within a run.
  """
  def get_task_instance(run_id, task_id) do
    TaskInstance
    |> where(run_id: ^run_id, task_id: ^task_id)
    |> Repo.one()
  end

  @doc """
  Fetches all task instances for a specific run.
  """
  def get_run_task_instances(run_id) do
    TaskInstance
    |> where(run_id: ^run_id)
    |> order_by(asc: :start_time)
    |> Repo.all()
  end

  @doc """
  Converts a `%Air.DagRun{}` (with `:task_instances` preloaded) into the plain
  map shape the `DagExecutionHistory` component and this module's callers
  expect. Public so a LiveView can reuse it to splice a freshly-updated
  `%Air.DagRun{}`/`%Air.TaskInstance{}` into an already-fetched list without
  re-querying the whole history.
  """
  def format_execution(dag_run) do
    %{
      id: dag_run.run_id,
      dag_id: dag_run.dag_id,
      start_time: dag_run.start_time,
      end_time: dag_run.end_time,
      duration_ms: dag_run.duration_ms || 0,
      status: dag_run.status,
      tasks:
        dag_run.task_instances
        |> Enum.sort_by(& &1.id)
        |> Enum.map(&format_task_instance/1)
    }
  end

  @doc "Converts a `%Air.TaskInstance{}` into the plain map shape used in a execution's `:tasks` list."
  def format_task_instance(task_instance) do
    %{
      id: task_instance.task_id,
      name: task_instance.task_id,
      start_time: task_instance.start_time,
      end_time: task_instance.end_time,
      duration_ms: task_instance.duration_ms || 0,
      status: task_instance.status,
      reason: task_instance.reason,
      run_id: task_instance.run_id,
      try_number: task_instance.try_number,
      just_failed: false
    }
  end

  # Private helpers

  defp calculate_success_rate(successful, total) do
    cond do
      is_nil(successful) or is_nil(total) or total == 0 -> 0.0
      true -> Float.round(successful / total * 100, 2)
    end
  end
end

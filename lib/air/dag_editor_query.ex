defmodule Air.DagEditorQuery do
  @moduledoc """
  Query/context module for the visual DAG editor — loading a DAG with
  its tasks for the canvas, and saving the graph back (transactional
  upsert of tasks + deletion of removed ones + layout update on the DAG).
  """

  import Ecto.Query
  alias Air.{DAG, DagRun, DagTask, Repo}

  @doc """
  Loads a DAG and all its tasks, returning a map ready for the editor.

  Returns `{:ok, %{dag: %DAG{}, tasks: [%DagTask{}]}}` or `{:error, :not_found}`.
  """
  def get_dag_with_tasks(dag_id) do
    case Repo.get(DAG, dag_id) do
      nil ->
        {:error, :not_found}

      dag ->
        tasks =
          DagTask
          |> where(dag_id: ^dag_id)
          |> order_by(:task_id)
          |> Repo.all()

        {:ok, %{dag: dag, tasks: tasks}}
    end
  end

  @doc """
  Creates a new empty DAG with the given id.
  """
  def create_dag(dag_id, attrs \\ %{}) do
    %DAG{}
    |> DAG.changeset(Map.merge(%{dag_id: dag_id, title: "New DAG"}, attrs))
    |> Repo.insert()
  end

  @doc """
  Lists all DAGs (for a DAG picker/selector).
  """
  def list_dags do
    DAG
    |> order_by(:dag_id)
    |> Repo.all()
  end

  @doc """
  Updates a DAG's editable properties (Title, Description, Owner,
  Maintainers, Supporters, Labels, source code/language) from the DAG
  Properties drawer. `attrs` keys may be atoms or strings. Returns
  `{:error, changeset}` if `title` is blank, so the caller can surface the
  mandatory-field validation.
  """
  def update_properties(dag, attrs) do
    dag
    |> DAG.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Aggregate execution stats for a DAG's runs — total count, per-status
  counts, average duration (ms, successful runs only), and the most
  recent run. Returns a plain map (not an Ecto struct) ready for the
  Properties drawer; all-zero/nil defaults when the DAG has no runs yet.
  """
  def get_execution_stats(dag_id) do
    status_counts =
      DagRun
      |> where(dag_id: ^dag_id)
      |> group_by([r], r.status)
      |> select([r], {r.status, count(r.run_id)})
      |> Repo.all()
      |> Map.new()

    avg_duration_ms =
      DagRun
      |> where(dag_id: ^dag_id, status: :success)
      |> select([r], avg(r.duration_ms))
      |> Repo.one()

    last_run =
      DagRun
      |> where(dag_id: ^dag_id)
      |> order_by(desc: :start_time)
      |> limit(1)
      |> Repo.one()

    %{
      total_runs: Enum.sum(Map.values(status_counts)),
      success_count: Map.get(status_counts, :success, 0),
      failed_count: Map.get(status_counts, :failed, 0),
      running_count: Map.get(status_counts, :running, 0),
      avg_duration_ms: avg_duration_ms && Decimal.to_float(avg_duration_ms),
      last_run: last_run
    }
  end

  @doc """
  Saves the entire graph from the editor in a single transaction.

  `tasks_params` is a list of maps, each with at least:
    - "task_id" (string)
    - "task_type" ("task" | "condition")
    - "downstream_list" (list of %{"task_id" => ..., "data_size" => ...})

  And optionally: "source_code", "source_language" ("python" | "shell" |
  "javascript" | "elixir"), "pool", "pool_slots", "priority_weight",
  "queue", "max_tries", "retries".

  `layout` is a map of task_id => %{"x" => ..., "y" => ...} plus an
  optional "_canvas" key for pan/zoom state.

  The function:
  1. Upserts each task (insert or update by dag_id + task_id)
  2. Deletes any existing tasks not present in the incoming list
  3. Updates the DAG's layout
  """
  def save_graph(dag_id, tasks_params, layout) do
    Repo.transaction(fn ->
      # 1. Get existing task_ids for this DAG
      existing_task_ids =
        DagTask
        |> where(dag_id: ^dag_id)
        |> select([t], t.task_id)
        |> Repo.all()
        |> MapSet.new()

      incoming_task_ids =
        tasks_params
        |> Enum.map(& &1["task_id"])
        |> MapSet.new()

      # 2. Delete tasks that were removed from the graph
      removed_ids = MapSet.difference(existing_task_ids, incoming_task_ids)

      if MapSet.size(removed_ids) > 0 do
        removed_list = MapSet.to_list(removed_ids)

        from(t in DagTask, where: t.dag_id == ^dag_id and t.task_id in ^removed_list)
        |> Repo.delete_all()
      end

      # 3. Upsert each task
      Enum.each(tasks_params, fn task_params ->
        task_attrs = %{
          task_id: task_params["task_id"],
          dag_id: dag_id,
          task_type: task_params["task_type"] || "task",
          downstream_list: task_params["downstream_list"] || [],
          source_code: task_params["source_code"],
          source_language: task_params["source_language"] || "python",
          pool: task_params["pool"] || "default_pool",
          pool_slots: task_params["pool_slots"] || 1,
          priority_weight: task_params["priority_weight"] || 1,
          queue: task_params["queue"] || "default",
          max_tries: task_params["max_tries"] || 0,
          retries: task_params["retries"] || 0
        }

        case Repo.get_by(DagTask, dag_id: dag_id, task_id: task_attrs.task_id) do
          nil ->
            %DagTask{}
            |> DagTask.changeset(task_attrs)
            |> Repo.insert!()

          existing ->
            existing
            |> DagTask.changeset(task_attrs)
            |> Repo.update!()
        end
      end)

      # 4. Update the DAG's layout
      dag = Repo.get!(DAG, dag_id)

      dag
      |> DAG.changeset(%{layout: layout || %{}})
      |> Repo.update!()
    end)
  end
end

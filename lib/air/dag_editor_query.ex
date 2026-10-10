defmodule Air.DagEditorQuery do
  @moduledoc """
  Query/context module for the visual DAG editor — loading a DAG with
  its tasks for the canvas, and saving the graph back (transactional
  upsert of tasks + deletion of removed ones + layout update on the DAG).
  """

  import Ecto.Query
  alias Air.{DAG, DagRun, DagTask, Repo, TaskInstance}

  @doc """
  Loads a DAG and all its tasks, returning a map ready for the editor. A
  soft-deleted DAG (deleted_at set) is treated as not found, same as a
  genuinely nonexistent id — deleted DAGs never appear through normal
  queries.

  Returns `{:ok, %{dag: %DAG{}, tasks: [%DagTask{}]}}` or `{:error, :not_found}`.
  """
  def get_dag_with_tasks(dag_id) do
    case Repo.get(DAG, dag_id) do
      nil ->
        {:error, :not_found}

      %DAG{deleted_at: deleted_at} when not is_nil(deleted_at) ->
        {:error, :not_found}

      dag ->
        tasks =
          DagTask
          |> where([t], t.dag_id == ^dag_id and is_nil(t.deleted_at))
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
  Lists all non-deleted DAGs (for a DAG picker/selector/list page).
  """
  def list_dags do
    DAG
    |> where([d], is_nil(d.deleted_at))
    |> order_by(:dag_id)
    |> Repo.all()
  end

  @doc """
  Lists non-deleted DAGs whose id, title, description, owner, or labels
  match `query` (case-insensitive substring match; labels match if any
  entry contains the term). Blank/nil `query` returns every non-deleted
  DAG, same as `list_dags/0`.
  """
  def search_dags(query) when query in [nil, ""] do
    list_dags()
  end

  def search_dags(query) do
    escaped =
      query
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    term = "%#{escaped}%"

    DAG
    |> where([d], is_nil(d.deleted_at))
    |> where(
      [d],
      ilike(d.dag_id, ^term) or
        ilike(d.title, ^term) or
        ilike(d.description, ^term) or
        ilike(d.owner, ^term) or
        fragment("EXISTS (SELECT 1 FROM unnest(?) AS label WHERE label ILIKE ?)", d.labels, ^term)
    )
    |> order_by(:dag_id)
    |> Repo.all()
  end

  @doc """
  Soft-deletes a DAG and its tasks (sets `deleted_at` on both) — hidden
  from every normal query from this point on, but left in the database for
  `Air.DagRetentionJob` to hard-delete (along with its run history) 30
  days later. Run history (dag_run/task_instance) is intentionally left
  alone until the actual purge, not marked deleted now — nothing queries
  runs by a "not deleted" DAG filter today, and keeping them as-is means a
  restore (if ever added) wouldn't need to also resurrect run history
  separately. Returns `{:ok, %DAG{}}` or `{:error, :not_found}`.
  """
  def delete_dag(dag_id) do
    case Repo.get(DAG, dag_id) do
      nil ->
        {:error, :not_found}

      %DAG{deleted_at: deleted_at} when not is_nil(deleted_at) ->
        {:error, :not_found}

      dag ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Repo.transaction(fn ->
          from(t in DagTask, where: t.dag_id == ^dag_id) |> Repo.update_all(set: [deleted_at: now])
          dag |> Ecto.Changeset.change(deleted_at: now) |> Repo.update!()
        end)
    end
  end

  @doc """
  Permanently deletes every DAG (and its tasks/runs/task_instances) that
  was soft-deleted more than `older_than_days` days ago. Used by
  `Air.DagRetentionJob`'s periodic sweep; exposed as its own function so it
  can be called/tested independently of the job's scheduling. Returns the
  number of DAGs purged.
  """
  def purge_deleted_dags(older_than_days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-older_than_days, :day)

    dag_ids =
      DAG
      |> where([d], not is_nil(d.deleted_at) and d.deleted_at < ^cutoff)
      |> select([d], d.dag_id)
      |> Repo.all()

    Enum.each(dag_ids, fn dag_id ->
      Repo.transaction(fn ->
        from(ti in TaskInstance, where: ti.dag_id == ^dag_id) |> Repo.delete_all()
        from(r in DagRun, where: r.dag_id == ^dag_id) |> Repo.delete_all()
        from(t in DagTask, where: t.dag_id == ^dag_id) |> Repo.delete_all()
        from(d in DAG, where: d.dag_id == ^dag_id) |> Repo.delete_all()
      end)
    end)

    length(dag_ids)
  end

  @doc """
  Serializes a DAG (its editable properties, not run history/stats) plus
  every one of its tasks to a plain map ready for `Jason.encode!/1` — the
  "Copy" side of the DAG list page's copy/paste. Deliberately omits
  `dag_id` (reassigned on paste to whatever new id the user picks),
  `layout` (canvas positions tied to the original DAG's own coordinate
  space — pasting a copy auto-arranges instead), and
  `created_by`/`updated_by`/timestamps (no auth system yet, and a copy's
  provenance is a fresh creation, not the original's). Returns `nil` if
  the DAG doesn't exist.
  """
  def export_dag_json(dag_id) do
    case get_dag_with_tasks(dag_id) do
      {:error, :not_found} ->
        nil

      {:ok, %{dag: dag, tasks: tasks}} ->
        %{
          title: dag.title,
          description: dag.description,
          owner: dag.owner,
          maintainers: dag.maintainers,
          supporters: dag.supporters,
          labels: dag.labels,
          source_code: dag.source_code,
          source_language: dag.source_language,
          tasks: Enum.map(tasks, &export_task/1)
        }
    end
  end

  defp export_task(task) do
    %{
      task_id: task.task_id,
      task_type: task.task_type,
      downstream_list: task.downstream_list,
      source_code: task.source_code,
      source_language: task.source_language,
      pool: task.pool,
      pool_slots: task.pool_slots,
      priority_weight: task.priority_weight,
      queue: task.queue,
      max_tries: task.max_tries,
      retries: task.retries
    }
  end

  @doc """
  Creates a new DAG with id `new_dag_id` from a map previously produced by
  `export_dag_json/1` (string or atom keys both accepted, since it may have
  round-tripped through `Jason.decode!/1`). Inserts the DAG and all its
  tasks in one transaction. Returns `{:ok, %DAG{}}` or `{:error,
  changeset}` — typically a blank/duplicate `new_dag_id` or an invalid
  task.
  """
  def import_dag_from_json(new_dag_id, %{} = data) do
    Repo.transaction(fn ->
      dag_attrs = %{
        dag_id: new_dag_id,
        title: get(data, :title) || "Copy of DAG",
        description: get(data, :description),
        owner: get(data, :owner),
        maintainers: get(data, :maintainers) || [],
        supporters: get(data, :supporters) || [],
        labels: get(data, :labels) || [],
        source_code: get(data, :source_code),
        source_language: get(data, :source_language) || "python"
      }

      dag =
        case %DAG{} |> DAG.changeset(dag_attrs) |> Repo.insert() do
          {:ok, dag} -> dag
          {:error, changeset} -> Repo.rollback(changeset)
        end

      tasks = get(data, :tasks) || []

      Enum.each(tasks, fn task_data ->
        task_attrs = %{
          task_id: get(task_data, :task_id),
          dag_id: new_dag_id,
          task_type: get(task_data, :task_type) || "task",
          downstream_list: get(task_data, :downstream_list) || [],
          source_code: get(task_data, :source_code),
          source_language: get(task_data, :source_language) || "python",
          pool: get(task_data, :pool) || "default_pool",
          pool_slots: get(task_data, :pool_slots) || 1,
          priority_weight: get(task_data, :priority_weight) || 1,
          queue: get(task_data, :queue) || "default",
          max_tries: get(task_data, :max_tries) || 0,
          retries: get(task_data, :retries) || 0
        }

        case %DagTask{} |> DagTask.changeset(task_attrs) |> Repo.insert() do
          {:ok, _task} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

      dag
    end)
  end

  # Looks up a key that may be either an atom or a string (import data may
  # arrive either way depending on whether the caller already decoded JSON
  # with string keys or built the map directly in Elixir).
  defp get(map, atom_key) do
    Map.get(map, atom_key) || Map.get(map, Atom.to_string(atom_key))
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
        |> where([t], t.dag_id == ^dag_id and is_nil(t.deleted_at))
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

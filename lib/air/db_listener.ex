defmodule Air.DbListener do
  @moduledoc """
  Listens to Postgres notifications and broadcasts them to LiveViews via PubSub.

  When task instances or DAG runs are updated in the database, this listener
  catches the notifications and forwards them to any subscribed LiveViews.
  """

  use GenServer
  require Logger

  @debounce_ms 250

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, pid} = Postgrex.Notifications.start_link(Air.Repo.config())

    # Subscribe to task_updated and dag_run_updated channels
    Postgrex.Notifications.listen(pid, "task_updated")
    Postgrex.Notifications.listen(pid, "dag_run_updated")

    {:ok, %{
      listener_pid: pid,
      pending_tasks: %{},      # Map of run_id -> list of task updates
      pending_runs: %{}        # Map of run_id -> run update
    }}
  end

  @impl true
  def handle_info({:notification, _pid, _ref, "task_updated", payload}, state) do
    case Jason.decode(payload) do
      {:ok, task_data} ->
        run_id = task_data["run_id"]
        new_state = accumulate_task_update(state, run_id, task_data)
        reply_with_timeout(new_state)
      {:error, _} ->
        Logger.warning("Failed to decode task_updated notification: #{payload}")
        reply_with_timeout(state)
    end
  end

  def handle_info({:notification, _pid, _ref, "dag_run_updated", payload}, state) do
    case Jason.decode(payload) do
      {:ok, run_data} ->
        run_id = run_data["run_id"]
        new_state = accumulate_run_update(state, run_id, run_data)
        reply_with_timeout(new_state)
      {:error, _} ->
        Logger.warning("Failed to decode dag_run_updated notification: #{payload}")
        reply_with_timeout(state)
    end
  end

  def handle_info({:notification, _pid, _ref, channel, payload}, state) do
    Logger.debug("Received notification on channel #{channel}: #{payload}")
    reply_with_timeout(state)
  end

  # Timeout fired — flush all accumulated updates
  def handle_info(:timeout, state) do
    new_state = flush_all_updates(state)
    reply_with_timeout(new_state)
  end

  # Helper to always set timeout if there are pending updates
  defp reply_with_timeout(state) do
    has_pending = map_size(state.pending_tasks) > 0 or map_size(state.pending_runs) > 0
    if has_pending do
      {:noreply, state, @debounce_ms}
    else
      {:noreply, state}
    end
  end

  defp accumulate_task_update(state, run_id, task_data) do
    # Add task to pending list
    pending_tasks = Map.update(state.pending_tasks, run_id, [task_data], &[task_data | &1])
    %{state | pending_tasks: pending_tasks}
  end

  defp accumulate_run_update(state, run_id, run_data) do
    # Store run update (overwriting any previous one for this run)
    pending_runs = Map.put(state.pending_runs, run_id, run_data)
    %{state | pending_runs: pending_runs}
  end

  defp flush_all_updates(state) do
    # Flush all pending tasks
    Enum.each(state.pending_tasks, fn {run_id, tasks} ->
      # Reverse to restore original order (we prepended). Key by
      # "task_id" (the string task name, e.g. "start_data_pipeline"),
      # NOT "id" (the integer DB row ID) — the formatted execution's
      # task list uses task_id as its :id field (set by
      # DagExecutionQuery.format_task_instance/1), so the LiveView's
      # handle_info looks up by that string, not the row integer.
      tasks_map = Map.new(Enum.reverse(tasks), &{&1["task_id"], &1})
      Phoenix.PubSub.broadcast(Air.PubSub, "dag_run:#{run_id}", {:tasks_updated, tasks_map})
    end)

    # Flush all pending runs
    Enum.each(state.pending_runs, fn {run_id, run_data} ->
      Phoenix.PubSub.broadcast(Air.PubSub, "dag_run:#{run_id}", {:dag_run_updated, run_data})
    end)

    # Clear all pending state
    %{state | pending_tasks: %{}, pending_runs: %{}}
  end
end

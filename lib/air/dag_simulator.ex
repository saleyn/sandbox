defmodule Air.DagSimulator do
  @moduledoc """
  Shared helpers for simulating realistic DAG run data (used by both the seed
  script and the "Trigger Execution" demo action).

  A run's total duration is always derived from the sum of its simulated task
  durations, rather than picked independently — so it never disagrees with
  the success/failed time breakdown shown in the stacked bar chart (which
  would otherwise overflow past 100%), and it stays naturally similar from
  run to run, since it's a sum over ~20 tasks, without needing artificial
  per-run jitter.
  """

  @task_durations_ms [300_000, 600_000, 900_000, 1_200_000]

  @doc """
  Builds a simulated execution plan for a run: one map per task, each with a
  randomized duration/status and sequential start/end times beginning at
  `run_start`. Task statuses are weighted so most tasks succeed; when
  `run_status` is `:failed`, failures are more likely.
  """
  def build_task_plan(dag_tasks, run_start, run_status) do
    dag_tasks
    |> Enum.with_index()
    |> Enum.map(fn {task, idx} ->
      duration_ms = Enum.random(@task_durations_ms)
      start_time = DateTime.add(run_start, idx * 60, :second)
      end_time = DateTime.add(start_time, div(duration_ms, 1000), :second)

      %{
        task_id: task.task_id,
        start_time: start_time,
        end_time: end_time,
        duration_ms: duration_ms,
        status: random_task_status(run_status)
      }
    end)
  end

  @doc "Sums the `duration_ms` of every entry in a task plan."
  def total_duration_ms(task_plan) do
    Enum.sum(Enum.map(task_plan, & &1.duration_ms))
  end

  @doc """
  Derives an overall run status from a task plan: `:failed` if any task
  failed, `:success` otherwise.
  """
  def overall_status(task_plan) do
    if Enum.any?(task_plan, &(&1.status == :failed)), do: :failed, else: :success
  end

  defp random_task_status(run_status) do
    cond do
      run_status == :failed and Enum.random(1..100) < 30 -> :failed
      run_status == :failed -> :success
      Enum.random(1..100) < 80 -> :success
      Enum.random(1..100) < 15 -> :failed
      true -> :skipped
    end
  end
end

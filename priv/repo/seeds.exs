# Script for populating the database with DAG execution history data.
#
# Run it as:
#     mix run priv/repo/seeds.exs
#
# This creates:
#   - 1 example DAG with 12 tasks (the editor/demo UI is easier to read with
#     a small graph; 12 is the cap for any seeded DAG)
#   - 5 DAG runs (executions) over the past 5 days
#   - Task instances for each task in each run with realistic statuses

alias Air.Repo
alias Air.DAG
alias Air.DagRun
alias Air.DagSimulator
alias Air.DagTask
alias Air.TaskInstance

# Define task names (12 max per seeded DAG — keeps the editor/demo UI
# readable without scrolling/zooming out).
task_names = [
  "push_config_params",
  "start_data_pipeline",
  "start_branch_normal",
  "start_branch_cdc",
  "create_emr_cluster_normal",
  "create_emr_cluster_cdc",
  "add_step_to_write_data_to_s3_normal",
  "add_step_to_write_data_to_s3_cdc",
  "paths_merge",
  "terminate_cluster",
  "count_records",
  "end_data_pipeline"
]

# Helper function to determine downstream tasks for the DAG, by index into
# task_names above — condensed normal/CDC branch-and-merge shape. Returns
# real task_ids (task_names entries), not placeholder "task_N" strings, so
# downstream_list actually references tasks that exist (a prior version of
# this seed used "task_1"/"task_2"/etc. placeholders that matched nothing,
# silently producing a DAG with zero edges).
get_downstream_tasks = fn idx, names ->
  downstream_indices =
    case idx do
      0 -> [1]
      1 -> [2, 3]
      2 -> [4]
      3 -> [5]
      4 -> [6]
      5 -> [7]
      6 -> [8]
      7 -> [8]
      8 -> [9]
      9 -> [10]
      10 -> [11]
      11 -> []
      _ -> []
    end

  Enum.map(downstream_indices, fn i -> %{"task_id" => Enum.at(names, i), "data_size" => "M"} end)
end

# Clear existing data
IO.puts("🗑️  Cleaning up existing data...")
Repo.delete_all(TaskInstance)
Repo.delete_all(DagRun)
Repo.delete_all(DagTask)
Repo.delete_all(DAG)

# Create DAG
IO.puts("📊 Creating DAG...")

dag_attrs = %{
  dag_id: "example_data_pipeline",
  title: "Example Data Pipeline",
  description: "Example DAG showing data processing pipeline with normal and CDC branches",
  owner: "data_team",
  maintainers: ["alice@example.com", "bob@example.com"],
  supporters: ["carol@example.com"],
  labels: ["data-pipeline", "nightly"],
  is_paused: false,
  source_language: "python",
  source_code: """
  # Entry point invoked by the scheduler before building the task graph.
  def configure(context):
      context.set_param("environment", "production")
  """
}

{:ok, dag} = Repo.insert(DAG.changeset(%DAG{}, dag_attrs))

# Create DAG tasks
IO.puts("📝 Creating #{length(task_names)} DAG tasks...")

dag_tasks =
  task_names
  |> Enum.with_index()
  |> Enum.map(fn {task_name, idx} ->
    {:ok, task} =
      Repo.insert(
        DagTask.changeset(%DagTask{}, %{
          task_id: task_name,
          dag_id: dag.dag_id,
          task_type: "PythonOperator",
          downstream_list: get_downstream_tasks.(idx, task_names)
        })
      )

    task
  end)

IO.puts("✓ Created #{length(dag_tasks)} DAG tasks")

# Generate 5 DAG runs with various statuses
IO.puts("🏃 Creating 5 DAG runs with task instances...")

base_time = DateTime.utc_now() |> DateTime.add(-5, :day)

dag_runs =
  Enum.map(0..4, fn i ->
    run_start = DateTime.add(base_time, i * 86400, :second)

    # Bias every 3rd run toward failure, then simulate each task and derive
    # the run's actual status/duration from the resulting task plan.
    status_bias = if rem(i, 3) == 0, do: :failed, else: :success
    task_plan = DagSimulator.build_task_plan(dag_tasks, run_start, status_bias)
    duration_ms = DagSimulator.total_duration_ms(task_plan)
    run_status = DagSimulator.overall_status(task_plan)
    run_end = DateTime.add(run_start, div(duration_ms, 1000), :second)

    {:ok, run} =
      Repo.insert(
        DagRun.changeset(%DagRun{}, %{
          run_id: "dag_run_#{DateTime.to_iso8601(run_start) |> String.replace(~r/[^0-9]/, "")}",
          dag_id: dag.dag_id,
          status: run_status,
          start_time: run_start,
          end_time: run_end,
          duration_ms: duration_ms,
          data_interval_start: run_start,
          data_interval_end: run_end,
          run_type: "scheduled"
        })
      )

    # Create a task instance for each entry in the simulated task plan
    Enum.each(task_plan, fn task ->
      {:ok, _instance} =
        Repo.insert(
          TaskInstance.changeset(%TaskInstance{}, %{
            task_id: task.task_id,
            run_id: run.run_id,
            dag_id: dag.dag_id,
            status: task.status,
            start_time: task.start_time,
            end_time: task.end_time,
            duration_ms: task.duration_ms,
            try_number: 1,
            max_tries: 0,
            hostname: "worker-#{Enum.random(1..3)}"
          })
        )
    end)

    run
  end)

IO.puts("✓ Created #{length(dag_runs)} DAG runs with task instances")

IO.puts("""
✅ Seed data created successfully!

Summary:
  - DAG: #{dag.dag_id}
  - Tasks: #{length(dag_tasks)}
  - Runs: #{length(dag_runs)}
  - Total Task Instances: #{length(dag_runs) * length(dag_tasks)}

View the visualization at: http://localhost:4000/demo/dag-execution-history
""")

# Script for populating the database with DAG execution history data.
#
# Run it as:
#     mix run priv/repo/seeds.exs
#
# This creates:
#   - 1 example DAG with 23 tasks
#   - 5 DAG runs (executions) over the past 5 days
#   - Task instances for each task in each run with realistic statuses

alias Air.Repo
alias Air.DAG
alias Air.DagRun
alias Air.DagSimulator
alias Air.DagTask
alias Air.TaskInstance

# Helper function to determine downstream tasks for the DAG.
# Each entry is a map with task_id + data_size (the connection metadata).
get_downstream_tasks = fn idx, _total ->
  downstream_ids =
    case idx do
      0 -> ["task_1", "task_2"]
      1 -> ["task_2"]
      2 -> ["task_3", "task_4"]
      3 -> ["task_5"]
      4 -> ["task_6"]
      5 -> ["task_7", "task_8", "task_9"]
      8 -> ["task_10", "task_11"]
      9 -> ["task_12"]
      10 -> ["task_13"]
      11 -> ["task_14"]
      12 -> ["task_15", "task_16"]
      15 -> ["task_17", "task_18"]
      16 -> ["task_19"]
      17 -> ["task_20", "task_21", "task_22"]
      21 -> ["task_22"]
      22 -> []
      _ -> []
    end

  Enum.map(downstream_ids, fn tid -> %{"task_id" => tid, "data_size" => "M"} end)
end

# Clear existing data
IO.puts("🗑️  Cleaning up existing data...")
Repo.delete_all(TaskInstance)
Repo.delete_all(DagRun)
Repo.delete_all(DagTask)
Repo.delete_all(DAG)

# Define task names
task_names = [
  "push_config_params",
  "start_data_pipeline",
  "choose_normal_or_cdc",
  "start_branch_normal",
  "create_emr_cluster_normal",
  "add_step_to_write_data_to_s3_normal",
  "monitor_AU_IN_normal_job",
  "monitor_EU_IN_normal_job",
  "monitor_US_CA_normal_job",
  "start_branch_cdc",
  "create_emr_cluster_cdc",
  "add_step_to_write_data_to_s3_cdc",
  "monitor_AU_IN_cdc_job",
  "monitor_EU_IN_cdc_job",
  "monitor_US_CA_cdc_job",
  "paths_merge",
  "terminate_cluster",
  "update_latest_denormalized_date_file_txt",
  "count_records_1",
  "count_records_2",
  "count_records_3",
  "end_data_pipeline",
  "trigger_ups_device_graph_etl_write_to_aerospike_dag"
]

# Create DAG
IO.puts("📊 Creating DAG...")

dag_attrs = %{
  dag_id: "example_data_pipeline",
  description: "Example DAG showing data processing pipeline with normal and CDC branches",
  owner: "data_team",
  is_paused: false
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
          downstream_list: get_downstream_tasks.(idx, length(task_names))
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

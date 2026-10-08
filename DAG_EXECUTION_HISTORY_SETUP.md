# DAG Execution History - Complete Setup Guide

This guide walks through the complete setup of the DAG Execution History visualization component, including database schema, seeds, and the Phoenix LiveView component.

## What Was Created

### 1. Ecto Schemas (4 files)
- `/lib/air/dag.ex` - DAG definition schema
- `/lib/air/dag_run.ex` - DAG execution run schema
- `/lib/air/dag_task.ex` - Task definition schema
- `/lib/air/task_instance.ex` - Task execution instance schema

### 2. Database Migrations (4 files)
- `/priv/repo/migrations/20261007140900_create_dags.exs`
- `/priv/repo/migrations/20261007140901_create_dag_runs.exs`
- `/priv/repo/migrations/20261007140902_create_dag_tasks.exs`
- `/priv/repo/migrations/20261007140903_create_task_instances.exs`

### 3. Data Layer
- `/lib/air/dag_execution_query.ex` - Query module for fetching execution history
- `/priv/repo/seeds.exs` - Seed file to populate demo data

### 4. UI Components
- `/lib/air_web/components/dag_execution_history.ex` - Main visualization component
- `/lib/air_web/pages/dag_execution_history_demo.ex` - Demo page (updated to use DB)

### 5. Documentation
- `/DAG_EXECUTION_HISTORY_COMPONENT.md` - Component documentation
- `/DATABASE_SCHEMA.md` - Database schema documentation
- `/DAG_EXECUTION_HISTORY_SETUP.md` - This file

## Quick Start (5 minutes)

### Step 1: Run Migrations

```bash
mix ecto.migrate
```

This creates 4 database tables:
- `dags`
- `dag_runs`
- `dag_tasks`
- `task_instances`

### Step 2: Populate Demo Data

```bash
mix run priv/repo/seeds.exs
```

Output should show:
```
✅ Seed data created successfully!

Summary:
  - DAG: example_data_pipeline
  - Tasks: 23
  - Runs: 5

View the visualization at: http://localhost:4000/demo/dag-execution-history
```

### Step 3: Start the Server

```bash
mix phx.server
```

### Step 4: View the Component

Open your browser to: http://localhost:4000/demo/dag-execution-history

## What You'll See

The demo page displays:

1. **Statistics Cards**
   - Total runs: 5
   - Successful: 3
   - Failed: 2 (one run fails every 3 runs)
   - Success rate: 60%

2. **DAG Execution Grid**
   - 5 columns (one per execution run)
   - 23 rows (one per task)
   - Small colored squares indicating task status
   - Header with run date and success/failure ratio bars

3. **Interactive Features**
   - Hover over any square to see task details (name, status, duration)
   - Click on any square to see full task details below the grid
   - Status legend showing all possible statuses

## Integration with Your App

### 1. Fetching Execution Data

```elixir
alias Air.DagExecutionQuery

# Get recent executions for a DAG
executions = DagExecutionQuery.get_recent_dag_executions("my_dag", 10)

# Get statistics
stats = DagExecutionQuery.get_dag_stats("my_dag")

# Get specific task instance
task = DagExecutionQuery.get_task_instance("run_id", "task_id")
```

### 2. Using the Component

In your LiveView:

```elixir
defmodule MyApp.DagDashboard do
  use MyApp, :live_view
  alias AirWeb.Components.DagExecutionHistory
  alias Air.DagExecutionQuery

  def mount(_params, _session, socket) do
    executions = DagExecutionQuery.get_recent_dag_executions("my_dag", 5)
    {:ok, assign(socket, executions: executions)}
  end

  def handle_event("task_clicked", %{"task_id" => id, "run_id" => run_id}, socket) do
    # Handle click - navigate or show modal
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <DagExecutionHistory.dag_execution_history
      executions={@executions}
      on_task_click={JS.push("task_clicked")}
    />
    """
  end
end
```

### 3. Inserting Execution Data

```elixir
alias Air.Repo
alias Air.DagRun
alias Air.TaskInstance

# Create a DAG run
{:ok, run} = Repo.insert(
  DagRun.changeset(%DagRun{}, %{
    run_id: "my_run_#{System.os_time(:second)}",
    dag_id: "my_dag",
    status: "running",
    start_time: DateTime.utc_now(),
    duration_ms: 0
  })
)

# Create task instances for the run
{:ok, task} = Repo.insert(
  TaskInstance.changeset(%TaskInstance{}, %{
    task_id: "my_task",
    run_id: run.run_id,
    dag_id: "my_dag",
    status: "running",
    start_time: DateTime.utc_now(),
    duration_ms: 0
  })
)

# Update task when complete
TaskInstance.changeset(task, %{
  status: "success",
  end_time: DateTime.utc_now(),
  duration_ms: 300_000
}) |> Repo.update()
```

## Database Schema Overview

### Tables Created

```sql
-- DAG definitions
CREATE TABLE dags (
  dag_id VARCHAR PRIMARY KEY,
  description TEXT,
  owner VARCHAR,
  is_paused BOOLEAN DEFAULT false,
  inserted_at TIMESTAMP,
  updated_at TIMESTAMP
);

-- DAG execution runs
CREATE TABLE dag_runs (
  run_id VARCHAR PRIMARY KEY,
  dag_id VARCHAR NOT NULL REFERENCES dags(dag_id),
  status VARCHAR NOT NULL,
  start_time TIMESTAMP NOT NULL,
  end_time TIMESTAMP,
  duration_ms INTEGER,
  ...
);

-- Task definitions
CREATE TABLE dag_tasks (
  id SERIAL PRIMARY KEY,
  task_id VARCHAR NOT NULL,
  dag_id VARCHAR NOT NULL REFERENCES dags(dag_id),
  task_type VARCHAR NOT NULL,
  ...
);

-- Task executions
CREATE TABLE task_instances (
  id SERIAL PRIMARY KEY,
  task_id VARCHAR NOT NULL,
  run_id VARCHAR NOT NULL REFERENCES dag_runs(run_id),
  dag_id VARCHAR NOT NULL REFERENCES dags(dag_id),
  status VARCHAR NOT NULL,
  ...
);
```

## Demo Data Structure

The seed file creates:

### 1 DAG
- **ID**: `example_data_pipeline`
- **Description**: Data pipeline with normal and CDC branches
- **Owner**: `data_team`
- **Tasks**: 23 (with task dependencies defined)

### 23 Tasks
```
push_config_params
start_data_pipeline
choose_normal_or_cdc
start_branch_normal
create_emr_cluster_normal
add_step_to_write_data_to_s3_normal
monitor_AU_IN_normal_job
monitor_EU_IN_normal_job
monitor_US_CA_normal_job
start_branch_cdc
create_emr_cluster_cdc
add_step_to_write_data_to_s3_cdc
monitor_AU_IN_cdc_job
monitor_EU_IN_cdc_job
monitor_US_CA_cdc_job
paths_merge
terminate_cluster
update_latest_denormalized_date_file_txt
count_records_1
count_records_2
count_records_3
end_data_pipeline
trigger_ups_device_graph_etl_write_to_aerospike_dag
```

### 5 DAG Runs
- Spread across 5 consecutive days
- Random task durations (300ms to 1.2 seconds each)
- Random task statuses (80% success, 15% failed, 5% skipped)
- Every 3rd run is marked as failed overall

### 115 Task Instances
- 5 runs × 23 tasks = 115 instances
- Each with realistic execution times and statuses
- Assigned to random worker nodes (worker-1, worker-2, worker-3)

## Troubleshooting

### Issue: "No execution data found"

**Solution**: Run the seeds first
```bash
mix run priv/repo/seeds.exs
```

### Issue: Database error "table doesn't exist"

**Solution**: Run migrations
```bash
mix ecto.migrate
```

### Issue: Compilation error about undefined modules

**Solution**: Ensure all files were created:
```bash
# Check schemas exist
ls lib/air/dag*.ex lib/air/task_instance.ex

# Check migrations exist
ls priv/repo/migrations/2026*.exs

# Check component exists
ls lib/air_web/components/dag_execution_history.ex
```

### Issue: Schema validation errors

**Solution**: Check `mix.exs` includes all dependencies (should already be there):
```elixir
{:phoenix, "~> 1.8"},
{:phoenix_ecto, "~> 4.5"},
{:ecto_sql, "~> 3.13"},
{:postgrex, ">= 0.0.0"},
```

## Performance Tips

### For Large Datasets

1. **Pagination**
   ```elixir
   # Get page 2 with 20 runs per page
   DagExecutionQuery.get_dag_executions("dag_id", limit: 20, offset: 20)
   ```

2. **Filtering by Date**
   ```elixir
   DagRun
   |> where([r], r.dag_id == "my_dag" and r.start_time > ^one_week_ago)
   |> Repo.all()
   ```

3. **Limit Preloads**
   The query module uses `:preload` strategically. For large datasets, consider manual queries.

### Monitoring Queries

Enable query logging in `config/dev.exs`:
```elixir
config :air, Air.Repo,
  log: :debug
```

## Next Steps

### Enhance the Component

1. **Add Real-Time Updates**
   - Subscribe to status changes via PubSub
   - Auto-refresh execution data

2. **Add Filtering**
   - Filter by status, date range, task name
   - Search functionality

3. **Add Export**
   - Export data as CSV
   - Generate PDF reports

### Connect Your Scheduler

Integrate with your job scheduler:

```elixir
# When a task starts in your scheduler
Air.Repo.insert!(Air.TaskInstance.changeset(%Air.TaskInstance{}, %{
  task_id: task_id,
  run_id: run_id,
  dag_id: dag_id,
  status: "running",
  start_time: DateTime.utc_now()
}))

# When a task completes
task_instance
|> Air.TaskInstance.changeset(%{
  status: "success",
  end_time: DateTime.utc_now(),
  duration_ms: elapsed_ms
})
|> Air.Repo.update!()
```

## File Checklist

- [x] `/lib/air/dag.ex` - DAG schema
- [x] `/lib/air/dag_run.ex` - DagRun schema
- [x] `/lib/air/dag_task.ex` - DagTask schema
- [x] `/lib/air/task_instance.ex` - TaskInstance schema
- [x] `/priv/repo/migrations/20261007140900_create_dags.exs` - Create dags table
- [x] `/priv/repo/migrations/20261007140901_create_dag_runs.exs` - Create dag_runs table
- [x] `/priv/repo/migrations/20261007140902_create_dag_tasks.exs` - Create dag_tasks table
- [x] `/priv/repo/migrations/20261007140903_create_task_instances.exs` - Create task_instances table
- [x] `/lib/air/dag_execution_query.ex` - Query module
- [x] `/priv/repo/seeds.exs` - Seed file
- [x] `/lib/air_web/components/dag_execution_history.ex` - Component
- [x] `/lib/air_web/pages/dag_execution_history_demo.ex` - Demo page
- [x] `/lib/air_web/router.ex` - Routes (updated)
- [x] `/DAG_EXECUTION_HISTORY_COMPONENT.md` - Component docs
- [x] `/DATABASE_SCHEMA.md` - Schema docs
- [x] `/DAG_EXECUTION_HISTORY_SETUP.md` - This file

## Summary

You now have:
- ✅ Complete database schema for DAG execution tracking
- ✅ Ecto schemas and migrations ready to deploy
- ✅ Query module for efficient data retrieval
- ✅ Production-ready Phoenix component for visualization
- ✅ Demo page with sample data
- ✅ Comprehensive documentation

**To get started:**
```bash
mix ecto.migrate
mix run priv/repo/seeds.exs
mix phx.server
# Visit http://localhost:4000/demo/dag-execution-history
```

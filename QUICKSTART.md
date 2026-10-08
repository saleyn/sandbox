# DAG Execution History - Quick Start Guide

## 30-Second Setup

```bash
# 1. Run database migrations
mix ecto.migrate

# 2. Populate with demo data
mix run priv/repo/seeds.exs

# 3. Start the server
mix phx.server

# 4. Open your browser
# http://localhost:4000/demo/dag-execution-history
```

## What You'll See

A grid showing:
- **5 columns** = execution runs (most recent on right)
- **23 rows** = tasks in the DAG
- **Colored squares** = task status (green=success, red=failed, etc.)
- **Header** = run date and success/failure ratio

Hover over any square to see task details. Click to see full information.

## File Structure

```
lib/air/
├── dag.ex                          # DAG schema
├── dag_run.ex                      # DAG run schema
├── dag_task.ex                     # Task schema
├── task_instance.ex                # Task execution schema
└── dag_execution_query.ex          # Query helpers

lib/air_web/
├── components/
│   └── dag_execution_history.ex   # Main component
└── pages/
    └── dag_execution_history_demo.ex  # Demo page

priv/repo/
├── migrations/
│   ├── 20261007140900_create_dags.exs
│   ├── 20261007140901_create_dag_runs.exs
│   ├── 20261007140902_create_dag_tasks.exs
│   └── 20261007140903_create_task_instances.exs
└── seeds.exs                       # Demo data
```

## Use in Your App

### Option 1: Quick Copy (with demo data)
```elixir
alias AirWeb.Components.DagExecutionHistory
alias Air.DagExecutionQuery

def mount(_params, _session, socket) do
  executions = DagExecutionQuery.get_recent_dag_executions("my_dag", 5)
  {:ok, assign(socket, executions: executions)}
end

def render(assigns) do
  ~H"""
  <DagExecutionHistory.dag_execution_history
    executions={@executions}
    on_task_click={JS.push("task_clicked")}
  />
  """
end
```

### Option 2: Integrate with Your Scheduler

When a task **starts**:
```elixir
Air.Repo.insert!(Air.TaskInstance.changeset(%Air.TaskInstance{}, %{
  task_id: "my_task",
  run_id: "my_run_#{System.os_time(:second)}",
  dag_id: "my_dag",
  status: "running",
  start_time: DateTime.utc_now()
}))
```

When a task **completes**:
```elixir
task
|> Air.TaskInstance.changeset(%{
  status: "success",
  end_time: DateTime.utc_now(),
  duration_ms: elapsed_ms
})
|> Air.Repo.update!()
```

## Available Queries

```elixir
# Get recent executions
Air.DagExecutionQuery.get_recent_dag_executions("dag_id", count)

# Get with custom options
Air.DagExecutionQuery.get_dag_executions("dag_id", limit: 20, offset: 0)

# Get statistics
stats = Air.DagExecutionQuery.get_dag_stats("dag_id")
# Returns: %{total_runs, successful_runs, failed_runs, success_rate, avg_duration_ms}

# Get specific task
task = Air.DagExecutionQuery.get_task_instance("run_id", "task_id")

# Get all tasks in a run
tasks = Air.DagExecutionQuery.get_run_task_instances("run_id")
```

## Task Statuses

```
:success           - Task completed successfully (Green)
:failed            - Task execution failed (Red)
:upstream_failed   - Dependency failed (Dark Red)
:running           - Task is currently running (Blue)
:queued            - Waiting to run (Yellow)
:skipped           - Task was skipped (Amber)
```

## Component Props

```heex
<.dag_execution_history
  executions={@executions}        # List of execution objects
  on_task_click={JS.push(...)}    # Optional: click handler
  class="rounded-lg shadow-xl"    # Optional: extra CSS
/>
```

## Expected Data Shape

```elixir
executions = [
  %{
    id: "run_1",
    dag_id: "my_dag",
    start_time: ~U[2026-10-07 10:00:00Z],
    end_time: ~U[2026-10-07 10:30:00Z],
    duration_ms: 1_800_000,
    status: :success,
    tasks: [
      %{
        id: "task_1",
        name: "extract_data",
        start_time: ~U[2026-10-07 10:00:00Z],
        end_time: ~U[2026-10-07 10:05:00Z],
        duration_ms: 300_000,
        status: :success,
        run_id: "run_1"
      },
      # ... more tasks
    ]
  },
  # ... more runs
]
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Table doesn't exist" | Run `mix ecto.migrate` |
| "No execution data found" | Run `mix run priv/repo/seeds.exs` |
| Tasks not showing | Check data has `tasks` array populated |
| Component not rendering | Verify `executions` attribute is provided |
| Styling looks wrong | Ensure Tailwind is compiled: `mix tailwind air` |

## Next Steps

1. **Run migrations**: `mix ecto.migrate`
2. **Add demo data**: `mix run priv/repo/seeds.exs`
3. **Start server**: `mix phx.server`
4. **View demo**: http://localhost:4000/demo/dag-execution-history
5. **Read full docs**: See `DAG_EXECUTION_HISTORY_COMPONENT.md`
6. **Check schema**: See `DATABASE_SCHEMA.md`
7. **Integrate with your app**: See `DAG_EXECUTION_HISTORY_SETUP.md`

## Common Customizations

### Change colors
Edit `/lib/air_web/components/dag_execution_history.ex`, function `task_status_square/1`

### Change grid size
Adjust in demo page or increase `limit` in `DagExecutionQuery.get_recent_dag_executions/2`

### Add filtering
Enhance the query module to accept status/date filters

### Real-time updates
Subscribe to database changes via Phoenix.PubSub and reload data

## What's Included

✅ **4 Ecto Schemas** - Complete data models
✅ **4 Database Migrations** - Production-ready schema
✅ **Query Module** - Efficient data retrieval
✅ **Phoenix Component** - Reusable UI
✅ **Demo Page** - Fully functional example
✅ **Demo Data** - 115 pre-populated records
✅ **Complete Docs** - 4 documentation files

**Total: 16 files, ~70KB of code and documentation**

## File Checklist

- [x] `/lib/air/dag.ex`
- [x] `/lib/air/dag_run.ex`
- [x] `/lib/air/dag_task.ex`
- [x] `/lib/air/task_instance.ex`
- [x] `/lib/air/dag_execution_query.ex`
- [x] `/lib/air_web/components/dag_execution_history.ex`
- [x] `/lib/air_web/pages/dag_execution_history_demo.ex`
- [x] `/priv/repo/migrations/20261007140900_create_dags.exs`
- [x] `/priv/repo/migrations/20261007140901_create_dag_runs.exs`
- [x] `/priv/repo/migrations/20261007140902_create_dag_tasks.exs`
- [x] `/priv/repo/migrations/20261007140903_create_task_instances.exs`
- [x] `/priv/repo/seeds.exs`
- [x] `/DAG_EXECUTION_HISTORY_COMPONENT.md`
- [x] `/DATABASE_SCHEMA.md`
- [x] `/DAG_EXECUTION_HISTORY_SETUP.md`
- [x] `/IMPLEMENTATION_SUMMARY.md`
- [x] `/QUICKSTART.md` (this file)

---

**Ready to go!** 🚀
Run the 3 commands above and you'll have a working DAG execution history visualization.

# DAG Execution History - Database Schema

This document describes the database schema for storing and querying DAG execution history.

## Overview

The schema consists of 4 main tables:
- `dags` - DAG definitions
- `dag_runs` - Individual DAG executions
- `dag_tasks` - Task definitions within a DAG
- `task_instances` - Individual task executions within a DAG run

## Schema Diagrams

### Relationships

```
DAG (dags)
  ├── has_many DagRun (dag_runs)
  │   └── has_many TaskInstance (task_instances)
  └── has_many DagTask (dag_tasks)
      └── has_many TaskInstance (task_instances)
```

## Table Definitions

### `dags` Table

Stores DAG (Directed Acyclic Graph) definitions.

| Column | Type | Constraints | Description |
|--------|------|-----------|-------------|
| `dag_id` | string | PRIMARY KEY, UNIQUE | Unique identifier for the DAG |
| `description` | text | | Detailed description of the DAG's purpose |
| `owner` | string | | Team or person responsible for the DAG |
| `is_paused` | boolean | DEFAULT: false | Whether the DAG is paused from scheduling |
| `inserted_at` | utc_datetime | | Record creation timestamp |
| `updated_at` | utc_datetime | | Last update timestamp |

**Indexes:**
- `dag_id` (UNIQUE PRIMARY KEY)

**Example:**
```elixir
%{
  dag_id: "example_data_pipeline",
  description: "Data pipeline for processing and analytics",
  owner: "data_team",
  is_paused: false
}
```

### `dag_runs` Table

Stores individual DAG execution runs.

| Column | Type | Constraints | Description |
|--------|------|-----------|-------------|
| `run_id` | string | PRIMARY KEY, UNIQUE | Unique identifier for this run |
| `dag_id` | string | FOREIGN KEY, NOT NULL | References `dags.dag_id` |
| `status` | string | NOT NULL | Enum: success, failed, running, queued, skipped |
| `start_time` | utc_datetime | NOT NULL | When the run started |
| `end_time` | utc_datetime | | When the run ended |
| `duration_ms` | integer | | Total execution time in milliseconds |
| `data_interval_start` | utc_datetime | | Data processing period start |
| `data_interval_end` | utc_datetime | | Data processing period end |
| `run_type` | string | DEFAULT: "manual" | How the run was triggered (scheduled, manual, etc.) |
| `notes` | text | | Additional information about the run |
| `inserted_at` | utc_datetime | | Record creation timestamp |
| `updated_at` | utc_datetime | | Last update timestamp |

**Indexes:**
- `run_id` (UNIQUE PRIMARY KEY)
- `dag_id` (for querying runs by DAG)
- `status` (for filtering by status)
- `start_time` (for sorting by execution date)

**Example:**
```elixir
%{
  run_id: "dag_run_20261007120000",
  dag_id: "example_data_pipeline",
  status: "success",
  start_time: ~U[2026-10-07 12:00:00Z],
  end_time: ~U[2026-10-07 12:30:00Z],
  duration_ms: 1_800_000,
  run_type: "scheduled"
}
```

### `dag_tasks` Table

Stores task definitions within a DAG.

| Column | Type | Constraints | Description |
|--------|------|-----------|-------------|
| `id` | integer | PRIMARY KEY | Auto-incrementing ID |
| `task_id` | string | NOT NULL | Human-readable task identifier |
| `dag_id` | string | FOREIGN KEY, NOT NULL | References `dags.dag_id` |
| `task_type` | string | NOT NULL | Type of task (PythonOperator, BashOperator, etc.) |
| `downstream_list` | array[string] | DEFAULT: [] | Task IDs that depend on this task |
| `pool` | string | DEFAULT: "default_pool" | Resource pool for task execution |
| `pool_slots` | integer | DEFAULT: 1 | Number of pool slots required |
| `priority_weight` | integer | DEFAULT: 1 | Execution priority |
| `queue` | string | DEFAULT: "default" | Task queue name |
| `max_tries` | integer | DEFAULT: 0 | Maximum retry attempts |
| `retries` | integer | DEFAULT: 0 | Current retry count |
| `inserted_at` | utc_datetime | | Record creation timestamp |
| `updated_at` | utc_datetime | | Last update timestamp |

**Unique Constraint:**
- `(dag_id, task_id)` - Each DAG can only have one task with a given ID

**Indexes:**
- `(dag_id, task_id)` (UNIQUE)
- `dag_id` (for fetching DAG tasks)
- `task_id` (for task lookup)

**Example:**
```elixir
%{
  task_id: "extract_data",
  dag_id: "example_data_pipeline",
  task_type: "PythonOperator",
  downstream_list: ["transform_data", "validate_data"],
  pool: "default_pool",
  pool_slots: 1,
  priority_weight: 10,
  max_tries: 2
}
```

### `task_instances` Table

Stores individual task executions within DAG runs.

| Column | Type | Constraints | Description |
|--------|------|-----------|-------------|
| `id` | integer | PRIMARY KEY | Auto-incrementing ID |
| `task_id` | string | NOT NULL | References `dag_tasks.task_id` |
| `run_id` | string | FOREIGN KEY, NOT NULL | References `dag_runs.run_id` |
| `dag_id` | string | FOREIGN KEY, NOT NULL | References `dags.dag_id` |
| `status` | string | NOT NULL | Enum: success, failed, upstream_failed, running, queued, skipped |
| `start_time` | utc_datetime | | When the task started |
| `end_time` | utc_datetime | | When the task ended |
| `duration_ms` | integer | | Execution time in milliseconds |
| `try_number` | integer | DEFAULT: 1 | Which retry attempt this is |
| `max_tries` | integer | DEFAULT: 0 | Maximum retries for this task |
| `hostname` | string | | Worker node that executed the task |
| `logs` | text | | Task execution logs (can be very large) |
| `notes` | text | | Additional task information |
| `inserted_at` | utc_datetime | | Record creation timestamp |
| `updated_at` | utc_datetime | | Last update timestamp |

**Unique Constraint:**
- `(run_id, task_id, try_number)` - One instance per task per run per attempt

**Indexes:**
- `(run_id, task_id, try_number)` (UNIQUE)
- `dag_id` (for DAG queries)
- `run_id` (for run queries)
- `task_id` (for task queries)
- `status` (for filtering by status)
- `start_time` (for time-based queries)

**Example:**
```elixir
%{
  task_id: "extract_data",
  run_id: "dag_run_20261007120000",
  dag_id: "example_data_pipeline",
  status: "success",
  start_time: ~U[2026-10-07 12:00:00Z],
  end_time: ~U[2026-10-07 12:05:00Z],
  duration_ms: 300_000,
  try_number: 1,
  hostname: "worker-1"
}
```

## Ecto Schemas

### Air.DAG
```elixir
defmodule Air.DAG do
  use Ecto.Schema

  schema "dags" do
    field :dag_id, :string
    field :description, :string
    field :owner, :string
    field :is_paused, :boolean, default: false

    has_many :runs, Air.DagRun, foreign_key: :dag_id, references: :dag_id
    has_many :tasks, Air.DagTask, foreign_key: :dag_id, references: :dag_id

    timestamps(type: :utc_datetime)
  end
end
```

### Air.DagRun
```elixir
defmodule Air.DagRun do
  use Ecto.Schema

  schema "dag_runs" do
    field :run_id, :string
    field :dag_id, :string
    field :status, Ecto.Enum, values: [:success, :failed, :running, :queued, :skipped]
    field :start_time, :utc_datetime
    field :end_time, :utc_datetime
    field :duration_ms, :integer
    field :data_interval_start, :utc_datetime
    field :data_interval_end, :utc_datetime
    field :run_type, :string, default: "manual"
    field :notes, :string

    belongs_to :dag, Air.DAG, foreign_key: :dag_id, references: :dag_id, define_field: false
    has_many :task_instances, Air.TaskInstance, foreign_key: :run_id, references: :run_id

    timestamps(type: :utc_datetime)
  end
end
```

### Air.DagTask
```elixir
defmodule Air.DagTask do
  use Ecto.Schema

  schema "dag_tasks" do
    field :task_id, :string
    field :dag_id, :string
    field :task_type, :string
    field :downstream_list, {:array, :string}, default: []
    field :pool, :string, default: "default_pool"
    field :pool_slots, :integer, default: 1
    field :priority_weight, :integer, default: 1
    field :queue, :string, default: "default"
    field :max_tries, :integer, default: 0
    field :retries, :integer, default: 0

    belongs_to :dag, Air.DAG, foreign_key: :dag_id, references: :dag_id, define_field: false
    has_many :instances, Air.TaskInstance, foreign_key: :task_id, references: :task_id

    timestamps(type: :utc_datetime)
  end
end
```

### Air.TaskInstance
```elixir
defmodule Air.TaskInstance do
  use Ecto.Schema

  schema "task_instances" do
    field :task_id, :string
    field :run_id, :string
    field :dag_id, :string
    field :status, Ecto.Enum, values: [:success, :failed, :upstream_failed, :running, :queued, :skipped]
    field :start_time, :utc_datetime
    field :end_time, :utc_datetime
    field :duration_ms, :integer
    field :try_number, :integer, default: 1
    field :max_tries, :integer, default: 0
    field :hostname, :string
    field :logs, :string
    field :notes, :string

    belongs_to :run, Air.DagRun, foreign_key: :run_id, references: :run_id, define_field: false
    belongs_to :task, Air.DagTask, foreign_key: :task_id, references: :task_id, define_field: false
    belongs_to :dag, Air.DAG, foreign_key: :dag_id, references: :dag_id, define_field: false

    timestamps(type: :utc_datetime)
  end
end
```

## Setup Instructions

### 1. Create Migrations

The migration files are in `/priv/repo/migrations/`:
- `20261007140900_create_dags.exs`
- `20261007140901_create_dag_runs.exs`
- `20261007140902_create_dag_tasks.exs`
- `20261007140903_create_task_instances.exs`

### 2. Run Migrations

```bash
mix ecto.migrate
```

### 3. Populate with Demo Data

```bash
mix run priv/repo/seeds.exs
```

This creates:
- 1 example DAG with 23 tasks
- 5 DAG runs over 5 days
- 115 task instances (5 runs × 23 tasks)

### 4. View the Component

Start the server:
```bash
mix phx.server
```

Visit: http://localhost:4000/demo/dag-execution-history

## Query Examples

### Using Air.DagExecutionQuery

```elixir
# Get recent executions
executions = Air.DagExecutionQuery.get_recent_dag_executions("example_data_pipeline", 10)

# Get DAG statistics
stats = Air.DagExecutionQuery.get_dag_stats("example_data_pipeline")

# Get task instance details
task = Air.DagExecutionQuery.get_task_instance("dag_run_123", "task_name")

# Get all task instances for a run
tasks = Air.DagExecutionQuery.get_run_task_instances("dag_run_123")
```

## Performance Considerations

### Indexes

The schema includes strategic indexes for common queries:
- Query by DAG: `dag_runs(dag_id)`, `dag_tasks(dag_id)`
- Query by status: `dag_runs(status)`, `task_instances(status)`
- Query by time: `dag_runs(start_time)`, `task_instances(start_time)`
- Unique constraints prevent duplicate entries

### Best Practices

1. **Large Logs**: The `logs` field in `task_instances` can grow very large. Consider:
   - Storing logs in a separate table with foreign key reference
   - Archiving old logs to external storage
   - Compressing logs in the database

2. **History Retention**: Implement a retention policy:
   - Archive runs older than 1 year to a separate table
   - Delete task instances older than 2 years
   - Keep recent data (last 90 days) in the main tables

3. **Pagination**: When fetching many runs:
   ```elixir
   # Use limit and offset for pagination
   Air.DagExecutionQuery.get_dag_executions("dag_id", limit: 20, offset: 40)
   ```

## Future Enhancements

- Add `xcom` table for cross-task communication values
- Add `dag_dependencies` table for DAG-to-DAG dependencies
- Add `task_retry` table for retry history details
- Partitioning `task_instances` by date for better performance
- Time-series database integration for metrics

## Migration Checklist

- [x] Create Ecto schemas
- [x] Create database migrations
- [x] Create seed file for demo data
- [x] Create query module (Air.DagExecutionQuery)
- [x] Update demo LiveView to use database
- [x] Add routes and components

To verify everything is working:
```bash
# Run migrations
mix ecto.migrate

# Populate with demo data
mix run priv/repo/seeds.exs

# Start server
mix phx.server

# Visit http://localhost:4000/demo/dag-execution-history
```

# DAG Execution History Component

A Phoenix LiveView component that visualizes DAG (Directed Acyclic Graph) task execution history, similar to Apache Airflow's UI.

## Overview

The component displays a grid-based visualization where:
- **Columns** represent individual execution runs (most recent on the right)
- **Rows** represent tasks within the DAG
- **Colored squares** indicate task execution status
- **Header** shows execution dates and stacked bar charts for success/failure ratios

## Features

### Visual Elements

1. **Dark Theme Header**
   - Shows maximum duration across all executions
   - Displays date for each execution

2. **Stacked Duration Bar Chart**
   - Green section: successful task time
   - Red section: failed task time
   - Shows ratio of success vs failure in execution

3. **Task Status Grid**
   - Small colored squares for each task in each execution
   - Fixed left column with task names (alphabetically sorted)
   - Consistent color coding across all executions

4. **Interactive Tooltips**
   - Hover over any task square to see:
     - Task name
     - Status (Success, Failed, Skipped, Running, Queued)
     - Duration
     - Start time
   - Dark theme tooltip with arrow pointing to square

5. **Click Handler**
   - Click on task squares to trigger custom events
   - Can be used to open detail modals or navigate

## Status Colors

| Color | Status | Meaning |
|-------|--------|---------|
| 🟩 Green | Success | Task completed successfully |
| 🟥 Red | Failed | Task execution failed |
| 🟦 Blue | Running | Task is currently running |
| 🟨 Yellow | Queued | Task is waiting to run |
| 🟧 Orange | Skipped | Task was skipped |
| ⬜ Gray | Not Run | Task was not executed |

## Data Structure

The component expects executions with this structure:

```elixir
%{
  id: "dag_run_123",              # Unique execution ID
  dag_id: "my_dag",               # DAG identifier
  start_time: ~U[2026-10-07 10:00:00Z],  # Execution start
  end_time: ~U[2026-10-07 10:30:00Z],    # Execution end
  duration_ms: 1800000,           # Total duration in milliseconds
  status: :success,               # Overall status: :success, :failed
  tasks: [
    %{
      id: "task_1",
      name: "extract_data",       # Task name (displayed in grid)
      start_time: ~U[2026-10-07 10:00:00Z],
      end_time: ~U[2026-10-07 10:10:00Z],
      duration_ms: 600000,
      status: :success            # :success, :failed, :running, :queued, :skipped
    },
    # ... more tasks
  ]
}
```

## Usage

### Basic Usage

```heex
<.dag_execution_history
  executions={@executions}
  on_task_click={JS.push("task_clicked")}
  class="rounded-lg shadow-xl"
/>
```

### In a LiveView

```elixir
defmodule MyApp.DagDashboard do
  use MyApp, :live_view
  alias MyApp.Components.DagExecutionHistory

  def mount(_params, _session, socket) do
    executions = fetch_executions_from_db()
    {:ok, assign(socket, executions: executions)}
  end

  def handle_event("task_clicked", %{"task_id" => task_id, "run_id" => run_id}, socket) do
    # Handle task click - open details modal, navigate, etc.
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

### With Event Handling

```elixir
def handle_event("task_clicked", %{"task_id" => task_id, "run_id" => run_id}, socket) do
  # Navigate to task details
  {:noreply, push_navigate(socket, to: ~p"/tasks/#{task_id}")}

  # Or open a modal
  # {:noreply, assign(socket, show_task_modal: true, selected_task: task_id)}
end
```

## Component Attributes

| Attribute | Type | Required | Description |
|-----------|------|----------|-------------|
| `executions` | List | Yes | List of execution objects with tasks |
| `on_task_click` | JS Command | No | JS event handler for task clicks |
| `class` | String | No | Additional CSS classes for styling |

## Styling

The component uses:
- **Tailwind CSS** for layout and styling
- **Dark theme** (dark gray background with white/light text)
- **Responsive design** with horizontal scrolling for many executions
- **Fixed left column** for task names to remain visible when scrolling

### Customization

To customize colors, edit the status color mapping in `task_status_square/1`:

```elixir
{bg_color, status_text} =
  case task do
    nil -> {"bg-gray-700", "Not run"}
    %{status: :success} -> {"bg-green-500", "Success"}
    # ... customize colors here
  end
```

## Helper Functions

### `format_duration/1`
Formats milliseconds into human-readable duration:
- Input: `1800000` → Output: `"30m 0s"`
- Input: `600000` → Output: `"10m 0s"`
- Input: `45000` → Output: `"45s"`

### `format_time/1`
Formats DateTime to readable time string:
- Input: `~U[2026-10-07 10:30:45Z]` → Output: `"2026-10-07 10:30"`

### `format_date/1`
Formats DateTime to date string:
- Input: `~U[2026-10-07 10:30:45Z]` → Output: `"2026-10-07"`

## Demo

A demo page is available at `/demo/dag-execution-history` that showcases:
- 5 sample executions
- 23 different tasks
- Various status distributions
- Interactive tooltips and click handling
- Status legend

## Performance Considerations

1. **Execution Count**: Works well with 5-20 executions. Beyond that, consider:
   - Pagination
   - Filtering by date range
   - Virtual scrolling

2. **Task Count**: Handles 20-50 tasks comfortably. For more:
   - Group tasks by category
   - Filter to show only relevant tasks
   - Implement collapsible groups

3. **Rendering**: All HTML is static after initial load, making it fast and efficient.

## Accessibility

- Tooltips provide status information
- Colors have sufficient contrast
- Button states are clearly indicated
- Task names are shown on hover for truncated names

## Browser Support

Works with all modern browsers:
- Chrome/Edge (latest)
- Firefox (latest)
- Safari (latest)

## Future Enhancements

Potential improvements:
- [ ] Zoom/pan controls for large grids
- [ ] Filtering by status or task name
- [ ] Sorting tasks by name, success rate, or duration
- [ ] Export as image or CSV
- [ ] Real-time updates via WebSocket
- [ ] Task dependencies visualization
- [ ] Duration heatmap coloring
- [ ] Drill-down to execution/task details

## File Location

- **Component**: `/lib/air_web/components/dag_execution_history.ex`
- **Demo Page**: `/lib/air_web/pages/dag_execution_history_demo.ex`
- **Route**: Added to `/lib/air_web/router.ex`

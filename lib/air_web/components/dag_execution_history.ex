defmodule AirWeb.Components.DagExecutionHistory do
  @moduledoc """
  A visual component for displaying DAG tasks execution history similar to Airflow.

  Displays a grid where:
  - Each column represents an execution/run
  - Top section shows execution date and stacked bar chart (success/failure times)
  - Each row represents a task in the DAG
  - Grid cells contain small colored squares indicating task status
  - Hovering shows task details
  - Clicking opens detailed task information
  """

  use Phoenix.Component
  alias Phoenix.LiveView.JS

  @doc """
  Renders DAG execution history visualization.

  ## Attributes

  - `executions` - List of execution runs with structure:
      %{
        id: "run-123",
        dag_id: "my_dag",
        start_time: ~U[2026-10-07 10:00:00Z],
        end_time: ~U[2026-10-07 10:30:00Z],
        status: :success | :failed,
        duration_ms: 1800000,
        tasks: [
          %{
            id: "task-1",
            name: "extract_data",
            start_time: ~U[2026-10-07 10:00:00Z],
            end_time: ~U[2026-10-07 10:10:00Z],
            status: :success,
            duration_ms: 600000
          },
          ...
        ]
      }

  - `on_task_click` - name of the event to push when a task status square is clicked
    (e.g. `"task_clicked"`), or `nil`/`false` to disable click handling. The pushed
    event receives `%{"task_id" => ..., "run_id" => ...}` as params.
  - `on_run_click` - name of the event to push when a run's bar is clicked
    (e.g. `"run_clicked"`), or `nil`/`false` to disable click handling. The pushed
    event receives `%{"run_id" => ...}` as params.
  - `task_color_mode` - how strongly a task's status color is rendered:
      - `:fixed` (default) - every task square is fully opaque regardless of duration
      - `:duration` - a task square's opacity is scaled by its own duration relative
        to the longest-running task among all visible executions, so slower tasks
        render more vividly and quicker ones fade toward the background
  - `class` - Additional CSS classes
  """
  attr :id, :string, default: "dag-execution-history", doc: "Stable DOM id for the grid container"
  attr :executions, :list, required: true, doc: "List of execution runs (most recent last)"
  attr :on_task_click, :string, default: nil, doc: "Event name to push when a task square is clicked"
  attr :on_run_click, :string, default: nil, doc: "Event name to push when a run's bar is clicked"

  attr :task_color_mode, :atom,
    default: :fixed,
    values: [:fixed, :duration],
    doc: "Task square color intensity: :fixed (always full color) or :duration (proportional to task duration)"

  attr :class, :string, default: "", doc: "Additional CSS classes"

  def dag_execution_history(assigns) do
    # Get all unique tasks across executions, preserving execution order
    # (order they appear in the first execution, which is their DAG sequence order)
    all_tasks = assigns.tasks
    dag_id    = assigns.dag_id
    executions = Air.DagExecutionQuery.get_recent_dag_executions(dag_id, 5) || []

    # Calculate max duration across all executions for proportional bar sizing
    max_duration_ms =
      executions
      |> Enum.map(& &1.duration_ms)
      |> Enum.max(fn -> 0 end)

    # Calculate the longest individual task duration across all visible executions
    # (not deduped like all_tasks above, since every instance of a task name across
    # runs can have a different duration), used to normalize :duration color mode.
    max_task_duration_ms =
      executions
      |> Enum.flat_map(& &1.tasks)
      |> Enum.map(& &1.duration_ms)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0 end)

    # Pick how finely to tick the timeline stripe (hour vs. a "nice" minute
    # interval) based on how closely spaced the visible runs actually are —
    # a DAG scheduled every few minutes needs minute ticks, one scheduled a
    # few times a day doesn't.
    tick_granularity = compute_tick_granularity(executions)

    # Two-pass tick labeling:
    #
    # Pass 1: mark each execution with whether its date/time bucket
    # differs from the previous run's (same as before — dedup identical
    # consecutive ticks).
    #
    # Pass 2: suppress any tick whose previous *shown* tick was in the
    # immediately preceding column — two labels in directly adjacent
    # narrow columns overlap and look too busy. A gap of at least 2
    # columns between shown labels keeps the timeline readable.
    {executions_pass1, _} =
      Enum.map_reduce(executions, {nil, nil}, fn exec, {prev_date, prev_bucket} ->
        date = exec.start_time && DateTime.to_date(exec.start_time)
        bucket = exec.start_time && time_bucket(exec.start_time, tick_granularity)

        exec =
          exec
          |> Map.put(:show_date, date != prev_date)
          |> Map.put(:show_time, bucket != prev_bucket)
          |> Map.put(:tick_time_label, bucket && format_tick_time(bucket))

        {exec, {date, bucket}}
      end)

    # Pass 2: thin out labels that are too close together. Track the
    # column index of the last *shown* date/time label; suppress if the
    # current column is the very next one (distance of 1).
    min_gap = 2

    {executions_with_flags, _} =
      executions_pass1
      |> Enum.with_index()
      |> Enum.map_reduce({-min_gap, -min_gap}, fn {exec, col_idx}, {last_date_col, last_time_col} ->
        {show_date, new_date_col} =
          if exec.show_date and col_idx - last_date_col >= min_gap do
            {true, col_idx}
          else
            {false, last_date_col}
          end

        {show_time, new_time_col} =
          if exec.show_time and col_idx - last_time_col >= min_gap do
            {true, col_idx}
          else
            {false, last_time_col}
          end

        exec = %{exec | show_date: show_date, show_time: show_time}
        {exec, {new_date_col, new_time_col}}
      end)

    assigns =
      assigns
      |> assign(:executions, executions)
      |> assign(:all_tasks, all_tasks)
      |> assign(:max_duration_ms, max_duration_ms)
      |> assign(:max_task_duration_ms, max_task_duration_ms)
      |> assign(:executions_with_flags, executions_with_flags)

    ~H"""
    <div class={["w-full overflow-hidden bg-white dark:bg-gray-900 text-gray-900 dark:text-white rounded-lg shadow-lg", @class]}>
      <!-- Main Grid Container: a plain flex row (NOT itself scrollable) with
           two siblings — the frozen task-name column, and a second,
           independently-scrolling area for just the executions grid. Only
           the second one carries overflow-x-auto, so its native scrollbar
           spans only that area's own width and never renders underneath
           the frozen column — splitting the layout this way, rather than
           keeping both inside one shared overflow-x-auto (where the
           frozen column used to need `sticky left-0` to stay visually
           pinned while scrolling), was what fixed that. The hook is
           attached here, on the common ancestor of both siblings, since
           row/column hover-highlighting needs to match cells in either
           one. -->
      <div class="flex" phx-hook=".DagGridHover" id={@id}>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".DagGridHover">
          export default {
            mounted() {
              this.el.addEventListener("mouseover", (e) => this.hover(e))
              this.el.addEventListener("mouseout", (e) => this.clear())
            },
            hover(e) {
              const cell = e.target.closest("[data-task-name], [data-run-id]")
              if (!cell) return
              const task = cell.getAttribute("data-task-name")
              const run = cell.getAttribute("data-run-id")
              this.el.querySelectorAll(".dag-cell").forEach(el => {
                const matches =
                  (!!task && el.getAttribute("data-task-name") === task) ||
                  (!!run && el.getAttribute("data-run-id") === run)
                el.classList.toggle("dag-cell-highlight", matches)
              })
            },
            clear() {
              this.el.querySelectorAll(".dag-cell-highlight").forEach(el => el.classList.remove("dag-cell-highlight"))
            }
          }
        </script>

        <!-- Frozen Left Column with Task Names. No longer needs
             `sticky`/`left-0` — since it now lives OUTSIDE the scrolling
             area entirely (a plain flex sibling) rather than pinned
             inside one, it's simply always visible. The opaque
             background still stops anything from showing through, and
             the drop-shadow still marks the visual edge against the
             scrolling grid beside it. -->
        <!-- z-10 + relative: establishes a stacking context below the
             tooltip's z-50 in the scrollable sibling, so hover popups
             on tasks near the left edge aren't hidden behind this
             column. Without this, the frozen column (painted first in
             DOM order but with no explicit z-index) would default to
             the same stacking level as the scrollable area, and the
             drop-shadow gave it a visual "above" appearance even though
             it wasn't winning any z-fight — the real issue was
             overflow-x-auto on the scrollable sibling clipping the
             tooltip, but giving this column a *lower* explicit z keeps
             the tooltip visible when it overflows leftward past the
             column boundary. -->
        <div class="bg-gray-100 dark:bg-gray-800 flex-shrink-0 relative z-10 shadow-[4px_0_6px_-2px_rgba(0,0,0,0.15)] dark:shadow-[4px_0_6px_-2px_rgba(0,0,0,0.4)]">
          <!-- Timeline stripe header cell: left-side label for the tick
               row above the Duration axis. Height must match the
               tick-row height on the executions side (h-8) so the
               Duration header and task rows below it stay aligned
               between the frozen column and the scrolling grid. -->
          <div class="h-8 px-3 flex items-end pb-0.5">
            <p class="text-[10px] font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide">Timeline</p>
          </div>

          <!-- Header Cell: Duration axis label + tick values. Bottom border only
               (separates header from rows below); no right border here, so it
               doesn't bleed a vertical line through the header area. -->
          <div class="px-3 py-1 h-40 flex flex-col justify-between border-b border-gray-300 dark:border-gray-700">
            <p class="text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide pt-1">Duration</p>
            <div class="flex-1 flex flex-col justify-between items-end pb-1 pr-1 font-mono text-[10px] text-gray-500 leading-none text-right">
              <span><%= format_axis_duration(@max_duration_ms) %></span>
              <span><%= format_axis_duration(div(@max_duration_ms, 2)) %></span>
              <span><%= format_axis_duration(0) %></span>
            </div>
          </div>

          <!-- Task Names: right border lives here (below the header only),
               separating task names from the execution grid. -->
          <div :for={task_id <- all_tasks |> IO.inspect(label: "all_tasks")} class="border-r border-gray-300 dark:border-gray-700">
            <div
              class="dag-cell px-6 py-0 h-6 flex items-center border-b border-gray-300 dark:border-gray-700 last:border-b-0 cursor-pointer transition-opacity"
              data-task-name={task_id}
            >
              <p class="text-xs text-gray-600 dark:text-gray-300 truncate max-w-48" title={task_id}>
                {task_id}
              </p>
            </div>
          </div>
        </div>

        <%= if @executions != [] do %>
        <!-- Scrollable Executions Area: the only element in this component
             with overflow-x-auto, so the horizontal scrollbar it produces
             only ever spans this element's own width — i.e. starts right
             after the frozen column above, never underneath it. min-w-0
             lets this flex child shrink below its content's natural
             width when needed (the default min-width:auto on flex items
             would otherwise fight the sibling frozen column for space). -->
        <div class="overflow-x-auto flex-1 min-w-0 relative z-20">
          <div class="inline-flex min-w-full relative">
            <!-- Gridlines overlay aligned with the Duration axis ticks.
                 top-8 (not top-0) accounts for the timeline stripe row
                 now sitting above the h-40 bar-chart area within each
                 execution column — without that offset these lines would
                 render over the stripe instead of over the bars. -->
            <div class="absolute inset-x-0 top-8 h-40 flex flex-col justify-between pointer-events-none z-0">
              <div class="border-t border-gray-300 dark:border-gray-700"></div>
              <div class="border-t border-gray-300 dark:border-gray-700"></div>
              <div class="border-t border-gray-400 dark:border-gray-600"></div>
            </div>
            <%= for execution <- @executions_with_flags do %>
              <.execution_column
                execution={execution}
                all_tasks={@all_tasks}
                on_task_click={@on_task_click}
                on_run_click={@on_run_click}
                max_duration_ms={@max_duration_ms}
                max_task_duration_ms={@max_task_duration_ms}
                task_color_mode={@task_color_mode}
              />
            <% end %>
          </div>
        </div>
        <% else %>
        <div class="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg p-8 text-center">
          <p class="text-gray-600 dark:text-gray-400 text-lg mb-4">No execution data found for DAG: <%= @dag_id %></p>
          <p class="text-gray-500 dark:text-gray-500">Run <code class="bg-gray-100 dark:bg-gray-900 px-2 py-1 rounded">mix run priv/repo/seeds.exs</code> to populate demo data</p>
        </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp execution_column(assigns) do
    execution = assigns.execution
    duration_ms = execution.duration_ms || 0
    max_duration_ms = assigns.max_duration_ms

    # Stack the bar by time: green = sum of successful task durations,
    # red = sum of unsuccessful (failed/upstream_failed) task durations,
    # both as a percentage of this run's own duration.
    success_time = execution.tasks |> Enum.filter(&(&1.status == :success)) |> Enum.map(& &1.duration_ms) |> Enum.sum()

    unsuccessful_time =
      execution.tasks
      |> Enum.filter(&(&1.status in [:failed, :upstream_failed]))
      |> Enum.map(& &1.duration_ms)
      |> Enum.sum()

    success_percent = if duration_ms > 0, do: Float.round(success_time / duration_ms * 100, 1), else: 0
    failed_percent = if duration_ms > 0, do: Float.round(unsuccessful_time / duration_ms * 100, 1), else: 0

    # Overall bar height is proportional to the max duration among visible runs,
    # so the longest-running visible execution gets a full-height bar.
    bar_height_percent = if max_duration_ms > 0, do: Float.round(duration_ms / max_duration_ms * 100, 1), else: 0

    # Build task lookup map
    task_map = Map.new(execution.tasks, &{&1.name, &1})

    assigns =
      assigns
      |> assign(:duration_ms, duration_ms)
      |> assign(:success_percent, success_percent)
      |> assign(:failed_percent, failed_percent)
      |> assign(:bar_height_percent, bar_height_percent)
      |> assign(:task_map, task_map)

    ~H"""
    <div class="flex-shrink-0 flex flex-col relative" data-run-id={@execution.id}>
      <!-- Timeline tick stripe: two stacked lines (date + time) that
           together form a continuous axis labelling when the run occurred.
           The date line only shows when the calendar day changes from the
           previous run; the time line only shows when the time bucket
           (hour or "nice minute" interval — 15/20/30 min — depending on
           how closely spaced the visible runs are) changes. This means
           most run columns have an empty h-8 stripe (no label, just the
           reserved height to stay aligned with the frozen column's
           matching h-8 "Timeline" header cell). -->
      <!-- The tick cell itself is h-8 + relative to anchor the labels,
           but contributes NO width to the column — the labels are
           absolutely positioned so they overflow visually without
           stretching the column (a "2026-10-08" label is ~60px wide vs
           the ~24px min-w-6 task-square column). left-1/2 -translate-x-1/2
           centers them horizontally over the column's own midpoint. -->
      <div class="h-8 relative min-w-6">
        <div class="absolute bottom-0.5 left-1/2 -translate-x-1/2 flex flex-col items-center pointer-events-none">
          <%= if @execution.show_date do %>
            <span class="text-[9px] text-gray-500 dark:text-gray-400 whitespace-nowrap leading-none">
              <%= format_short_date(@execution.start_time) %>
            </span>
          <% end %>
          <%= if @execution.show_time do %>
            <span class="text-[9px] font-mono text-gray-500 dark:text-gray-400 whitespace-nowrap leading-none">
              <%= @execution.tick_time_label %>
            </span>
          <% end %>
        </div>
      </div>

      <!-- Header with stacked Vertical Bar (green=success time, red=unsuccessful time).
           The bar is anchored to the bottom of this h-40 cell via `absolute bottom-0`
           (rather than flex `justify-end`), so its bottom edge always sits exactly on
           the 00:00:00 axis line regardless of flex sizing quirks — only its height
           varies with duration, growing upward from that fixed baseline. -->
      <div
        class="dag-cell px-0.5 pb-1 min-w-6 flex-shrink-0 h-40 relative z-10 border-r border-gray-200 dark:border-gray-800"
        data-run-id={@execution.id}
      >
        <button
          type="button"
          class={[
            "absolute bottom-1 left-1/2 -translate-x-1/2 w-3 max-h-[calc(100%-0.25rem)] flex flex-col justify-end rounded-t-xs overflow-hidden shadow-sm",
            @on_run_click && "cursor-pointer hover:brightness-125"
          ]}
          style={"height: #{@bar_height_percent}%; min-height: 2px;"}
          title={"Total run time: #{format_duration(@duration_ms)} — success #{@success_percent}% / failed #{@failed_percent}%"}
          phx-click={@on_run_click && JS.push(@on_run_click, value: %{run_id: @execution.id})}
          disabled={!@on_run_click}
        >
          <%!-- justify-end: success_percent + failed_percent can be < 100% of this
               bar's own height whenever the run has skipped/other-status tasks.
               Without justify-end, that leftover gap renders at the bottom
               (default flex-col stacks from the top), making the colored
               portion float above the baseline instead of touching it. --%>
          <%= if @failed_percent > 0 do %>
            <div class="bg-red-500 w-full" style={"height: #{@failed_percent}%"} />
          <% end %>
          <%= if @success_percent > 0 do %>
            <div class="bg-green-500 w-full" style={"height: #{@success_percent}%"} />
          <% end %>
        </button>
      </div>

      <!-- Task Status Grid -->
      <div class="flex-1 border-r border-gray-200 dark:border-gray-800">
        <%= for task_id <- @all_tasks do %>
          <div
            class="dag-cell px-0.5 py-0 h-6 flex items-center justify-center border-b border-gray-200 dark:border-gray-700 last:border-b-0"
            data-task-name={task_id}
            data-run-id={@execution.id}
          >
            <.task_status_square
              task={Map.get(@task_map, task_id)}
              run_id={@execution.id}
              on_click={@on_task_click}
              color_mode={@task_color_mode}
              max_task_duration_ms={@max_task_duration_ms}
            />
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp task_status_square(assigns) do
    task = assigns.task

    {bg_color, extra_class, status_text} =
      case task do
        nil ->
          {"bg-gray-700", "", "Not run"}

        %{status: :success} ->
          {"bg-green-500", "", "Success"}

        %{status: :failed, just_failed: true} ->
          {"bg-red-600", "animate-explosion", "Failed"}

        %{status: :failed} ->
          {"bg-red-600", "", "Failed"}

        %{status: :upstream_failed} ->
          {"bg-red-700", "", "Upstream Failed"}

        %{status: :running} ->
          {"bg-blue-500", "", "Running"}

        %{status: :queued} ->
          {"bg-yellow-400", "", "Queued"}

        %{status: :skipped} ->
          {"bg-amber-500", "", "Skipped"}

        %{status: :waiting} ->
          {"bg-white", "", "Waiting"}

        %{status: :cancelled} ->
          {"bg-slate-600", "", "Cancelled"}

        _ ->
          {"bg-gray-500", "", "Unknown"}
      end

    # In :duration color mode, fade a task square's opacity toward a floor based
    # on how short its own duration is relative to the slowest task shown anywhere
    # in the grid, so slow tasks render vivid and quick ones visibly lighter.
    # In :fixed mode (default) every square stays fully opaque regardless of
    # duration — only its status (color) is informative.
    # Running tasks are ALWAYS fully opaque — the animated stripes need to
    # stay bright and visible to clearly signal "actively executing", not
    # dimmed by a proportional-duration adjustment for a task that hasn't
    # even finished yet (its duration_ms is still nil/partial).
    opacity =
      case {assigns.color_mode, task} do
        {_, %{status: :running}} ->
          1.0

        {:duration, %{duration_ms: duration_ms}} when is_integer(duration_ms) and assigns.max_task_duration_ms > 0 ->
          floor = 0.35
          floor + (1 - floor) * (duration_ms / assigns.max_task_duration_ms)

        _ ->
          1.0
      end

    assigns =
      assigns
      |> assign(:bg_color, bg_color)
      |> assign(:extra_class, extra_class)
      |> assign(:status_text, status_text)
      |> assign(:opacity, opacity)

    ~H"""
    <div class="relative inline-block">
      <!-- Status Square -->
      <button
        class={[
          "w-4 h-4 rounded transition-all hover:shadow-lg hover:scale-125 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500 peer flex items-center justify-center",
          @bg_color,
          @extra_class
        ]}
        style={"opacity: #{@opacity}"}
        phx-click={
          @on_click && @task &&
            JS.push(@on_click, value: %{task_id: @task.id, run_id: @run_id})
        }
        disabled={is_nil(@task)}
      >
        <%= if @task && @task.status == :running do %>
          <span class="hero-arrow-path size-3 text-white animate-spin" />
        <% end %>
      </button>

      <!-- Tooltip appears to the RIGHT of the square so it extends into
           the scrollable grid area, never leftward over the frozen
           column. Theme-aware: light bg in light mode, dark in dark. -->
      <%= if @task do %>
        <div class="absolute left-full top-1/2 -translate-y-1/2 ml-2 hidden peer-hover:block z-50 pointer-events-none opacity-100">
          <div class="bg-white dark:bg-gray-950 text-gray-900 dark:text-white px-3 py-2 rounded-md shadow-lg text-xs whitespace-nowrap border border-gray-200 dark:border-gray-700 opacity-100">
            <p class="font-semibold"><%= @task.name %></p>
            <p class="text-gray-500 dark:text-gray-300 mt-0.5"><%= @status_text %></p>
            <%= if @task.reason do %>
              <p class="text-amber-600 dark:text-amber-400 text-xs mt-0.5">
                Reason: <%= @task.reason %>
              </p>
            <% end %>
            <p class="text-gray-500 dark:text-gray-400 text-xs">
              <%= format_duration(@task.duration_ms) %>
            </p>
            <p class="text-gray-400 dark:text-gray-500 text-xs mt-0.5">
              <%= format_time(@task.start_time) %>
            </p>

            <!-- Tooltip arrow (points left) -->
            <div class="absolute right-full top-1/2 -translate-y-1/2 -mr-0.5 border-4 border-transparent border-r-white dark:border-r-gray-950"></div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Helper functions

  defp format_time(datetime) when is_struct(datetime, DateTime) do
    datetime
    |> DateTime.to_naive()
    |> NaiveDateTime.to_string()
    |> String.slice(0..15)
  end

  # DB notification payloads arrive as JSON, so DateTime fields come back
  # as ISO 8601 strings (e.g. "2026-10-08T07:24:12Z") rather than
  # DateTime structs — display them directly, trimmed to date+time.
  defp format_time(iso_string) when is_binary(iso_string) do
    iso_string
    |> String.replace("T", " ")
    |> String.slice(0..15)
  end

  defp format_time(nil), do: "N/A"


  defp format_duration(ms) when is_integer(ms) and ms >= 0 do
    total_seconds = div(ms, 1000)
    hours = div(total_seconds, 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    seconds = rem(total_seconds, 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m #{seconds}s"
      minutes > 0 -> "#{minutes}m #{seconds}s"
      seconds > 0 -> "#{seconds}s"
      true -> "#{ms}ms"
    end
  end

  defp format_duration(_), do: "N/A"

  # Formats milliseconds as a fixed HH:MM:SS axis tick label, e.g. 15:28:32.
  defp format_axis_duration(ms) when is_integer(ms) and ms >= 0 do
    total_seconds = div(ms, 1000)
    hours = div(total_seconds, 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    seconds = rem(total_seconds, 60)

    :io_lib.format("~2..0B:~2..0B:~2..0B", [hours, minutes, seconds])
    |> IO.iodata_to_binary()
  end

  defp format_axis_duration(_), do: "00:00:00"

  # --- Timeline tick-stripe helpers ---

  # Determines how finely to tick the timeline based on the median gap
  # between consecutive visible runs (sorted chronologically). Returns
  # the "nice" interval in minutes to bucket each run's time into — 60
  # (show just the hour) when runs are sparse, or 30/20/15 when runs
  # are closely spaced within the same hour.
  defp compute_tick_granularity(executions) do
    sorted_starts =
      executions
      |> Enum.map(& &1.start_time)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort(DateTime)

    gaps_minutes =
      sorted_starts
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> abs(DateTime.diff(b, a, :minute)) end)
      |> Enum.reject(&(&1 == 0))

    median_gap = if gaps_minutes == [], do: 999, else: Enum.at(Enum.sort(gaps_minutes), div(length(gaps_minutes), 2))

    cond do
      median_gap <= 20 -> 15
      median_gap <= 35 -> 20
      median_gap <= 50 -> 30
      true -> 60
    end
  end

  # Rounds a DateTime's time component down to the nearest multiple of
  # `granularity_minutes` within its own hour — e.g. with granularity 15,
  # 10:37 → 10:30; with granularity 60, just the hour (10:00). Returns
  # {hour, rounded_minute} as a comparable tuple.
  defp time_bucket(datetime, granularity_minutes) do
    t = DateTime.to_time(datetime)
    rounded = div(t.minute, granularity_minutes) * granularity_minutes
    {t.hour, rounded}
  end

  # Formats a {hour, minute} bucket tuple as "HH:MM".
  defp format_tick_time({hour, minute}) do
    :io_lib.format("~2..0B:~2..0B", [hour, minute])
    |> IO.iodata_to_binary()
  end

  # Formats a DateTime as a compact "Oct 8" / "Sep 30"-style label for
  # Formats a DateTime as "YYYY-MM-DD" for the timeline tick stripe.
  defp format_short_date(datetime) when is_struct(datetime, DateTime) do
    pad = fn n -> String.pad_leading(Integer.to_string(n), 2, "0") end
    "#{datetime.year}-#{pad.(datetime.month)}-#{pad.(datetime.day)}"
  end

  defp format_short_date(nil), do: ""
end

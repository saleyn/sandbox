defmodule AirWeb.Pages.DagExecutionHistoryDemo do
  @moduledoc """
  Demo page showing the DAG Execution History component in action.

  This page fetches real data from the database using the DagExecutionQuery module.
  Make sure to run `mix run priv/repo/seeds.exs` to populate the database first.
  """
  use AirWeb, :live_view

  alias AirWeb.Components.DagExecutionHistory
  alias Air.DagExecutionQuery

  @def_dag_id "example_data_pipeline"
  @show_max_runs 10

  @impl true
  def mount(params, _session, socket) do
    dag_id = params["dag_id"] || @def_dag_id
    tasks = DagExecutionQuery.get_tasks_for_dag(dag_id)
    stats = DagExecutionQuery.get_dag_stats(dag_id)
    executions = DagExecutionQuery.get_recent_dag_executions(dag_id, @show_max_runs) || []

    socket =
      socket
      |> assign(dag_id: dag_id)
      |> assign(tasks: tasks)
      |> assign(stats: stats)
      |> assign(dag_id: dag_id)
      |> assign(selected_task: nil)
      |> assign(task_color_mode: :duration)
      |> assign(in_flight_run_id: nil)
      |> assign(date_from: "")
      |> assign(date_to: "")
      |> assign(date_label: nil)
      |> assign(tasks: tasks)
      |> assign(executions: executions)

    # Note: Phoenix.PubSub doesn't support wildcard subscriptions.
    # We subscribe to specific run topics inside handle_event("trigger_execution").
    {:ok, socket}
  end

  @impl true
  def handle_event("task_clicked", %{"task_id" => task_id, "run_id" => run_id}, socket) do
    # Fetch task instance details
    task = DagExecutionQuery.get_task_instance(run_id, task_id)

    message =
      "Clicked: #{task_id} | Status: #{task.status} | Duration: #{format_duration(task.duration_ms)}"

    {:noreply,
     socket
     |> put_flash(:info, message)
     |> assign(selected_task: task)}
  end

  def handle_event("run_clicked", %{"run_id" => run_id}, socket) do
    run = Air.Repo.get!(Air.DagRun, run_id)

    message =
      "Run #{run_id} | Status: #{run.status} | Total execution time: #{format_duration(run.duration_ms)}"

    {:noreply, put_flash(socket, :info, message)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, selected_task: nil)}
  end

  def handle_event("set_task_color_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, task_color_mode: String.to_existing_atom(mode))}
  end

  def handle_event("filter_by_date", %{"date_from" => date_from, "date_to" => date_to} = params, socket) do
    # The JS date picker sends the symbolic label (e.g. "Last 1 hour")
    # that produced this from/to pair, if the user picked one from the
    # quick list rather than typing/applying a custom range. We store it
    # alongside date_from/date_to and echo it back via data-label on the
    # next render, so the picker can keep showing the symbolic choice
    # instead of resolving "Last 1 hour" into a concrete timestamp that then
    # looks like a *different* value was chosen once Elixir's response
    # round-trips back into the component.
    label = Map.get(params, "label", "")
    date_label = if label == "", do: nil, else: label

    case parse_date_range(date_from, date_to) do
      {:ok, from_dt, to_dt} ->
        executions = DagExecutionQuery.get_dag_executions_in_range(socket.assigns.dag_id, from_dt, to_dt)

        {:noreply,
         socket
         # A prior failed attempt may have left an :error flash behind;
         # clear it on success so the banner doesn't linger after the
         # user picks a valid range.
         |> clear_flash(:error)
         |> assign(
           executions: executions,
           date_from: date_from,
           date_to: date_to,
           date_label: date_label
         )}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, "Invalid date range: #{msg}")}
    end
  end

  def handle_event("trigger_execution", _params, socket) do
    import Ecto.Query
    dag_id = socket.assigns.dag_id

    # Don't allow multiple simultaneous triggers
    if socket.assigns.in_flight_run_id do
      {:noreply, put_flash(socket, :warning, "A run is already in progress. Please wait for it to complete.")}
    else
      run_start = DateTime.utc_now()
      run_id = "dag_run_#{System.os_time(:millisecond)}"

      # Fetch tasks ordered by task_id to ensure consistent DAG sequence order
      dag_tasks = Air.Repo.all(from dt in Air.DagTask, where: dt.dag_id == ^dag_id, order_by: dt.id)

      # Create the run record with :running status
      {:ok, _run} =
        Air.Repo.insert(
          Air.DagRun.changeset(%Air.DagRun{}, %{
            run_id: run_id,
            dag_id: dag_id,
            status: :running,
            start_time: run_start,
            run_type: "manual"
          })
        )

      # Create all task instances with :waiting status (not yet started)
      Enum.each(dag_tasks, fn task ->
        Air.Repo.insert(
          Air.TaskInstance.changeset(%Air.TaskInstance{}, %{
            task_id: task.task_id,
            run_id: run_id,
            dag_id: dag_id,
            status: :waiting,
            hostname: "worker-#{Enum.random(1..3)}"
          })
        )
      end)

      # Fetch the full run with preloaded task instances (ordered by id) for immediate display
      task_instances_query = from(ti in Air.TaskInstance, order_by: ti.id)
      full_run = Air.Repo.get!(Air.DagRun, run_id) |> Air.Repo.preload(task_instances: task_instances_query)
      new_execution = DagExecutionQuery.format_execution(full_run)

      # Append the new run to the end of the executions list so it appears
      # as the rightmost (most recent) column — the list is chronological
      # (oldest first, newest last), matching the query's own ordering.
      updated_executions = [new_execution | (Enum.reverse(socket.assigns.executions) |> Enum.take(@show_max_runs-1))]
                        |> Enum.reverse()

      # Subscribe to database notifications for this run
      Phoenix.PubSub.subscribe(Air.PubSub, "dag_run:#{run_id}")

      # Kick off the background step-by-step simulator with ordered task instances
      Air.DagRunSimulator.start(run_id, full_run.task_instances)

      {:noreply,
       socket
       |> put_flash(:info, "🚀 New execution triggered: #{run_id} (simulating...)")
       |> assign(in_flight_run_id: run_id, executions: updated_executions)}
    end
  end

  @impl true
  def handle_info({:tasks_updated, tasks_map}, socket) when is_map(tasks_map) do
    # Extract the run_id from the first task in the batch — all tasks in
    # a single notification batch belong to the same run (DbListener
    # accumulates per run_id). Only update the execution whose id matches
    # this run, not every execution in the list — task_id names (e.g.
    # "start_data_pipeline") are shared across ALL runs of the same DAG,
    # so without scoping by run_id every historical run's identically-
    # named task would get overwritten with the current run's state.
    target_run_id =
      tasks_map
      |> Map.values()
      |> List.first()
      |> case do
        nil -> nil
        task_data -> task_data["run_id"]
      end

    updated_executions =
      socket.assigns.executions
      |> Enum.map(fn exec ->
        if exec.id == target_run_id do
          updated_tasks =
            exec.tasks
            |> Enum.map(fn t ->
              case Map.get(tasks_map, t.id) do
                nil ->
                  t
                task_data ->
                  new_status = String.to_atom(task_data["status"])

                  %{
                    t
                    | status: new_status,
                      reason: task_data["reason"],
                      start_time: task_data["start_time"],
                      end_time: task_data["end_time"],
                      duration_ms: task_data["duration_ms"],
                      just_failed: new_status == :failed and t.status != :failed
                  }
              end
            end)

          # Recompute the execution's own duration_ms from the sum of
          # its tasks' individual durations so far — the run-level
          # duration_ms only gets set by the server once the whole run
          # completes (via :dag_run_updated), but the bar chart needs a
          # meaningful value while the run is still in progress,
          # otherwise the bar stays flat/empty until completion.
          total_duration =
            updated_tasks
            |> Enum.map(fn t ->
              case t.duration_ms do
                ms when is_integer(ms) -> ms
                _ -> 0
              end
            end)
            |> Enum.sum()

          %{exec | tasks: updated_tasks, duration_ms: max(exec.duration_ms, total_duration)}
        else
          exec
        end
      end)

    {:noreply, assign(socket, executions: updated_executions)}
  end

  def handle_info({:dag_run_updated, run_data}, socket) do
    # The run is complete. Find and update it in the executions list.
    run_id = run_data["run_id"]

    updated_executions =
      socket.assigns.executions
      |> Enum.map(fn exec ->
        if exec.id == run_id do
          # Preserve the tasks list (already updated by task_updated messages)
          # but update the run's top-level fields
          %{
            exec
            | status: String.to_atom(run_data["status"]),
              end_time: run_data["end_time"],
              duration_ms: run_data["duration_ms"]
          }
        else
          exec
        end
      end)

    # Refresh stats and clear the in-flight flag
    stats = DagExecutionQuery.get_dag_stats(socket.assigns.dag_id)
    status_text = run_data["status"]

    {:noreply,
     socket
     |> assign(executions: updated_executions, stats: stats, in_flight_run_id: nil)
     |> put_flash(:success, "✅ Execution completed: #{run_id} (status: #{status_text})")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-gray-50 dark:bg-gray-900 min-h-screen p-8">
      <div class="max-w-full mx-auto">
        <!-- Header. flex-col below md so the title stacks above the
             controls on narrow screens instead of being squeezed beside
             a fixed-width date picker + button that can't shrink or
             wrap — items-start/justify-between only arrange things
             left-to-right in a row, they don't make a row responsive by
             themselves. -->
        <div class="mb-8 flex flex-col md:flex-row md:items-start md:justify-between gap-4">
          <div>
            <h1 class="text-4xl font-bold text-gray-900 dark:text-white mb-2">DAG Execution History</h1>
            <p class="text-lg text-gray-600 dark:text-gray-400">
              Task execution status visualization for <span class="font-mono text-blue-600 dark:text-blue-400"><%= @dag_id %></span>
            </p>
          </div>
          <!-- flex-wrap + w-full below md: the date picker and button
               drop to their own line(s) and can wrap instead of forcing
               horizontal overflow once the viewport is too narrow for
               both at full width side by side. md:flex-shrink-0 keeps
               this group from being compressed by the title at desktop
               widths, where there's room for both. -->
          <div class="flex flex-wrap items-center gap-3 w-full md:w-auto md:flex-shrink-0">
            <!-- Color theme toggle (light/dark/system), same component
                 used in the default Phoenix app layout — this page
                 doesn't wrap itself in <Layouts.app>, so it needs its
                 own copy here to have a toggle at all. -->
            <Layouts.theme_toggle />
            <!-- Time Range Filter (Grafana-style date picker), next to the
                 trigger button rather than its own section below the
                 header. w-full on narrow screens so it uses the full
                 available width rather than a fixed desktop size that
                 would either overflow or look cramped; sm:w-80 caps it
                 back down once there's enough room for it to sit next to
                 the button instead of alone on its own line. -->
            <div
              id="date-picker-container"
              phx-hook="DatePickerHook"
              phx-update="ignore"
              data-from={@date_from}
              data-to={@date_to}
              data-label={@date_label}
              class="w-full sm:w-80"
            ></div>
            <button
              phx-click="trigger_execution"
              disabled={!!@in_flight_run_id}
              class={[
                "px-4 py-2 font-semibold rounded-lg transition-colors whitespace-nowrap",
                @in_flight_run_id
                && "bg-gray-300 text-gray-500 dark:bg-gray-600 dark:text-gray-400 cursor-not-allowed",
                !@in_flight_run_id
                && "bg-blue-600 hover:bg-blue-700 text-white"
              ]}
            >
              <%= if @in_flight_run_id, do: "⏳ Running...", else: "🚀 Trigger Execution" %>
            </button>
          </div>
        </div>

        <!-- Stats Cards -->
        <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-8">
          <div class="bg-white dark:bg-gray-800 p-4 rounded-lg border border-gray-200 dark:border-gray-700">
            <p class="text-gray-500 dark:text-gray-400 text-sm uppercase">Total Runs</p>
            <p class="text-3xl font-bold text-gray-900 dark:text-white mt-2"><%= @stats.total_runs %></p>
          </div>
          <div class="bg-white dark:bg-gray-800 p-4 rounded-lg border border-gray-200 dark:border-gray-700">
            <p class="text-gray-500 dark:text-gray-400 text-sm uppercase">Successful</p>
            <p class="text-3xl font-bold text-green-600 dark:text-green-500 mt-2"><%= @stats.successful_runs %></p>
          </div>
          <div class="bg-white dark:bg-gray-800 p-4 rounded-lg border border-gray-200 dark:border-gray-700">
            <p class="text-gray-500 dark:text-gray-400 text-sm uppercase">Failed</p>
            <p class="text-3xl font-bold text-red-600 dark:text-red-500 mt-2"><%= @stats.failed_runs %></p>
          </div>
          <div class="bg-white dark:bg-gray-800 p-4 rounded-lg border border-gray-200 dark:border-gray-700">
            <p class="text-gray-500 dark:text-gray-400 text-sm uppercase">Success Rate</p>
            <p class="text-3xl font-bold text-blue-600 dark:text-blue-500 mt-2"><%= @stats.success_rate %>%</p>
          </div>
        </div>

        <!-- Flash Messages -->
        <div :if={@flash["info"]} class="mb-4 p-4 bg-blue-50 dark:bg-blue-900 border border-blue-300 dark:border-blue-600 text-blue-800 dark:text-blue-100 rounded-lg">
          <%= @flash["info"] %>
        </div>
        <div :if={@flash["success"]} class="mb-4 p-4 bg-green-50 dark:bg-green-900 border border-green-300 dark:border-green-600 text-green-800 dark:text-green-100 rounded-lg">
          <%= @flash["success"] %>
        </div>
        <div :if={@flash["warning"]} class="mb-4 p-4 bg-amber-50 dark:bg-amber-900 border border-amber-300 dark:border-amber-600 text-amber-800 dark:text-amber-100 rounded-lg">
          <%= @flash["warning"] %>
        </div>
        <div :if={@flash["error"]} class="mb-4 p-4 bg-red-50 dark:bg-red-900 border border-red-300 dark:border-red-600 text-red-800 dark:text-red-100 rounded-lg">
          <%= @flash["error"] %>
        </div>

        <!-- Task Color Intensity Mode -->
        <div class="mb-4 flex items-center gap-3">
          <span class="text-gray-600 dark:text-gray-400 text-sm uppercase">Task color intensity</span>
          <div class="inline-flex rounded-lg border border-gray-300 dark:border-gray-700 overflow-hidden">
            <button
              phx-click="set_task_color_mode"
              phx-value-mode="fixed"
              class={[
                "px-3 py-1.5 text-sm font-medium transition-colors",
                @task_color_mode == :fixed && "bg-blue-600 text-white",
                @task_color_mode != :fixed && "bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-400 dark:hover:bg-gray-700"
              ]}
            >
              Fixed
            </button>
            <button
              phx-click="set_task_color_mode"
              phx-value-mode="duration"
              class={[
                "px-3 py-1.5 text-sm font-medium transition-colors",
                @task_color_mode == :duration && "bg-blue-600 text-white",
                @task_color_mode != :duration && "bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-400 dark:hover:bg-gray-700"
              ]}
            >
              Proportional
            </button>
          </div>
        </div>

        <!-- DAG Execution History Component -->
        <div class="mb-8">
          <DagExecutionHistory.dag_execution_history
            dag_id={@dag_id}
            tasks={@tasks}
            executions={@executions}
            on_task_click="task_clicked"
            on_run_click="run_clicked"
            task_color_mode={@task_color_mode}
          />
        </div>

        <!-- Selected Task Details -->
        <%= if @selected_task do %>
          <div class="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg p-6 mb-8">
            <div class="flex justify-between items-start mb-4">
              <div>
                <h3 class="text-xl font-bold text-gray-900 dark:text-white"><%= @selected_task.task_id %></h3>
                <p class="text-gray-600 dark:text-gray-400 text-sm">Run: <span class="font-mono"><%= @selected_task.run_id %></span></p>
              </div>
              <button
                phx-click={JS.push("clear_selection")}
                class="text-gray-500 hover:text-gray-900 dark:text-gray-400 dark:hover:text-white transition"
              >
                ✕
              </button>
            </div>

            <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
              <div>
                <p class="text-gray-500 dark:text-gray-500 text-xs uppercase">Status</p>
                <p class="text-gray-900 dark:text-white font-semibold mt-1 capitalize">
                  <span class={status_badge_class(@selected_task.status)}>
                    <%= @selected_task.status %>
                  </span>
                </p>
              </div>
              <div>
                <p class="text-gray-500 dark:text-gray-500 text-xs uppercase">Duration</p>
                <p class="text-gray-900 dark:text-white font-semibold mt-1">
                  <%= format_duration(@selected_task.duration_ms) %>
                </p>
              </div>
              <div>
                <p class="text-gray-500 dark:text-gray-500 text-xs uppercase">Try Number</p>
                <p class="text-gray-900 dark:text-white font-semibold mt-1"><%= @selected_task.try_number %></p>
              </div>
              <div>
                <p class="text-gray-500 dark:text-gray-500 text-xs uppercase">Started</p>
                <p class="text-gray-900 dark:text-white font-semibold mt-1 text-sm">
                  <%= format_datetime(@selected_task.start_time) %>
                </p>
              </div>
            </div>
          </div>
        <% end %>

        <!-- Legend -->
        <div class="bg-white dark:bg-gray-800 p-6 rounded-lg border border-gray-200 dark:border-gray-700">
          <h2 class="text-xl font-bold text-gray-900 dark:text-white mb-4">Status Legend</h2>
          <div class="grid grid-cols-2 md:grid-cols-6 gap-4">
            <div class="flex items-center gap-2">
              <div class="w-4 h-4 bg-green-500 rounded"></div>
              <span class="text-gray-700 dark:text-gray-300">Success</span>
            </div>
            <div class="flex items-center gap-2">
              <div class="w-4 h-4 bg-red-600 rounded"></div>
              <span class="text-gray-700 dark:text-gray-300">Failed</span>
            </div>
            <div class="flex items-center gap-2">
              <div class="w-4 h-4 bg-blue-500 rounded"></div>
              <span class="text-gray-700 dark:text-gray-300">Running</span>
            </div>
            <div class="flex items-center gap-2">
              <div class="w-4 h-4 bg-amber-500 rounded"></div>
              <span class="text-gray-700 dark:text-gray-300">Skipped</span>
            </div>
            <div class="flex items-center gap-2">
              <div class="w-4 h-4 bg-yellow-400 rounded"></div>
              <span class="text-gray-700 dark:text-gray-300">Queued</span>
            </div>
            <div class="flex items-center gap-2">
              <div class="w-4 h-4 bg-white border border-gray-300 dark:border-gray-600 rounded"></div>
              <span class="text-gray-700 dark:text-gray-300">Waiting</span>
            </div>
            <div class="flex items-center gap-2">
              <div class="w-4 h-4 bg-slate-600 rounded"></div>
              <span class="text-gray-700 dark:text-gray-300">Cancelled</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions

  defp parse_date_range(date_from, date_to) do
    with {:ok, from_dt} <- parse_date_expr(date_from),
         {:ok, to_dt} <- parse_date_expr(date_to) do
      {:ok, from_dt, to_dt}
    else
      {:error, msg} -> {:error, msg}
    end
  end

  defp parse_date_expr("now"), do: {:ok, DateTime.utc_now()}

  # "Sunday" / "Last Sunday" — most recent Sunday at midnight, or the
  # Sunday one week before that. Mirrors resolveDateExpr's own two
  # clauses in grafana-date-picker.js; this app's week-start convention
  # elsewhere stays Monday (ISO), these two phrases exist purely as the
  # vocabulary "This week"/"Last week" are built from.
  defp parse_date_expr("Sunday"), do: {:ok, most_recent_sunday(DateTime.utc_now())}
  defp parse_date_expr("Last Sunday"), do: {:ok, DateTime.add(most_recent_sunday(DateTime.utc_now()), -7, :day)}

  # "Last Sunday - 7 days" — anchors to the Sunday-before-last, then
  # applies a plain day offset on top. The " - N days" suffix is
  # intentionally only supported after "Last Sunday" (what "Last
  # week"'s own From needs), not as a fully general suffix grammar.
  defp parse_date_expr("Last Sunday - " <> rest) do
    case Regex.run(~r/^(\d+)\s*days?$/, String.trim(rest)) do
      [_full, num_str] ->
        with {num, _} <- Integer.parse(num_str) do
          last_sunday = DateTime.add(most_recent_sunday(DateTime.utc_now()), -7, :day)
          {:ok, DateTime.add(last_sunday, -num, :day)}
        else
          :error -> {:error, "Invalid number in date expression"}
        end

      nil ->
        {:error, "Invalid format. Use 'Last Sunday - N days'"}
    end
  end

  # "1st day of this month" / "1st day of last month"
  defp parse_date_expr("1st day of this month") do
    now = DateTime.utc_now()
    {:ok, DateTime.new!(%{DateTime.to_date(now) | day: 1}, ~T[00:00:00], "UTC")}
  end

  defp parse_date_expr("1st day of last month") do
    now = DateTime.utc_now()
    last_month = Date.shift(DateTime.to_date(now), month: -1)
    {:ok, DateTime.new!(%{last_month | day: 1}, ~T[00:00:00], "UTC")}
  end

  # "End of last month" — 23:59:59 on the last calendar day of last
  # month, i.e. one second before this month's own 1st-day boundary.
  defp parse_date_expr("End of last month") do
    now = DateTime.utc_now()
    start_of_this_month = %{DateTime.to_date(now) | day: 1}
    end_of_last_month = Date.add(start_of_this_month, -1)
    {:ok, DateTime.new!(end_of_last_month, ~T[23:59:59], "UTC")}
  end

  defp parse_date_expr("Last " <> rest), do: parse_relative_date("now", String.trim(rest))
  defp parse_date_expr("now - " <> rest), do: parse_relative_date("now", String.trim(rest))
  defp parse_date_expr(""), do: {:ok, DateTime.utc_now() |> DateTime.add(-30, :day)}

  # Matches both "YYYY-MM-DD HH:MM:SS" (what the JS date picker's calendar
  # popup writes, space-separated) and the ISO-standard "YYYY-MM-DDTHH:MM:SS".
  # Date.from_iso8601/1 alone only accepts a bare date — anything with a
  # time component appended falls through to the plain-date clause below
  # and previously hit :invalid_format there.
  defp parse_date_expr(<<date_part::binary-size(10), sep, time_part::binary>>)
       when sep in [?\s, ?T] do
    with {:ok, date} <- Date.from_iso8601(date_part),
         {:ok, time} <- Time.from_iso8601(pad_time(time_part)) do
      {:ok, DateTime.new!(date, time, "UTC")}
    else
      _ -> {:error, "Invalid date format. Use YYYY-MM-DD, YYYY-MM-DD HH:MM:SS, 'now', or 'Last Xd'"}
    end
  end

  defp parse_date_expr(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> {:ok, DateTime.new!(date, ~T[00:00:00], "UTC")}
      {:error, _} -> {:error, "Invalid date format. Use YYYY-MM-DD, YYYY-MM-DD HH:MM:SS, 'now', 'Last', or 'Last Xd'"}
    end
  end

  # Midnight on the most recent Sunday on/before `datetime` (inclusive —
  # if `datetime`'s date is itself a Sunday, returns that same day at
  # midnight).
  defp most_recent_sunday(datetime) do
    date = DateTime.to_date(datetime)
    # Date.day_of_week/2 with :sunday epoch: Sunday=1..Saturday=7
    days_since_sunday = Date.day_of_week(date, :sunday) - 1
    sunday_date = Date.add(date, -days_since_sunday)
    DateTime.new!(sunday_date, ~T[00:00:00], "UTC")
  end

  # Time.from_iso8601/1 requires seconds — pad "HH:MM" (e.g. from an
  # <input type="time"> without seconds touched) up to "HH:MM:00".
  defp pad_time(time_str) do
    case String.split(time_str, ":") do
      [_h, _m] -> time_str <> ":00"
      _ -> time_str
    end
  end

  defp parse_relative_date("now", expr) do
    # Remove leading/trailing whitespace and handle formats like "-5m", "- 5m", " -5m"
    expr = String.trim(expr)

    # Remove leading minus/dash and whitespace
    expr = if String.starts_with?(expr, "-"), do: String.slice(expr, 1..-1//-1), else: expr
    expr = String.trim(expr)

    # "3 months" / "6 months" — a space-separated whole-word unit (not
    # glued like "3d"), and the one unit that needs calendar-aware month
    # arithmetic rather than a fixed-length DateTime.add offset, so it's
    # matched and handled before the glued single-letter-unit regex below.
    case Regex.run(~r/^(\d+)\s+months?$/, expr) do
      [_full, num_str] ->
        with {num, _} <- Integer.parse(num_str) do
          now = DateTime.utc_now()
          shifted_date = Date.shift(DateTime.to_date(now), month: -num)
          {:ok, DateTime.new!(shifted_date, DateTime.to_time(now), "UTC")}
        else
          :error -> {:error, "Invalid number in date expression"}
        end

      nil ->
        parse_relative_date_full_word_unit(expr)
    end
  rescue
    _ -> {:error, "Invalid number in date expression"}
  end

  # "1 day" / "15 minutes" / "3 hours" / "2 weeks" — full-word units,
  # space-separated from the number, as opposed to "15m"/"7d" glued.
  # Mirrors resolveDateExpr's own fullWordMatch branch in
  # grafana-date-picker.js.
  defp parse_relative_date_full_word_unit(expr) do
    case Regex.run(~r/^(\d+)\s+(minutes?|hours?|days?|weeks?)$/, expr) do
      [_full, num_str, unit] ->
        with {num, _} <- Integer.parse(num_str) do
          cond do
            String.starts_with?(unit, "minute") -> {:ok, DateTime.utc_now() |> DateTime.add(-num, :minute)}
            String.starts_with?(unit, "hour") -> {:ok, DateTime.utc_now() |> DateTime.add(-num, :hour)}
            String.starts_with?(unit, "day") -> {:ok, DateTime.utc_now() |> DateTime.add(-num, :day)}
            String.starts_with?(unit, "week") -> {:ok, DateTime.utc_now() |> DateTime.add(-num * 7, :day)}
          end
        else
          :error -> {:error, "Invalid number in date expression"}
        end

      nil ->
        parse_relative_date_glued_unit(expr)
    end
  end

  defp parse_relative_date_glued_unit(expr) do
    # Use regex to extract number and unit
    case Regex.run(~r/^(\d+)([a-z]+)$/, expr) do
      [_full, num_str, unit] ->
        with {num, _} <- Integer.parse(num_str) do
          case unit do
            "d" -> {:ok, DateTime.utc_now() |> DateTime.add(-num, :day)}
            "h" -> {:ok, DateTime.utc_now() |> DateTime.add(-num, :hour)}
            "m" -> {:ok, DateTime.utc_now() |> DateTime.add(-num, :minute)}
            "w" -> {:ok, DateTime.utc_now() |> DateTime.add(-num * 7, :day)}
            _ -> {:error, "Invalid time unit. Use 'd', 'h', 'm', 'w', or 'months'"}
          end
        else
          :error -> {:error, "Invalid number in date expression"}
        end

      _ ->
        {:error,
         "Invalid relative date format. Use 'Last Xd' (days), 'Last Xh' (hours), 'Last Xm' (minutes), 'Last Xw' (weeks), or 'Last X months'"}
    end
  end

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

  defp format_datetime(datetime) when is_struct(datetime, DateTime) do
    datetime
    |> DateTime.to_naive()
    |> NaiveDateTime.to_string()
    |> String.slice(0..18)
  end

  defp format_datetime(nil), do: "N/A"

  defp status_badge_class(status) do
    case status do
      :success -> "px-2 py-1 bg-green-900 text-green-200 rounded text-xs"
      :failed -> "px-2 py-1 bg-red-900 text-red-200 rounded text-xs"
      :running -> "px-2 py-1 bg-blue-900 text-blue-200 rounded text-xs"
      :skipped -> "px-2 py-1 bg-amber-900 text-amber-200 rounded text-xs"
      :queued -> "px-2 py-1 bg-yellow-900 text-yellow-200 rounded text-xs"
      _ -> "px-2 py-1 bg-gray-700 text-gray-200 rounded text-xs"
    end
  end
end

defmodule AirWeb.Pages.DagEditor do
  @moduledoc """
  Visual DAG editor page using a custom DOM-based editor (DagEditorHook).

  Allows creating/editing DAGs by adding task nodes (rectangles),
  condition nodes (diamonds), connecting them (1-to-N with data_size
  metadata), editing task properties via a modal, and persisting
  everything to the database on explicit Save.
  """
  use AirWeb, :live_view

  require Logger

  alias Air.{AppSettingsQuery, DAG, DagEditorQuery}

  @impl true
  def mount(params, _session, socket) do
    dag_id = params["dag_id"]

    {dag, tasks, is_new} =
      if dag_id do
        case DagEditorQuery.get_dag_with_tasks(dag_id) do
          {:ok, %{dag: dag, tasks: tasks}} ->
            {dag, tasks, false}

          {:error, :not_found} ->
            # DAG doesn't exist yet — create it
            {:ok, dag} = DagEditorQuery.create_dag(dag_id)
            {dag, [], true}
        end
      else
        # No dag_id in URL — create a temporary new DAG
        temp_id = "dag_#{System.os_time(:millisecond)}"
        {:ok, dag} = DagEditorQuery.create_dag(temp_id)
        {dag, [], true}
      end

    # Serialize tasks for the JS hook
    graph_data = %{
      tasks: Enum.map(tasks, &format_task_for_js/1),
      layout: dag.layout || %{}
    }

    socket =
      socket
      |> assign(dag: dag)
      |> assign(dag_id: dag.dag_id)
      |> assign(graph_data: Jason.encode!(graph_data))
      |> assign(settings_data: Jason.encode!(AppSettingsQuery.as_editor_defaults()))
      |> assign(is_new: is_new)
      |> assign(selected_task: nil)
      |> assign(show_modal: false)
      |> assign(show_properties_drawer: false)
      |> assign_properties_form(DAG.changeset(dag, %{}))

    {:ok, socket}
  end

  @impl true
  def handle_event("open_properties_drawer", _params, socket) do
    {:noreply,
     socket
     |> assign(show_properties_drawer: true)
     |> assign(execution_stats: DagEditorQuery.get_execution_stats(socket.assigns.dag_id))
     |> assign_properties_form(DAG.changeset(socket.assigns.dag, %{}))}
  end

  def handle_event("close_properties_drawer", _params, socket) do
    {:noreply, assign(socket, show_properties_drawer: false)}
  end

  def handle_event("validate_properties", %{"dag" => params}, socket) do
    changeset =
      socket.assigns.dag
      |> DAG.changeset(normalize_properties_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign_properties_form(socket, changeset)}
  end

  def handle_event("save_properties", %{"dag" => params}, socket) do
    case DagEditorQuery.update_properties(socket.assigns.dag, normalize_properties_params(params)) do
      {:ok, dag} ->
        {:noreply,
         socket
         |> assign(dag: dag)
         |> assign(show_properties_drawer: false)
         |> assign_properties_form(DAG.changeset(dag, %{}))}

      {:error, changeset} ->
        {:noreply, assign_properties_form(socket, changeset)}
    end
  end

  def handle_event("update_settings", %{"name" => name, "value" => value}, socket) do
    # Persists as the new app-wide default for the NEXT editor session to
    # start from — not retroactive for any other tab/session already open,
    # same as toolbar changes already only affect the current session live.
    case AppSettingsQuery.update(%{name => value}) do
      {:ok, _settings} ->
        :ok

      {:error, changeset} ->
        Logger.warning("DagEditor update_settings: rejected #{name}=#{inspect(value)} — #{inspect(changeset.errors)}")
    end

    {:noreply, socket}
  end

  def handle_event("open_task_modal", params, socket) do
    {:noreply,
     socket
     |> assign(selected_task: params)
     |> assign(show_modal: true)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(selected_task: nil)
     |> assign(show_modal: false)}
  end

  def handle_event("save_task_modal", params, socket) do
    original_task_id = params["original_task_id"]

    properties = %{
      task_id: params["task_id"],
      task_type: params["task_type"] || "task",
      source_code: params["source_code"] || "",
      source_language: params["source_language"] || "python",
      pool: params["pool"] || "default_pool",
      pool_slots: parse_int(params["pool_slots"], 1),
      priority_weight: parse_int(params["priority_weight"], 1),
      queue: params["queue"] || "default",
      max_tries: parse_int(params["max_tries"], 0),
      retries: parse_int(params["retries"], 0)
    }

    {:noreply,
     socket
     |> push_event("task-updated", %{original_task_id: original_task_id, properties: properties})
     |> assign(show_modal: false, selected_task: nil)}
  end

  def handle_event("save_graph", %{"tasks" => tasks, "layout" => layout}, socket) do
    case DagEditorQuery.save_graph(socket.assigns.dag_id, tasks, layout) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "✅ DAG saved successfully")
         |> assign(is_new: false)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save DAG: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.sidebar_shell flash={@flash} current_path="/dag/editor">
    <div class="h-full flex flex-col">
      <!-- Title bar — kept OUTSIDE #dag-editor-root's phx-update="ignore"
           subtree (same reasoning as the drawers below): LiveView needs to
           patch @dag.title here whenever it's edited in the Properties
           drawer, which it can never do inside an ignored subtree. Also
           carries the toolbar buttons (Edit/Save/History/theme) — merged
           in from what used to be a second, separate bar inside
           #dag-editor-root (redundant row of chrome). Since these buttons
           are now outside #dag-editor-root, DagEditorHook's
           [data-graph-action] click handler listens on `document` rather
           than the hook's own element, so Save etc. still reach it. -->
      <div class="flex items-center gap-4 px-4 py-2 bg-base-100 border-b border-base-300 flex-shrink-0">
        <h1 class="text-xl font-bold text-base-content flex-shrink-0">DAG Editor</h1>
        <span class="text-lg text-base-content/70 truncate"><%= @dag.title %></span>

        <div class="flex items-center gap-3 ml-auto">
          <button
            type="button"
            id="dag-editor-undo-btn"
            data-graph-action="undo"
            aria-label="Undo (Ctrl+Z)"
            disabled
            class={["p-1.5 text-base-content/50 hover:text-base-content rounded hover:bg-base-200 disabled:opacity-30 disabled:pointer-events-none transition-colors" | tooltip_class(:bottom)]}
          >
            <.icon name="hero-arrow-uturn-left" class="size-4" />
          </button>
          <button
            type="button"
            id="dag-editor-redo-btn"
            data-graph-action="redo"
            aria-label="Redo (Ctrl+Shift+Z)"
            disabled
            class={["p-1.5 text-base-content/50 hover:text-base-content rounded hover:bg-base-200 disabled:opacity-30 disabled:pointer-events-none transition-colors" | tooltip_class(:bottom)]}
          >
            <.icon name="hero-arrow-uturn-right" class="size-4" />
          </button>

          <button
            type="button"
            phx-click="open_properties_drawer"
            class="flex items-center gap-1.5 px-3 py-1.5 bg-base-200 hover:bg-base-300 text-base-content text-sm rounded transition-colors"
          >
            <.icon name="hero-pencil-square" class="size-4 text-base-content/50" /> Edit
          </button>

          <button
            data-graph-action="save"
            class="flex items-center gap-1.5 px-4 py-1.5 bg-primary hover:bg-primary/90 text-primary-content text-sm font-semibold rounded transition-colors"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Save
          </button>

          <a
            href={~p"/demo/dag-execution-history"}
            class="px-3 py-1.5 bg-base-200 hover:bg-base-300 text-base-content text-sm rounded transition-colors"
          >
            ← History
          </a>

          <Layouts.theme_toggle />
        </div>
      </div>

      <!-- The hook element wraps the canvas so that data-graph-action
           button clicks (now in the title bar above) still bubble up to
           the hook's delegated click listener via DOM bubbling, which
           doesn't require the button to be a descendant of this specific
           div — only that the listener is attached to an ancestor shared
           by both, which document-level attachment on mount guarantees.
           phx-update="ignore" prevents LiveView from patching the canvas
           (which DagEditor owns entirely). -->
      <div
        id="dag-editor-root"
        phx-hook="DagEditorHook"
        phx-update="ignore"
        data-graph={@graph_data}
        data-settings={@settings_data}
        class="bg-window flex-1 min-h-0 flex flex-col"
      >
        <!-- Flash Messages (rendered outside phx-update="ignore" would
             be ideal, but since the whole hook div is ignore, we handle
             flashes via the server-rendered modal below instead) -->

        <!-- Graph canvas — flex-1 fills remaining viewport height. DagEditor
             builds its own DOM tree inside #dag-canvas-wrapper. -->
        <div class="flex-1 relative" id="dag-canvas-wrapper"></div>
      </div>
    </div>

    <!-- Task Properties Drawer — OUTSIDE the phx-update="ignore" hook
         div so LiveView can freely show/hide it on server-driven
         assign changes (@show_modal). If it were inside the ignored
         subtree, LiveView would never re-render it after initial mount.
         Slides in from the right rather than a centered modal, wide
         enough to comfortably show 80 columns of monospace source code
         (80ch + the code editor's line-number gutter and padding) on
         desktop; on narrow/mobile viewports it widens to the full window
         instead of being squeezed into a half-visible sliver. -->
    <%= if @show_modal && @selected_task do %>
      <div class="fixed inset-0 z-50">
        <!-- Backdrop: fades in on mount (same transition family as the
             drawer's slide, just opacity instead of translate). Closing
             only toggles classes client-side (data-closing + the opacity/
             translate classes below) — TaskModalTabsHook listens for the
             drawer's own transitionend and pushes close_modal to the
             server itself once the slide has actually finished, since
             Phoenix.LiveView.JS command chains all fire on the same tick
             (there's no built-in "run this op only after that transition
             completes" chaining), so a plain JS.push chained after
             JS.hide would otherwise remove the assign (and this whole
             block) before the animation had any chance to play. -->
        <div
          id="task-modal-backdrop"
          class="absolute inset-0 bg-black/50 opacity-0 transition-opacity duration-300 ease-out"
          phx-mounted={JS.remove_class("opacity-0", to: "#task-modal-backdrop") |> JS.add_class("opacity-100", to: "#task-modal-backdrop")}
          phx-click={close_drawer()}
        />

        <!-- Drawer panel: starts translated fully off-screen to the right
             and slides to rest on mount; closing reverses the same
             transition, and TaskModalTabsHook's transitionend listener
             pushes close_modal once it finishes (see data-closing-event
             below and the hook in code-editor-hook.js). -->
        <div
          id="task-modal"
          phx-hook="TaskModalTabsHook"
          data-closing-event="close_modal"
          phx-mounted={JS.remove_class("translate-x-full", to: "#task-modal") |> JS.add_class("translate-x-0", to: "#task-modal")}
          class="absolute inset-y-0 right-0 bg-base-100 shadow-xl border-l border-base-300 w-full sm:w-[min(50rem,90vw)] flex flex-col translate-x-full transition-transform duration-300 ease-out"
        >
          <div class="flex items-center justify-between px-6 py-4 border-b border-base-300 flex-shrink-0">
            <h2 class="text-lg font-bold text-base-content">Task Properties</h2>
            <button
              phx-click={close_drawer()}
              class="text-base-content/50 hover:text-base-content/70 transition"
            >
              ✕
            </button>
          </div>

          <!-- Tabs -->
          <div class="flex px-6 border-b border-base-300 flex-shrink-0">
            <button
              type="button"
              data-tab-button="properties"
              class="px-3 py-2 text-sm font-medium border-b-2 border-primary text-primary"
            >
              Properties
            </button>
            <button
              type="button"
              data-tab-button="source"
              class="px-3 py-2 text-sm font-medium border-b-2 border-transparent text-base-content/50 hover:text-base-content/70"
            >
              Source Code
            </button>
          </div>

          <form phx-submit="save_task_modal" class="flex flex-col flex-1 min-h-0">
            <input type="hidden" name="original_task_id" value={@selected_task["task_id"]} />

            <div data-tab-panel="properties" class="px-6 py-4 space-y-4 overflow-y-auto">
              <div>
                <label class="block text-sm font-medium text-base-content/70 mb-1">Task Name</label>
                <input
                  type="text"
                  name="task_id"
                  value={@selected_task["task_id"]}
                  class="w-full px-3 py-2 bg-field border border-base-300 rounded text-field-content text-sm focus:outline-none focus:border-focus"
                />
              </div>

              <div>
                <label class="block text-sm font-medium text-base-content/70 mb-1">Task Type</label>
                <select
                  name="task_type"
                  class="w-full px-3 py-2 bg-field border border-base-300 rounded text-field-content text-sm focus:outline-none focus:border-focus"
                >
                  <option value="task" selected={@selected_task["task_type"] == "task"}>Task</option>
                  <option value="condition" selected={@selected_task["task_type"] == "condition"}>Condition</option>
                </select>
              </div>

              <div class="grid grid-cols-2 gap-4">
                <div>
                  <label class="block text-sm font-medium text-base-content/70 mb-1">Pool</label>
                  <input
                    type="text"
                    name="pool"
                    value={@selected_task["pool"] || "default_pool"}
                    class="w-full px-3 py-2 bg-field border border-base-300 rounded text-field-content text-sm focus:outline-none focus:border-focus"
                  />
                </div>
                <div>
                  <label class="block text-sm font-medium text-base-content/70 mb-1">Queue</label>
                  <input
                    type="text"
                    name="queue"
                    value={@selected_task["queue"] || "default"}
                    class="w-full px-3 py-2 bg-field border border-base-300 rounded text-field-content text-sm focus:outline-none focus:border-focus"
                  />
                </div>
              </div>

              <div class="grid grid-cols-3 gap-4">
                <div>
                  <label class="block text-sm font-medium text-base-content/70 mb-1">Priority</label>
                  <input
                    type="number"
                    name="priority_weight"
                    value={@selected_task["priority_weight"] || 1}
                    class="w-full px-3 py-2 bg-field border border-base-300 rounded text-field-content text-sm focus:outline-none focus:border-focus"
                  />
                </div>
                <div>
                  <label class="block text-sm font-medium text-base-content/70 mb-1">Max Tries</label>
                  <input
                    type="number"
                    name="max_tries"
                    value={@selected_task["max_tries"] || 0}
                    class="w-full px-3 py-2 bg-field border border-base-300 rounded text-field-content text-sm focus:outline-none focus:border-focus"
                  />
                </div>
                <div>
                  <label class="block text-sm font-medium text-base-content/70 mb-1">Pool Slots</label>
                  <input
                    type="number"
                    name="pool_slots"
                    value={@selected_task["pool_slots"] || 1}
                    class="w-full px-3 py-2 bg-field border border-base-300 rounded text-field-content text-sm focus:outline-none focus:border-focus"
                  />
                </div>
              </div>
            </div>

            <div data-tab-panel="source" class="hidden px-6 py-4 flex-1 min-h-0 flex flex-col">
              <div class="flex items-center justify-between mb-1 flex-shrink-0">
                <label class="block text-sm font-medium text-base-content/70">Source Code</label>
                <select
                  name="source_language"
                  data-code-editor-language-select
                  class="px-2 py-1 bg-field border border-base-300 rounded text-field-content/70 text-xs"
                >
                  <option value="python" selected={@selected_task["source_language"] in [nil, "python"]}>Python</option>
                  <option value="shell" selected={@selected_task["source_language"] == "shell"}>Shell</option>
                  <option value="javascript" selected={@selected_task["source_language"] == "javascript"}>JavaScript</option>
                  <option value="elixir" selected={@selected_task["source_language"] == "elixir"}>Elixir</option>
                </select>
              </div>
              <div
                id="source-code-editor"
                phx-hook="CodeEditorHook"
                phx-update="ignore"
                data-source-code={@selected_task["source_code"] || ""}
                data-source-language={@selected_task["source_language"] || "python"}
                class="border border-base-300 rounded overflow-hidden flex-1 min-h-0"
              >
                <textarea name="source_code" class="hidden"><%= @selected_task["source_code"] || "" %></textarea>
              </div>
            </div>

            <div class="flex justify-end gap-3 px-6 py-4 border-t border-base-300 flex-shrink-0">
              <button
                type="button"
                phx-click={close_drawer()}
                class="px-4 py-2 bg-base-200 hover:bg-base-300 text-base-content text-sm rounded transition-colors"
              >
                Cancel
              </button>
              <button
                type="submit"
                class="px-4 py-2 bg-primary hover:bg-primary/90 text-primary-content text-sm font-semibold rounded transition-colors"
              >
                Save Properties
              </button>
            </div>
          </form>
        </div>
      </div>
    <% end %>

    <!-- DAG Properties Drawer — same slide-in/backdrop/transitionend-close
         pattern as the Task Properties Drawer above (see its comments for
         why JS.push isn't chained directly into the close animation). Two
         tabs: Properties (the DAG's own metadata + a read-only execution
         stats summary) and Source Code (a DAG-level CodeMirror editor,
         reusing TaskModalTabsHook/CodeEditorHook — both already operate
         generically on data-tab-*/data-code-editor-* attributes scoped to
         their own containing element, so a second independent instance on
         this drawer doesn't need any new JS). -->
    <%= if @show_properties_drawer do %>
      <div class="fixed inset-0 z-50">
        <div
          id="dag-properties-drawer-backdrop"
          class="absolute inset-0 bg-black/50 opacity-0 transition-opacity duration-300 ease-out"
          phx-mounted={
            JS.remove_class("opacity-0", to: "#dag-properties-drawer-backdrop")
            |> JS.add_class("opacity-100", to: "#dag-properties-drawer-backdrop")
          }
          phx-click={close_properties_drawer()}
        />

        <div
          id="dag-properties-drawer"
          phx-hook="TaskModalTabsHook"
          data-closing-event="close_properties_drawer"
          phx-mounted={
            JS.remove_class("translate-x-full", to: "#dag-properties-drawer")
            |> JS.add_class("translate-x-0", to: "#dag-properties-drawer")
          }
          class="absolute inset-y-0 right-0 bg-base-100 shadow-xl border-l border-base-300 w-full sm:w-[min(50rem,90vw)] flex flex-col translate-x-full transition-transform duration-300 ease-out"
        >
          <div class="flex items-center justify-between px-6 py-4 border-b border-base-300 flex-shrink-0">
            <h2 class="text-lg font-bold text-base-content">DAG Properties</h2>
            <button
              phx-click={close_properties_drawer()}
              class="text-base-content/50 hover:text-base-content/70 transition"
            >
              ✕
            </button>
          </div>

          <div class="flex px-6 border-b border-base-300 flex-shrink-0">
            <button
              type="button"
              data-tab-button="properties"
              class="px-3 py-2 text-sm font-medium border-b-2 border-primary text-primary"
            >
              Properties
            </button>
            <button
              type="button"
              data-tab-button="source"
              class="px-3 py-2 text-sm font-medium border-b-2 border-transparent text-base-content/50 hover:text-base-content/70"
            >
              Source Code
            </button>
          </div>

          <.form
            for={@properties_form}
            phx-change="validate_properties"
            phx-submit="save_properties"
            class="flex flex-col flex-1 min-h-0"
          >
            <div data-tab-panel="properties" class="px-6 py-4 space-y-2 overflow-y-auto">
              <div class="grid grid-cols-3 gap-3">
                <.input
                  name="dag_id_display"
                  value={@dag_id}
                  label="ID"
                  disabled
                  class="w-full px-3 py-2 bg-base-200 border border-base-300 rounded text-base-content/50 text-sm font-mono"
                />
                <div class="col-span-2">
                  <.input
                    field={@properties_form[:title]}
                    type="text"
                    label="Title"
                    class="w-full px-3 py-2 bg-field border border-base-300 rounded text-field-content text-sm focus:outline-none focus:border-focus"
                  />
                </div>
              </div>

              <.input
                field={@properties_form[:description]}
                type="textarea"
                label="Description"
                class="w-full px-3 py-2 bg-field border border-base-300 rounded text-field-content text-sm focus:outline-none focus:border-focus"
              />

              <.input
                field={@properties_form[:owner]}
                type="text"
                label="Owner"
                class="w-full px-3 py-2 bg-field border border-base-300 rounded text-field-content text-sm focus:outline-none focus:border-focus"
              />

              <.chip_list_input field={@properties_form[:maintainers]} label="Maintainers" />
              <.chip_list_input field={@properties_form[:supporters]} label="Supporters" />
              <.chip_list_input field={@properties_form[:labels]} label="Labels" />

              <div class="grid grid-cols-2 gap-4">
                <div>
                  <label class="block text-sm font-medium text-base-content/70 mb-1">Created</label>
                  <input
                    type="text"
                    value={format_timestamp(@dag.inserted_at)}
                    disabled
                    class="w-full px-3 py-2 bg-base-200 border border-base-300 rounded text-base-content/50 text-sm"
                  />
                </div>
                <div>
                  <label class="block text-sm font-medium text-base-content/70 mb-1">Last Updated</label>
                  <input
                    type="text"
                    value={format_timestamp(@dag.updated_at)}
                    disabled
                    class="w-full px-3 py-2 bg-base-200 border border-base-300 rounded text-base-content/50 text-sm"
                  />
                </div>
                <div>
                  <label class="block text-sm font-medium text-base-content/70 mb-1">Created By</label>
                  <input
                    type="text"
                    value={@dag.created_by || "—"}
                    disabled
                    class="w-full px-3 py-2 bg-base-200 border border-base-300 rounded text-base-content/50 text-sm"
                  />
                </div>
                <div>
                  <label class="block text-sm font-medium text-base-content/70 mb-1">Updated By</label>
                  <input
                    type="text"
                    value={@dag.updated_by || "—"}
                    disabled
                    class="w-full px-3 py-2 bg-base-200 border border-base-300 rounded text-base-content/50 text-sm"
                  />
                </div>
              </div>

              <div class="pt-2 border-t border-base-300">
                <h3 class="text-sm font-semibold text-base-content/70 mb-2">Execution Stats</h3>
                <div class="grid grid-cols-4 gap-3 text-center">
                  <div class="bg-base-200 rounded p-2">
                    <div class="text-lg font-bold text-base-content"><%= @execution_stats.total_runs %></div>
                    <div class="text-xs text-base-content/50">Total runs</div>
                  </div>
                  <div class="bg-base-200 rounded p-2">
                    <div class="text-lg font-bold text-green-600 dark:text-green-400"><%= @execution_stats.success_count %></div>
                    <div class="text-xs text-base-content/50">Succeeded</div>
                  </div>
                  <div class="bg-base-200 rounded p-2">
                    <div class="text-lg font-bold text-red-600 dark:text-red-400"><%= @execution_stats.failed_count %></div>
                    <div class="text-xs text-base-content/50">Failed</div>
                  </div>
                  <div class="bg-base-200 rounded p-2">
                    <div class="text-lg font-bold text-base-content"><%= format_duration(@execution_stats.avg_duration_ms) %></div>
                    <div class="text-xs text-base-content/50">Avg duration</div>
                  </div>
                </div>
                <p class="text-xs text-base-content/50 mt-2">
                  <%= if @execution_stats.last_run do %>
                    Last run: <span class="font-medium"><%= @execution_stats.last_run.status %></span>
                    at <%= format_timestamp(@execution_stats.last_run.start_time) %>
                  <% else %>
                    No runs yet.
                  <% end %>
                </p>
              </div>
            </div>

            <div data-tab-panel="source" class="hidden px-6 py-4 flex-1 min-h-0 flex flex-col">
              <div class="flex items-center justify-between mb-1 flex-shrink-0">
                <label class="block text-sm font-medium text-base-content/70">Source Code</label>
                <select
                  name="dag[source_language]"
                  data-code-editor-language-select
                  class="px-2 py-1 bg-field border border-base-300 rounded text-field-content/70 text-xs"
                >
                  <option value="python" selected={@dag.source_language in [nil, "python"]}>Python</option>
                  <option value="shell" selected={@dag.source_language == "shell"}>Shell</option>
                  <option value="javascript" selected={@dag.source_language == "javascript"}>JavaScript</option>
                  <option value="elixir" selected={@dag.source_language == "elixir"}>Elixir</option>
                </select>
              </div>
              <div
                id="dag-source-code-editor"
                phx-hook="CodeEditorHook"
                phx-update="ignore"
                data-source-code={@dag.source_code || ""}
                data-source-language={@dag.source_language || "python"}
                class="border border-base-300 rounded overflow-hidden flex-1 min-h-0"
              >
                <textarea name="dag[source_code]" class="hidden"><%= @dag.source_code || "" %></textarea>
              </div>
            </div>

            <div class="flex justify-end gap-3 px-6 py-4 border-t border-base-300 flex-shrink-0">
              <button
                type="button"
                phx-click={close_properties_drawer()}
                class="px-4 py-2 bg-base-200 hover:bg-base-300 text-base-content text-sm rounded transition-colors"
              >
                Cancel
              </button>
              <button
                type="submit"
                class="px-4 py-2 bg-primary hover:bg-primary/90 text-primary-content text-sm font-semibold rounded transition-colors"
              >
                Save Properties
              </button>
            </div>
          </.form>
        </div>
      </div>
    <% end %>
    </Layouts.sidebar_shell>
    """
  end

  # Tag/chip-style multi-value input for maintainers/supporters/labels —
  # renders the field's current list as removable chips plus a text box;
  # ChipListHook (assets/js/chip-list-hook.js) owns adding/removing chips
  # client-side and keeps a name="dag[field][]" hidden input per chip in
  # sync, so the surrounding <.form>'s normal phx-change/phx-submit payload
  # already contains the right list — no custom server-side parsing needed
  # beyond normalize_properties_params/1's "missing key means []" handling.
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true

  defp chip_list_input(assigns) do
    ~H"""
    <div>
      <label class="block text-sm font-medium text-base-content/70 mb-1">{@label}</label>
      <div
        id={"#{@field.id}-chips"}
        phx-hook="ChipListHook"
        phx-update="ignore"
        data-field-name={@field.name <> "[]"}
        data-values={Jason.encode!(@field.value || [])}
        class="flex flex-wrap gap-1.5 px-2 py-1.5 bg-field border border-base-300 rounded min-h-[2.25rem]"
      >
      </div>
    </div>
    """
  end

  # ── Private helpers ──

  # Reverses the drawer's/backdrop's entrance transition (slide back
  # off-screen, fade back out) — purely client-side, no server push here.
  # TaskModalTabsHook listens for #task-modal's own transitionend and
  # pushes close_modal itself once the slide has actually finished (see
  # data-closing-event on #task-modal above); a JS.push chained directly
  # after these class changes would fire on the same tick as everything
  # else in the chain (Phoenix.LiveView.JS has no "wait for this CSS
  # transition" primitive), removing @show_modal — and this whole
  # conditional block — before the animation had a chance to play.
  defp close_drawer(js \\ %JS{}) do
    js
    |> JS.remove_class("translate-x-0", to: "#task-modal")
    |> JS.add_class("translate-x-full", to: "#task-modal")
    |> JS.remove_class("opacity-100", to: "#task-modal-backdrop")
    |> JS.add_class("opacity-0", to: "#task-modal-backdrop")
  end

  # Same pattern as close_drawer/1, for the DAG Properties drawer.
  defp close_properties_drawer(js \\ %JS{}) do
    js
    |> JS.remove_class("translate-x-0", to: "#dag-properties-drawer")
    |> JS.add_class("translate-x-full", to: "#dag-properties-drawer")
    |> JS.remove_class("opacity-100", to: "#dag-properties-drawer-backdrop")
    |> JS.add_class("opacity-0", to: "#dag-properties-drawer-backdrop")
  end

  defp format_task_for_js(task) do
    %{
      task_id: task.task_id,
      task_type: task.task_type || "task",
      downstream_list: task.downstream_list || [],
      source_code: task.source_code || "",
      source_language: task.source_language || "python",
      pool: task.pool || "default_pool",
      pool_slots: task.pool_slots || 1,
      priority_weight: task.priority_weight || 1,
      queue: task.queue || "default",
      max_tries: task.max_tries || 0,
      retries: task.retries || 0
    }
  end

  defp assign_properties_form(socket, changeset) do
    assign(socket, properties_form: to_form(changeset, as: :dag))
  end

  # Chip-list fields (maintainers/supporters/labels) arrive from the form as
  # either a list already (repeated name="dag[x][]" inputs) or, if the list
  # ended up empty (no chips at all), the key may be missing entirely —
  # Plug's param parser drops an all-empty-named array rather than sending
  # []. Normalizing missing keys to [] keeps the changeset's cast from
  # treating "field not submitted" as "leave the existing value alone"
  # (cast/3's behavior for an absent key), which would make it impossible
  # to actually clear a chip list down to zero entries.
  defp normalize_properties_params(params) do
    Enum.reduce(~w(maintainers supporters labels), params, fn field, acc ->
      Map.update(acc, field, [], &(&1 || []))
    end)
  end

  defp parse_int(nil, default), do: default
  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end
  defp parse_int(val, _default) when is_integer(val), do: val
  defp parse_int(_, default), do: default

  defp format_timestamp(nil), do: "—"
  defp format_timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_timestamp(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when ms < 1000, do: "#{round(ms)} ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)} s"
end

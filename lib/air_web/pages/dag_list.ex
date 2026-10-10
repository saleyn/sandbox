defmodule AirWeb.Pages.DagList do
  @moduledoc """
  Lists every DAG with search/create/delete/copy/paste, linking out to the
  visual editor (AirWeb.Pages.DagEditor) for create-with-id and edit.

  Delete is soft (Air.DagEditorQuery.delete_dag/1 sets deleted_at) — rows
  are hard-deleted 30 days later by Air.DagRetentionJob, not from this
  page.
  """
  use AirWeb, :live_view

  alias Air.DagEditorQuery

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(search: "")
      |> assign(dags: DagEditorQuery.list_dags())
      |> assign(show_create_form: false)
      |> assign(new_dag_id: "")
      |> assign(create_error: nil)
      |> assign(pending_delete_id: nil)
      |> assign(show_paste_form: false)
      |> assign(paste_json: "")
      |> assign(paste_new_id: "")
      |> assign(paste_error: nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, assign(socket, search: query, dags: DagEditorQuery.search_dags(query))}
  end

  def handle_event("open_create_form", _params, socket) do
    {:noreply, assign(socket, show_create_form: true, new_dag_id: "", create_error: nil)}
  end

  def handle_event("close_create_form", _params, socket) do
    {:noreply, assign(socket, show_create_form: false)}
  end

  def handle_event("validate_new_dag_id", %{"dag_id" => dag_id}, socket) do
    {:noreply, assign(socket, new_dag_id: dag_id, create_error: nil)}
  end

  def handle_event("create_dag", %{"dag_id" => dag_id}, socket) do
    dag_id = String.trim(dag_id)

    cond do
      dag_id == "" ->
        {:noreply, assign(socket, create_error: "DAG ID is required")}

      not Regex.match?(~r/^[a-zA-Z0-9_-]+$/, dag_id) ->
        {:noreply,
         assign(socket, create_error: "Only letters, numbers, underscores, and hyphens are allowed")}

      true ->
        case DagEditorQuery.create_dag(dag_id) do
          {:ok, dag} ->
            {:noreply, push_navigate(socket, to: ~p"/dag/editor/#{dag.dag_id}")}

          {:error, changeset} ->
            message =
              case changeset.errors[:dag_id] do
                {msg, _} -> msg
                nil -> "Could not create DAG"
              end

            {:noreply, assign(socket, create_error: "DAG ID #{message}")}
        end
    end
  end

  def handle_event("confirm_delete", %{"dag_id" => dag_id}, socket) do
    {:noreply, assign(socket, pending_delete_id: dag_id)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, pending_delete_id: nil)}
  end

  def handle_event("delete_dag", %{"dag_id" => dag_id}, socket) do
    socket =
      case DagEditorQuery.delete_dag(dag_id) do
        {:ok, _dag} ->
          socket
          |> put_flash(:info, "Deleted #{dag_id}")
          |> assign(dags: DagEditorQuery.search_dags(socket.assigns.search))

        {:error, :not_found} ->
          put_flash(socket, :error, "DAG #{dag_id} was already deleted")
      end

    {:noreply, assign(socket, pending_delete_id: nil)}
  end

  def handle_event("copy_dag", %{"dag_id" => dag_id}, socket) do
    case DagEditorQuery.export_dag_json(dag_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "DAG #{dag_id} no longer exists")}

      data ->
        json = Jason.encode!(data, pretty: true)
        {:noreply, push_event(socket, "copy_to_clipboard", %{text: json})}
    end
  end

  def handle_event("open_paste_form", _params, socket) do
    {:noreply, assign(socket, show_paste_form: true, paste_json: "", paste_new_id: "", paste_error: nil)}
  end

  def handle_event("close_paste_form", _params, socket) do
    {:noreply, assign(socket, show_paste_form: false)}
  end

  def handle_event("paste_dag", %{"dag_id" => new_dag_id, "json" => json}, socket) do
    new_dag_id = String.trim(new_dag_id)

    with true <- new_dag_id != "" || {:error, "DAG ID is required"},
         true <-
           Regex.match?(~r/^[a-zA-Z0-9_-]+$/, new_dag_id) ||
             {:error, "Only letters, numbers, underscores, and hyphens are allowed"},
         {:ok, decoded} <- Jason.decode(json),
         {:ok, dag} <- DagEditorQuery.import_dag_from_json(new_dag_id, decoded) do
      {:noreply, push_navigate(socket, to: ~p"/dag/editor/#{dag.dag_id}")}
    else
      {:error, %Jason.DecodeError{}} ->
        {:noreply, assign(socket, paste_error: "Clipboard content is not valid JSON")}

      {:error, %Ecto.Changeset{} = changeset} ->
        message = changeset.errors |> Enum.map(fn {field, {msg, _}} -> "#{field} #{msg}" end) |> Enum.join(", ")
        {:noreply, assign(socket, paste_error: message)}

      {:error, msg} when is_binary(msg) ->
        {:noreply, assign(socket, paste_error: msg)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-gray-50 dark:bg-gray-900 min-h-screen" id="dag-list" phx-hook=".ClipboardHook">
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ClipboardHook">
        export default {
          mounted() {
            this.handleEvent("copy_to_clipboard", ({ text }) => {
              navigator.clipboard.writeText(text).catch((err) => console.error("Clipboard write failed:", err))
            })
          }
        }
      </script>

      <div class="max-w-6xl mx-auto p-8">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-3xl font-bold text-gray-900 dark:text-white">DAGs</h1>
          <Layouts.theme_toggle />
        </div>

        <!-- Toolbar: search + actions -->
        <div class="flex flex-wrap items-center gap-3 mb-6">
          <form phx-change="search" class="flex-1 min-w-[16rem]">
            <input
              type="text"
              name="q"
              value={@search}
              placeholder="Search by ID, title, description, owner, or label…"
              phx-debounce="200"
              class="w-full px-3 py-2 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-600 rounded text-gray-900 dark:text-white text-sm focus:outline-none focus:border-blue-500"
            />
          </form>

          <button
            type="button"
            phx-click="open_paste_form"
            class="px-3 py-1.5 bg-gray-200 hover:bg-gray-300 dark:bg-gray-700 dark:hover:bg-gray-600 text-gray-700 dark:text-gray-300 text-sm rounded transition-colors flex items-center gap-1.5"
          >
            <.icon name="hero-clipboard-document" class="size-4" /> Paste DAG
          </button>

          <button
            type="button"
            phx-click="open_create_form"
            class="px-4 py-1.5 bg-blue-600 hover:bg-blue-700 text-white text-sm font-semibold rounded transition-colors flex items-center gap-1.5"
          >
            <.icon name="hero-plus" class="size-4" /> New DAG
          </button>
        </div>

        <!-- Create form (inline, not a full drawer — single field) -->
        <div :if={@show_create_form} class="mb-6 p-4 bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg">
          <form phx-submit="create_dag" phx-change="validate_new_dag_id" class="flex items-start gap-3">
            <div class="flex-1">
              <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">New DAG ID</label>
              <input
                type="text"
                name="dag_id"
                value={@new_dag_id}
                placeholder="my_new_pipeline"
                autofocus
                class="w-full px-3 py-2 bg-white dark:bg-gray-700 border border-gray-300 dark:border-gray-600 rounded text-gray-900 dark:text-white text-sm font-mono focus:outline-none focus:border-blue-500"
              />
              <p :if={@create_error} class="mt-1 text-sm text-red-600 dark:text-red-400">{@create_error}</p>
            </div>
            <div class="flex gap-2 pt-6">
              <button
                type="button"
                phx-click="close_create_form"
                class="px-4 py-2 bg-gray-200 hover:bg-gray-300 dark:bg-gray-700 dark:hover:bg-gray-600 text-gray-700 dark:text-gray-300 text-sm rounded transition-colors"
              >
                Cancel
              </button>
              <button
                type="submit"
                class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white text-sm font-semibold rounded transition-colors"
              >
                Create & Open Editor
              </button>
            </div>
          </form>
        </div>

        <!-- Paste form -->
        <div :if={@show_paste_form} class="mb-6 p-4 bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg">
          <form phx-submit="paste_dag" class="space-y-3">
            <div>
              <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">New DAG ID</label>
              <input
                type="text"
                name="dag_id"
                value={@paste_new_id}
                placeholder="copied_pipeline"
                class="w-full px-3 py-2 bg-white dark:bg-gray-700 border border-gray-300 dark:border-gray-600 rounded text-gray-900 dark:text-white text-sm font-mono focus:outline-none focus:border-blue-500"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                Pasted DAG JSON (from a "Copy" action)
              </label>
              <textarea
                name="json"
                rows="8"
                placeholder="Paste JSON here (Ctrl+V / Cmd+V)…"
                class="w-full px-3 py-2 bg-white dark:bg-gray-700 border border-gray-300 dark:border-gray-600 rounded text-gray-900 dark:text-white text-sm font-mono focus:outline-none focus:border-blue-500"
              >{@paste_json}</textarea>
              <p :if={@paste_error} class="mt-1 text-sm text-red-600 dark:text-red-400">{@paste_error}</p>
            </div>
            <div class="flex justify-end gap-2">
              <button
                type="button"
                phx-click="close_paste_form"
                class="px-4 py-2 bg-gray-200 hover:bg-gray-300 dark:bg-gray-700 dark:hover:bg-gray-600 text-gray-700 dark:text-gray-300 text-sm rounded transition-colors"
              >
                Cancel
              </button>
              <button
                type="submit"
                class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white text-sm font-semibold rounded transition-colors"
              >
                Create from JSON
              </button>
            </div>
          </form>
        </div>

        <!-- Flash -->
        <div :if={@flash["info"]} class="mb-4 p-4 bg-blue-50 dark:bg-blue-900 border border-blue-300 dark:border-blue-600 text-blue-800 dark:text-blue-100 rounded-lg">
          {@flash["info"]}
        </div>
        <div :if={@flash["error"]} class="mb-4 p-4 bg-red-50 dark:bg-red-900 border border-red-300 dark:border-red-600 text-red-800 dark:text-red-100 rounded-lg">
          {@flash["error"]}
        </div>

        <!-- DAG table -->
        <div class="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg overflow-hidden">
          <table class="w-full text-sm">
            <thead class="bg-gray-100 dark:bg-gray-900 text-left">
              <tr>
                <th class="px-4 py-2 font-semibold text-gray-700 dark:text-gray-300">ID</th>
                <th class="px-4 py-2 font-semibold text-gray-700 dark:text-gray-300">Title</th>
                <th class="px-4 py-2 font-semibold text-gray-700 dark:text-gray-300">Owner</th>
                <th class="px-4 py-2 font-semibold text-gray-700 dark:text-gray-300">Labels</th>
                <th class="px-4 py-2 font-semibold text-gray-700 dark:text-gray-300">Updated</th>
                <th class="px-4 py-2"></th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@dags == []}>
                <td colspan="6" class="px-4 py-8 text-center text-gray-500 dark:text-gray-400">
                  <%= if @search != "" do %>
                    No DAGs match "<span class="font-mono">{@search}</span>".
                  <% else %>
                    No DAGs yet — click "New DAG" to create one.
                  <% end %>
                </td>
              </tr>
              <tr
                :for={dag <- @dags}
                class="border-t border-gray-200 dark:border-gray-700 hover:bg-gray-50 dark:hover:bg-gray-900/50"
              >
                <td class="px-4 py-2">
                  <.link navigate={~p"/dag/editor/#{dag.dag_id}"} class="font-mono text-blue-600 dark:text-blue-400 hover:underline">
                    {dag.dag_id}
                  </.link>
                </td>
                <td class="px-4 py-2 text-gray-900 dark:text-white">{dag.title}</td>
                <td class="px-4 py-2 text-gray-600 dark:text-gray-400">{dag.owner || "—"}</td>
                <td class="px-4 py-2">
                  <div class="flex flex-wrap gap-1">
                    <span
                      :for={label <- dag.labels}
                      class="inline-block px-2 py-0.5 rounded-full bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 text-xs"
                    >
                      {label}
                    </span>
                  </div>
                </td>
                <td class="px-4 py-2 text-gray-500 dark:text-gray-400 text-xs">
                  {format_timestamp(dag.updated_at)}
                </td>
                <td class="px-4 py-2">
                  <div class="flex items-center justify-end gap-1">
                    <.link
                      navigate={~p"/dag/editor/#{dag.dag_id}"}
                      title="Edit"
                      class="p-1.5 text-gray-500 hover:text-blue-600 dark:text-gray-400 dark:hover:text-blue-400 rounded hover:bg-gray-100 dark:hover:bg-gray-700"
                    >
                      <.icon name="hero-pencil-square" class="size-4" />
                    </.link>
                    <button
                      type="button"
                      title="Copy as JSON"
                      phx-click="copy_dag"
                      phx-value-dag_id={dag.dag_id}
                      class="p-1.5 text-gray-500 hover:text-blue-600 dark:text-gray-400 dark:hover:text-blue-400 rounded hover:bg-gray-100 dark:hover:bg-gray-700"
                    >
                      <.icon name="hero-document-duplicate" class="size-4" />
                    </button>

                    <%= if @pending_delete_id == dag.dag_id do %>
                      <button
                        type="button"
                        phx-click="delete_dag"
                        phx-value-dag_id={dag.dag_id}
                        class="px-2 py-1 bg-red-600 hover:bg-red-700 text-white text-xs rounded"
                      >
                        Confirm delete
                      </button>
                      <button
                        type="button"
                        phx-click="cancel_delete"
                        class="px-2 py-1 bg-gray-200 hover:bg-gray-300 dark:bg-gray-700 dark:hover:bg-gray-600 text-gray-700 dark:text-gray-300 text-xs rounded"
                      >
                        Cancel
                      </button>
                    <% else %>
                      <button
                        type="button"
                        title="Delete"
                        phx-click="confirm_delete"
                        phx-value-dag_id={dag.dag_id}
                        class="p-1.5 text-gray-500 hover:text-red-600 dark:text-gray-400 dark:hover:text-red-400 rounded hover:bg-gray-100 dark:hover:bg-gray-700"
                      >
                        <.icon name="hero-trash" class="size-4" />
                      </button>
                    <% end %>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp format_timestamp(nil), do: "—"
  defp format_timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end

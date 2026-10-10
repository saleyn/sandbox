defmodule AirWeb.Pages.Settings do
  @moduledoc """
  App-wide settings page. Currently controls the DAG editor's default
  chrome preferences (snap-to-grid, grid visibility, line style/width,
  arrow position, auto-layout direction) — the values a freshly opened
  editor session starts from before the user changes anything via the
  editor's own toolbar/context menu for that session (see
  Air.AppSettingsQuery and AirWeb.Pages.DagEditor's mount/3).

  Single-row, app-wide settings — there's no per-user/accounts system yet,
  so this isn't "my settings", it's "this app's settings".
  """
  use AirWeb, :live_view

  alias Air.{AppSettings, AppSettingsQuery}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_form(socket, AppSettings.changeset(AppSettingsQuery.get(), %{}))}
  end

  @impl true
  def handle_event("validate", %{"app_settings" => params}, socket) do
    changeset =
      AppSettingsQuery.get()
      |> AppSettings.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"app_settings" => params}, socket) do
    case AppSettingsQuery.update(params) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> put_flash(:info, "Settings saved")
         |> assign_form(AppSettings.changeset(settings, %{}))}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.sidebar_shell flash={@flash} current_path="/settings">
      <div class="max-w-2xl mx-auto p-8">
        <h1 class="text-3xl font-bold text-gray-900 dark:text-white mb-1">Settings</h1>
        <p class="text-gray-500 dark:text-gray-400 mb-6">
          Default preferences for new DAG editor sessions.
        </p>

        <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-6">
          <div class="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg p-6 space-y-5">
            <h2 class="text-sm font-semibold text-gray-700 dark:text-gray-300 uppercase tracking-wide">
              DAG Editor Defaults
            </h2>

            <div class="flex items-center justify-between">
              <div>
                <label class="block text-sm font-medium text-gray-900 dark:text-white">Snap to grid</label>
                <p class="text-xs text-gray-500 dark:text-gray-400">Node movement snaps to the grid by default</p>
              </div>
              <.input field={@form[:snap_to_grid]} type="checkbox" />
            </div>

            <div class="flex items-center justify-between">
              <div>
                <label class="block text-sm font-medium text-gray-900 dark:text-white">Show grid</label>
                <p class="text-xs text-gray-500 dark:text-gray-400">Background grid is visible by default</p>
              </div>
              <.input field={@form[:show_grid]} type="checkbox" />
            </div>

            <div class="grid grid-cols-2 gap-4">
              <.input
                field={@form[:line_shape]}
                type="select"
                label="Connection line style"
                options={[Straight: "straight", Curved: "curved", Angled: "angled"]}
              />
              <.input
                field={@form[:line_width]}
                type="select"
                label="Connection line width"
                options={[{"1 px", 1}, {"2 px", 2}, {"3 px", 3}, {"4 px", 4}, {"6 px", 6}]}
              />
            </div>

            <div class="grid grid-cols-2 gap-4">
              <.input
                field={@form[:arrow_position]}
                type="select"
                label="Arrow"
                options={["End": "end", "None": "none"]}
              />
              <.input
                field={@form[:layout_direction]}
                type="select"
                label="Auto layout direction"
                options={[Horizontal: "horizontal", Vertical: "vertical"]}
              />
            </div>
          </div>

          <div class="flex justify-end">
            <button
              type="submit"
              class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white text-sm font-semibold rounded transition-colors"
            >
              Save Settings
            </button>
          </div>
        </.form>
      </div>
    </Layouts.sidebar_shell>
    """
  end

  defp assign_form(socket, changeset) do
    assign(socket, form: to_form(changeset, as: :app_settings))
  end
end

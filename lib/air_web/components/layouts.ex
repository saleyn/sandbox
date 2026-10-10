defmodule AirWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AirWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/" class="flex-1 flex w-fit items-center gap-2">
          <img src={~p"/images/logo.svg"} width="36" />
          <span class="text-sm font-semibold">v{Application.spec(:phoenix, :vsn)}</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-column px-1 space-x-4 items-center">
          <li>
            <a href="https://phoenixframework.org/" class="btn btn-ghost">Website</a>
          </li>
          <li>
            <a href="https://github.com/phoenixframework/phoenix" class="btn btn-ghost">GitHub</a>
          </li>
          <li>
            <.theme_toggle />
          </li>
          <li>
            <a href="https://phoenix.hexdocs.pm/overview.html" class="btn btn-primary">
              Get Started <span aria-hidden="true">&rarr;</span>
            </a>
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  App shell with a collapsible left sidebar (nav: DAGs / Execution History /
  Settings) and a main content area for the current page's own markup.

  Collapse state is pure client-side (a CSS width transition + a
  colocated hook persisting to localStorage, same pattern as the theme
  toggle's own localStorage persistence) — no server round-trip, so it
  survives page navigation without needing a process-level assign.

  ## Examples

      <Layouts.sidebar_shell flash={@flash} current_path={@current_path}>
        <h1>Page content</h1>
      </Layouts.sidebar_shell>
  """
  attr :flash, :map, default: %{}, doc: "the map of flash messages"
  attr :current_path, :string, default: "", doc: "request path, for highlighting the active nav item"
  slot :inner_block, required: true

  def sidebar_shell(assigns) do
    ~H"""
    <div class="h-screen flex bg-gray-50 dark:bg-gray-900" id="app-shell">
      <aside
        id="app-sidebar"
        phx-hook=".SidebarCollapseHook"
        data-collapsed-class="app-sidebar-collapsed"
        class="flex flex-col flex-shrink-0 w-56 bg-white dark:bg-gray-800 border-r border-gray-200 dark:border-gray-700 transition-[width] duration-200 overflow-hidden"
      >
        <script :type={Phoenix.LiveView.ColocatedHook} name=".SidebarCollapseHook">
          export default {
            mounted() {
              const STORAGE_KEY = "dagEditor:sidebarCollapsed"
              const collapsedClass = this.el.dataset.collapsedClass
              const apply = (collapsed) => this.el.classList.toggle(collapsedClass, collapsed)

              let collapsed = false
              try { collapsed = localStorage.getItem(STORAGE_KEY) === "true" } catch {}
              apply(collapsed)

              this.el.querySelector("[data-sidebar-toggle]").addEventListener("click", () => {
                collapsed = !collapsed
                apply(collapsed)
                try { localStorage.setItem(STORAGE_KEY, String(collapsed)) } catch {}
              })
            }
          }
        </script>

        <div class="flex items-center gap-2 px-4 py-4 flex-shrink-0">
          <img src={~p"/images/logo.svg"} width="28" class="flex-shrink-0" />
          <span class="app-sidebar-label font-bold text-gray-900 dark:text-white whitespace-nowrap">Air</span>
        </div>

        <nav class="flex-1 px-2 space-y-1">
          <.sidebar_link navigate={~p"/dags"} current_path={@current_path} match="/dags" icon="hero-rectangle-stack">
            DAGs
          </.sidebar_link>
          <.sidebar_link
            navigate={~p"/demo/dag-execution-history"}
            current_path={@current_path}
            match="/demo/dag-execution-history"
            icon="hero-clock"
          >
            Execution History
          </.sidebar_link>
          <.sidebar_link navigate={~p"/settings"} current_path={@current_path} match="/settings" icon="hero-cog-6-tooth">
            Settings
          </.sidebar_link>
        </nav>

        <div class="flex items-center justify-between px-2 py-3 border-t border-gray-200 dark:border-gray-700 flex-shrink-0">
          <div class="app-sidebar-label">
            <.theme_toggle />
          </div>
          <button
            type="button"
            data-sidebar-toggle
            title="Collapse sidebar"
            class="p-1.5 text-gray-500 hover:text-gray-900 dark:text-gray-400 dark:hover:text-white rounded hover:bg-gray-100 dark:hover:bg-gray-700"
          >
            <.icon name="hero-chevron-double-left" class="size-4 app-sidebar-collapse-icon" />
          </button>
        </div>
      </aside>

      <div class="flex-1 min-w-0 flex flex-col">
        <!-- Top bar: fixed height, never scrolls with the page content
             below it (flex-shrink-0 on a column flex parent) — reserved
             for the future login avatar/account menu and any other
             always-visible, page-independent controls (notifications,
             global search, etc.) once they exist. Empty for now beyond
             the placeholder avatar. -->
        <div class="h-14 flex-shrink-0 flex items-center justify-end gap-3 px-4 border-b border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800">
          <button
            type="button"
            disabled
            title="Account (not implemented yet)"
            class="size-8 flex items-center justify-center rounded-full bg-gray-200 dark:bg-gray-700 text-gray-500 dark:text-gray-400 disabled:cursor-default"
          >
            <.icon name="hero-user" class="size-4" />
          </button>
        </div>

        <main class="flex-1 min-w-0 overflow-y-auto">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :navigate, :string, required: true
  attr :current_path, :string, required: true
  attr :match, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp sidebar_link(assigns) do
    assigns = assign(assigns, :active, String.starts_with?(assigns.current_path, assigns.match))

    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-3 px-2.5 py-2 rounded text-sm font-medium transition-colors",
        @active && "bg-blue-50 dark:bg-blue-900/40 text-blue-700 dark:text-blue-300",
        !@active &&
          "text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700"
      ]}
    >
      <.icon name={@icon} class="size-5 flex-shrink-0" />
      <span class="app-sidebar-label whitespace-nowrap">{render_slot(@inner_block)}</span>
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides a dropdown for picking the system/light/dark theme, based on
  themes defined in app.css.

  The trigger button shows only the currently-active choice's icon (not
  all three at once); clicking it opens a small menu of all three, and
  picking one both applies the theme and closes the menu back down to a
  single icon.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative" id="theme-toggle">
      <!-- Trigger: shows exactly one icon, selected via CSS by matching
           <html>'s data-theme/data-theme-source attributes (same
           ancestor-attribute selector trick the old slider used for its
           sliding highlight) — no server round-trip or JS state needed
           to know which icon is "current". relative + z-50 keeps this
           button clickable above the backdrop below once it's open
           (position: fixed; z-40 would otherwise paint over a
           default-stacked static button). -->
      <!-- The icon's color comes via an inline style, not the
           `text-base-content` utility class — `.btn`/`.btn-ghost` set
           `color: var(--btn-fg)` from inside a nested daisyUI
           sub-layer, and Tailwind's own utility classes (including
           text-base-content) live in a DIFFERENT layer with lower
           cascade-layer priority than that nested sub-layer, so the
           class lost every time no matter how it was written —
           explaining why it stayed black in both themes even after
           adding the class. An inline style has author-level priority
           that cascade layers can't override, so it wins unconditionally. -->
      <button
        type="button"
        class="btn btn-ghost btn-circle btn-sm relative z-50"
        style="color: var(--color-base-content)"
        phx-click={JS.toggle(to: "#theme-toggle-menu") |> JS.toggle(to: "#theme-toggle-backdrop")}
        aria-label="Change color theme"
        aria-haspopup="true"
      >
        <.icon
          name="hero-computer-desktop-micro"
          class="size-4 [[data-theme-source=user]_&]:hidden"
        />
        <.icon
          name="hero-sun-micro"
          class="size-4 hidden [[data-theme-source=user][data-theme=light]_&]:inline-block"
        />
        <.icon
          name="hero-moon-micro"
          class="size-4 hidden [[data-theme-source=user][data-theme=dark]_&]:inline-block"
        />
      </button>

      <!-- Invisible full-viewport backdrop: clicking anywhere outside the
           menu closes it. Toggled in lockstep with the menu by the
           trigger's own JS.toggle above, and again by every option
           below, so it never falls out of sync with the menu's open
           state. z-40 sits below the menu/trigger (z-50) but above
           normal page content. -->
      <div
        id="theme-toggle-backdrop"
        class="hidden fixed inset-0 z-40"
        phx-click={JS.hide(to: "#theme-toggle-menu") |> JS.hide(to: "#theme-toggle-backdrop")}
      />

      <!-- dark:bg-gray-800 overrides bg-base-100 specifically in dark
           mode — daisyUI's own dark-theme --color-base-100 doesn't match
           the gray-800 surface color used everywhere else in this app
           (demo page cards, date picker panels, etc.), so without this
           override the menu looked like a different, inconsistent shade
           of dark. The dark: variant's extra [data-theme=dark] attribute
           selector gives it higher specificity than the plain
           bg-base-100 class, so it reliably wins once dark mode is
           active; light mode is untouched and still uses bg-base-100. -->
      <div
        id="theme-toggle-menu"
        phx-hook="DropdownPositionHook"
        class="hidden absolute right-0 mt-2 w-40 flex flex-col gap-0.5 p-1 rounded-lg border border-base-300 bg-base-100 dark:bg-gray-800 text-base-content shadow-lg z-50"
        role="menu"
      >
        <!-- w-full on every item: without it each button only sizes to
             fit its icon+label, so the hover:bg-base-200 highlight only
             covered that narrow content width instead of spanning the
             whole menu panel. text-base-content on the wrapper above
             ties label color to the current daisyUI theme instead of
             inheriting whatever text color cascades down from the
             surrounding page (which has its own unrelated
             light/dark-mode text classes). -->
        <button
          type="button"
          role="menuitem"
          class="w-full flex items-center gap-2 px-2 py-1.5 rounded hover:bg-base-200 text-sm text-left"
          phx-click={
            JS.dispatch("phx:set-theme")
            |> JS.hide(to: "#theme-toggle-menu")
            |> JS.hide(to: "#theme-toggle-backdrop")
          }
          data-phx-theme="system"
        >
          <.icon name="hero-computer-desktop-micro" class="size-4" /> System
        </button>

        <button
          type="button"
          role="menuitem"
          class="w-full flex items-center gap-2 px-2 py-1.5 rounded hover:bg-base-200 text-sm text-left"
          phx-click={
            JS.dispatch("phx:set-theme")
            |> JS.hide(to: "#theme-toggle-menu")
            |> JS.hide(to: "#theme-toggle-backdrop")
          }
          data-phx-theme="light"
        >
          <.icon name="hero-sun-micro" class="size-4" /> Light
        </button>

        <button
          type="button"
          role="menuitem"
          class="w-full flex items-center gap-2 px-2 py-1.5 rounded hover:bg-base-200 text-sm text-left"
          phx-click={
            JS.dispatch("phx:set-theme")
            |> JS.hide(to: "#theme-toggle-menu")
            |> JS.hide(to: "#theme-toggle-backdrop")
          }
          data-phx-theme="dark"
        >
          <.icon name="hero-moon-micro" class="size-4" /> Dark
        </button>
      </div>
    </div>
    """
  end
end

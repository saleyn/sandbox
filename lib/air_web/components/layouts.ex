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
    <div class="h-screen flex bg-window" id="app-shell">
      <!-- Below md: off-canvas overlay (fixed, slid out via -translate-x-full,
           toggled by the top bar's hamburger button) so content gets the
           full viewport width instead of permanently losing ~224px to a
           sidebar that can't collapse itself away on a small screen.
           At/above md: back to a normal in-flow column, collapsible via
           the existing width-toggling SidebarCollapseHook. Both behaviors
           share the same markup/hook — only the positioning classes
           differ per breakpoint. -->
      <aside
        id="app-sidebar"
        phx-hook=".SidebarCollapseHook"
        data-collapsed-class="app-sidebar-collapsed"
        class="fixed inset-y-0 left-0 z-40 -translate-x-full md:translate-x-0 md:static flex flex-col flex-shrink-0 w-56 bg-base-100 border-r border-base-300 transition-[transform,width] duration-200 overflow-hidden"
      >
        <script :type={Phoenix.LiveView.ColocatedHook} name=".SidebarCollapseHook">
          export default {
            mounted() {
              this.applyCollapsedFromStorage()

              this.el.querySelector("[data-sidebar-toggle]").addEventListener("click", () => {
                const collapsedClass = this.el.dataset.collapsedClass
                const collapsed = !this.el.classList.contains(collapsedClass)
                this.el.classList.toggle(collapsedClass, collapsed)
                try { localStorage.setItem(this.storageKey(), String(collapsed)) } catch {}
              })

              // Mobile off-canvas open/close — independent of the
              // desktop collapse state above (a phone never shows the
              // "collapsed" 4rem rail, it's either fully open or fully
              // hidden off-screen).
              const openClass = "app-sidebar-mobile-open"
              const backdrop = document.getElementById("app-sidebar-backdrop")
              const setOpen = (open) => {
                this.el.classList.toggle(openClass, open)
                backdrop.classList.toggle("hidden", !open)
              }
              document.getElementById("app-sidebar-mobile-toggle").addEventListener("click", () => setOpen(true))
              backdrop.addEventListener("click", () => setOpen(false))
              this.el.querySelectorAll("nav a").forEach((link) => link.addEventListener("click", () => setOpen(false)))
            },

            // Every LiveView patch re-renders this element's class
            // attribute from the server's markup, which has no idea the
            // collapsed class was ever toggled (it's pure client-side,
            // localStorage-backed state — see the moduledoc above
            // sidebar_shell/1). Without this, any patch to the page
            // (e.g. clicking a tab that's handled by handle_params, not a
            // real navigation) silently wipes the collapsed class back
            // off, snapping the sidebar back open. mounted() alone only
            // fires once per real DOM-node creation, so the fix has to
            // reapply on every patch via updated() too.
            updated() {
              this.applyCollapsedFromStorage()
            },

            storageKey() {
              return "dagEditor:sidebarCollapsed"
            },

            applyCollapsedFromStorage() {
              let collapsed = false
              try { collapsed = localStorage.getItem(this.storageKey()) === "true" } catch {}
              this.el.classList.toggle(this.el.dataset.collapsedClass, collapsed)
            }
          }
        </script>

        <div class="flex items-center gap-2 px-4 py-4 flex-shrink-0">
          <img src={~p"/images/logo.svg"} width="28" class="flex-shrink-0" />
          <span class="app-sidebar-label font-bold text-base-content whitespace-nowrap">Air</span>
        </div>

        <nav class="flex-1 px-2 space-y-1">
          <.sidebar_link
            navigate={~p"/dags"}
            current_path={@current_path}
            match="/dags"
            icon="hero-rectangle-stack"
            label="DAGs"
          />
          <.sidebar_link
            navigate={~p"/demo/dag-execution-history"}
            current_path={@current_path}
            match="/demo/dag-execution-history"
            icon="hero-clock"
            label="Execution History"
          />
          <.sidebar_link
            navigate={~p"/settings"}
            current_path={@current_path}
            match="/settings"
            icon="hero-cog-6-tooth"
            label="Settings"
          />
        </nav>

        <div class="app-sidebar-footer flex items-center justify-between px-2 py-3 border-t border-base-300 flex-shrink-0">
          <div class="app-sidebar-label">
            <.theme_toggle />
          </div>
          <button
            type="button"
            data-sidebar-toggle
            aria-label="Collapse sidebar"
            class={["hidden md:block p-1.5 text-base-content/50 hover:text-base-content rounded hover:bg-base-200" | tooltip_class(:top)]}
          >
            <.icon name="hero-chevron-double-left" class="size-4 app-sidebar-collapse-icon" />
          </button>
        </div>
      </aside>

      <div
        id="app-sidebar-backdrop"
        class="hidden fixed inset-0 z-30 bg-black/40 md:hidden"
      />

      <div class="flex-1 min-w-0 flex flex-col">
        <!-- Top bar: fixed height, never scrolls with the page content
             below it (flex-shrink-0 on a column flex parent) — reserved
             for the future login avatar/account menu and any other
             always-visible, page-independent controls (notifications,
             global search, etc.) once they exist. Empty for now beyond
             the placeholder avatar. -->
        <div class="h-14 flex-shrink-0 flex items-center justify-between gap-3 px-4 border-b border-base-300 bg-base-100">
          <button
            type="button"
            id="app-sidebar-mobile-toggle"
            aria-label="Open menu"
            class={["md:hidden p-1.5 -ml-1.5 text-base-content/50 hover:text-base-content rounded hover:bg-base-200" | tooltip_class(:bottom_left)]}
          >
            <.icon name="hero-bars-3" class="size-5" />
          </button>
          <div class="flex-1"></div>
          <button
            type="button"
            disabled
            aria-label="Account (not implemented yet)"
            class={["size-8 flex items-center justify-center rounded-full bg-base-300 text-base-content/50 disabled:cursor-default" | tooltip_class(:bottom_right)]}
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
    <.confirm_dialog />
    """
  end

  attr :navigate, :string, required: true
  attr :current_path, :string, required: true
  attr :match, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp sidebar_link(assigns) do
    assigns = assign(assigns, :active, String.starts_with?(assigns.current_path, assigns.match))

    ~H"""
    <!--
      w-full: without it, this link's box is only as wide as its content
      (icon + padding, since the label is display:none when collapsed —
      see .app-sidebar-label in app.css), sitting flush against nav's left
      padding with nothing constraining/centering it against the right
      edge of the (now much narrower, 4rem) sidebar — the icon LOOKED
      off-center because the link's own box was off-center, not the icon
      within it. Stays justify-start (icon flush left, same as always) by
      default so the expanded layout is unaffected; .app-sidebar-collapsed
      .app-sidebar-nav-link in app.css switches it to justify-center ONLY
      while collapsed, centering the lone icon in the now-full-width link.

      aria-label duplicates the visible label text: when collapsed, the
      <span class="app-sidebar-label"> below is display:none (via app.css),
      which also removes it from the accessible name computation — without
      this, a collapsed nav link would announce as unlabeled to a screen
      reader even though a sighted user still gets the hover tooltip (the
      link's own ::after, via tooltip_class/1 + app-sidebar-collapsed-tooltip
      below — CSS reads this same aria-label directly, see .hover-tooltip
      in app.css — so it never double-tooltips alongside aria-label).

      app-sidebar-collapsed-tooltip (see app.css): only shown while
      collapsed — expanded already shows the real label inline, a
      redundant hover tooltip there would be noise.
    -->
    <.link
      navigate={@navigate}
      aria-label={@label}
      class={
        [
          "app-sidebar-nav-link w-full flex items-center justify-start gap-3 px-2.5 py-2 rounded text-sm font-medium transition-colors app-sidebar-collapsed-tooltip",
          @active && "bg-ghost/10 text-ghost",
          !@active &&
            "text-base-content/70 hover:bg-base-200"
        ] ++ tooltip_class(:right)
      }
    >
      <.icon name={@icon} class="size-5 flex-shrink-0" />
      <span class="app-sidebar-label whitespace-nowrap">{@label}</span>
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

  `id` defaults to "theme-toggle" (the sidebar footer's own instance, the
  original/only call site for a long time) but MUST be overridden with a
  unique value for any additional instance on the same page (e.g. the
  Theme Editor's copy, reachable without expanding the sidebar first) —
  the trigger/menu/backdrop's open-close wiring is all
  `JS.toggle/hide(to: "#\{id}-...")`, so two instances sharing the default
  id would open/close each other's menus instead of their own.
  """
  attr :id, :string, default: "theme-toggle"

  def theme_toggle(assigns) do
    ~H"""
    <div class="relative" id={@id}>
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
        phx-click={JS.toggle(to: "##{@id}-menu") |> JS.toggle(to: "##{@id}-backdrop")}
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
        id={"#{@id}-backdrop"}
        class="hidden fixed inset-0 z-40"
        phx-click={JS.hide(to: "##{@id}-menu") |> JS.hide(to: "##{@id}-backdrop")}
      />

      <div
        id={"#{@id}-menu"}
        phx-hook="DropdownPositionHook"
        class="hidden absolute right-0 mt-2 w-40 flex flex-col gap-0.5 p-1 rounded-lg border border-base-300 bg-base-100 text-base-content shadow-lg z-50"
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
            |> JS.hide(to: "##{@id}-menu")
            |> JS.hide(to: "##{@id}-backdrop")
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
            |> JS.hide(to: "##{@id}-menu")
            |> JS.hide(to: "##{@id}-backdrop")
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
            |> JS.hide(to: "##{@id}-menu")
            |> JS.hide(to: "##{@id}-backdrop")
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

defmodule AirWeb.Pages.Settings do
  @moduledoc """
  App-wide settings page, organized into tabs:

    * "Editor" — the DAG editor's default chrome preferences (snap-to-grid,
      grid visibility, line style/width, arrow position, auto-layout
      direction), backed by the single-row Air.AppSettings /
      Air.AppSettingsQuery (see AirWeb.Pages.DagEditor's mount/3).
    * "Theme Editor" — named light/dark color presets (Air.ThemePreset /
      Air.ThemePresetQuery), applied live via a push_event the root
      layout's script turns into CSS custom-property overrides.

  There's no accounts system yet, so "Editor" settings are app-wide (one
  row, no user scoping) while theme presets use a placeholder user_id
  (see Air.ThemePreset's moduledoc) so the table is ready for real
  per-user scoping once accounts exist.
  """
  use AirWeb, :live_view

  alias Air.{AppSettings, AppSettingsQuery, ThemePreset, ThemePresetQuery}

  # No accounts system yet — every visitor shares this placeholder id, so
  # presets they save are visible to them (and only distinguished from
  # system presets by this id) until real per-user scoping exists.
  @current_user_id "default"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:tab, "editor")
     |> assign_form(AppSettings.changeset(AppSettingsQuery.get(), %{}))
     |> assign_presets()
     |> assign(:selected_preset_id, nil)
     |> assign(:open_scheme, "light")
     |> assign_preset_form(nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in ["editor", "theme"], do: params["tab"], else: "editor"
    {:noreply, assign(socket, :tab, tab)}
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

  def handle_event("select_preset", %{"id" => id}, socket) do
    preset = Enum.find(socket.assigns.presets, &(&1.id == String.to_integer(id)))
    {:noreply, socket |> assign(:selected_preset_id, preset && preset.id) |> assign_preset_form(preset)}
  end

  def handle_event("new_preset", _params, socket) do
    {:noreply, socket |> assign(:selected_preset_id, nil) |> assign_preset_form(nil)}
  end

  def handle_event("toggle_scheme", %{"scheme" => scheme}, socket) when scheme in ["light", "dark"] do
    {:noreply, assign(socket, :open_scheme, scheme)}
  end

  def handle_event("validate_preset", %{"theme_preset" => params}, socket) do
    changeset =
      socket.assigns.preset_form.source.data
      |> ThemePreset.changeset(preset_params(params))
      |> validate_unique_name(socket.assigns.presets, socket.assigns.preset_form.source.data)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :preset_form, to_form(changeset, as: :theme_preset))}
  end

  def handle_event("save_preset", %{"theme_preset" => params}, socket) do
    attrs = preset_params(params) |> Map.put("user_id", @current_user_id)
    base = socket.assigns.preset_form.source.data

    # A system preset (or, once accounts exist, anyone else's) is never
    # updated in place — editing one and saving always forks a brand new
    # preset owned by the current user, same as "Save As" in a document
    # editor. Only a preset this user already owns can be updated in place.
    own_existing? = base.id && not base.is_system && base.user_id == @current_user_id

    changeset =
      base
      |> ThemePreset.changeset(attrs)
      |> validate_unique_name(socket.assigns.presets, base)
      |> Map.put(:action, :validate)

    if changeset.valid? do
      result =
        if own_existing?,
          do: ThemePresetQuery.update(base, attrs),
          else: ThemePresetQuery.create(Map.put(attrs, "is_system", false))

      case result do
        {:ok, preset} ->
          {:noreply,
           socket
           |> put_flash(:info, "Theme \"#{preset.name}\" saved")
           |> assign_presets()
           |> assign(:selected_preset_id, preset.id)
           |> assign_preset_form(preset)}

        {:error, changeset} ->
          {:noreply, assign(socket, :preset_form, to_form(changeset, as: :theme_preset))}
      end
    else
      {:noreply, assign(socket, :preset_form, to_form(changeset, as: :theme_preset))}
    end
  end

  def handle_event("delete_preset", _params, socket) do
    preset = socket.assigns.preset_form.source.data

    case preset.id && not preset.is_system && ThemePresetQuery.delete(preset) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Theme deleted")
         |> assign_presets()
         |> assign(:selected_preset_id, nil)
         |> assign_preset_form(nil)}

      _ ->
        {:noreply, put_flash(socket, :error, "Can't delete this theme")}
    end
  end

  def handle_event("apply_preset", _params, socket) do
    changeset = socket.assigns.preset_form.source

    light = Ecto.Changeset.get_field(changeset, :light_colors)
    dark = Ecto.Changeset.get_field(changeset, :dark_colors)

    {:noreply, push_event(socket, "apply-theme-preset", %{light: light, dark: dark})}
  end

  defp preset_params(params) do
    %{
      "name" => params["name"],
      "light_colors" => strip_colors(params["light_colors"]),
      "dark_colors" => strip_colors(params["dark_colors"])
    }
  end

  # Catches a duplicate name immediately (as the user types, via
  # phx-change) rather than only after a failed DB round-trip — the
  # unique_constraint in ThemePreset.changeset/2 still exists as a
  # backstop against races, but relying on it alone means the error only
  # ever surfaces post-submit. Scoped to presets already visible to this
  # user (same set @presets holds: their own + all system presets), since
  # that's exactly the set a save would conflict against — editing a
  # preset's own name against itself (same id) is not a conflict.
  defp validate_unique_name(changeset, presets, %{id: current_id}) do
    name = Ecto.Changeset.get_field(changeset, :name)

    taken? =
      name not in [nil, ""] and
        Enum.any?(presets, fn p -> p.id != current_id and String.downcase(p.name) == String.downcase(name) end)

    if taken?,
      do: Ecto.Changeset.add_error(changeset, :name, "is already taken"),
      else: changeset
  end

  # Each <input type="color"> submits alongside a LiveView-injected
  # "_unused_<key>" sibling (see Phoenix.Component.used_input?/1) marking
  # inputs untouched since the last change event — real for any LiveView
  # form, not specific to this page. Keep only the actual color keys.
  defp strip_colors(nil), do: %{}

  defp strip_colors(colors) do
    Map.take(colors, ThemePreset.color_keys())
  end

  defp assign_presets(socket) do
    assign(socket, :presets, ThemePresetQuery.list_for_user(@current_user_id))
  end

  defp assign_preset_form(socket, nil) do
    # A brand-new theme starts as a COPY of the system "Default" preset's
    # colors, not blank white — defaulting every swatch to white meant
    # clicking Apply before customizing anything (now that Apply reaches
    # real app chrome, not just this page's own preview) painted the
    # whole app white-on-white. Starting from a real, complete palette
    # means Apply is always safe, and the user only edits the swatches
    # they actually want to change.
    base_preset =
      Enum.find(socket.assigns.presets, & &1.is_system) ||
        Enum.find(socket.assigns.presets, & &1.name == "Default")

    {light_colors, dark_colors} =
      if base_preset,
        do: {base_preset.light_colors, base_preset.dark_colors},
        else: {Map.new(ThemePreset.color_keys(), &{&1, "#ffffff"}), Map.new(ThemePreset.color_keys(), &{&1, "#ffffff"})}

    changeset =
      ThemePreset.changeset(%ThemePreset{user_id: @current_user_id}, %{
        "light_colors" => light_colors,
        "dark_colors" => dark_colors
      })

    assign(socket, :preset_form, to_form(changeset, as: :theme_preset))
  end

  defp assign_preset_form(socket, %ThemePreset{} = preset) do
    assign(socket, :preset_form, to_form(ThemePreset.changeset(preset, %{}), as: :theme_preset))
  end

  defp assign_form(socket, changeset) do
    assign(socket, form: to_form(changeset, as: :app_settings))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.sidebar_shell flash={@flash} current_path="/settings">
      <div class={["p-3 sm:p-8", if(@tab == "theme", do: "max-w-[59rem]", else: "max-w-3xl")]}>
        <h1 class="text-3xl font-bold text-base-content mb-1">Settings</h1>
        <p class="text-base-content/50 mb-6">App-wide preferences.</p>

        <div class="border-b border-base-300 mb-6 flex items-center justify-between">
          <nav class="flex gap-6 -mb-px">
            <.tab_link label="Editor" tab="editor" current={@tab} />
            <.tab_link label="Theme Editor" tab="theme" current={@tab} />
          </nav>
          <!--
            Page-level controls for the Theme Editor tab, grouped here next
            to the tab bar rather than inside the preset-editing form below
            — both act on something OTHER than the preset being edited
            (the app's live theme; an explanation of the color system
            itself), so neither belongs mixed in with the per-preset
            Import/Copy/Paste/Delete/Apply/Save actions in the form's own
            button row. theme_toggle needs its own id (see
            Layouts.theme_toggle/1's moduledoc) since the sidebar footer
            already mounts one with the default id on the same page.
          -->
          <div :if={@tab == "theme"} class="mb-2 flex items-center gap-2">
            <Layouts.theme_toggle id="theme-editor-theme-toggle" />
            <button
              type="button"
              phx-click={open_color_guide()}
              aria-label="What is each color used for?"
              class={["size-5 shrink-0 flex items-center justify-center rounded-full border border-base-300 text-base-content/50 hover:text-base-content hover:border-base-content/50 text-xs font-semibold" | tooltip_class(:bottom_right)]}
            >
              ?
            </button>
          </div>
        </div>

        <.editor_tab :if={@tab == "editor"} form={@form} />
        <.theme_tab
          :if={@tab == "theme"}
          presets={@presets}
          selected_preset_id={@selected_preset_id}
          preset_form={@preset_form}
          open_scheme={@open_scheme}
        />
      </div>

      <.color_guide_drawer :if={@tab == "theme"} />
    </Layouts.sidebar_shell>
    """
  end

  # Right-side drawer explaining what every color in the Theme Editor is
  # actually used for across the app — the swatch grid itself only has
  # room for a 1-2 word caption per color (see Air.ThemePreset.
  # shade_caption/1); this is where the full explanation lives, opened via
  # the (?) button next to the tab bar.
  defp color_guide_drawer(assigns) do
    assigns = assign(assigns, :entries, theme_color_guide())

    ~H"""
    <!--
      Same always-mounted, translate-x-full + opacity-0 slide/fade pattern
      as AirWeb.Pages.DagEditor's #dag-properties-drawer (there's no
      shared drawer component — each drawer in this app hand-rolls this).
      Deliberately NOT JS.toggle/JS.show's display-based hide/show: those
      set an inline `style="display: ..."` that overrides a `flex`
      utility class entirely (inline styles always win over classes),
      which silently turned this drawer from a flex column into a plain
      block the instant it opened — collapsing the height the scrollable
      body (flex-1 min-h-0 overflow-y-auto below) needs to size against,
      so it grew to fit ALL its content instead of scrossing. Class-only
      toggling (translate/opacity) never touches `display`, so the `flex`
      class stays in effect the whole time, open or closed.
    -->
    <div
      id="color-guide-backdrop"
      class="fixed inset-0 bg-black/30 z-40 opacity-0 pointer-events-none transition-opacity duration-300 ease-out"
      phx-click={close_color_guide()}
    />
    <div
      id="color-guide-drawer"
      class="fixed inset-y-0 right-0 w-full sm:w-96 bg-base-100 border-l border-base-300 shadow-xl z-50 flex flex-col translate-x-full transition-transform duration-300 ease-out"
    >
      <div class="flex items-center justify-between px-4 py-3 border-b border-base-300 flex-shrink-0">
        <h2 class="text-sm font-semibold text-base-content">What each color is used for</h2>
        <button
          type="button"
          phx-click={close_color_guide()}
          aria-label="Close"
          class={["p-1 rounded text-base-content/50 hover:text-base-content hover:bg-base-200" | tooltip_class(:bottom_right)]}
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>
      <!--
        min-h-0 is load-bearing on a flex child that needs to scroll: a
        flex item's default min-height is auto (shrink to fit content),
        which lets it grow taller than the flex-col parent's own height
        instead of clipping/scrolling — overflow-y-auto alone silently
        does nothing without this, since there's never any overflow to
        scroll if the box keeps growing to contain everything.
      -->
      <div class="flex-1 min-h-0 overflow-y-auto px-4 py-3 space-y-4">
        <div :for={{key, caption, description} <- @entries}>
          <p class="text-xs font-semibold text-base-content">
            {caption} <span class="font-normal text-base-content/40 font-mono">({key})</span>
          </p>
          <p class="text-xs text-base-content/60 mt-0.5">{description}</p>
        </div>
      </div>
    </div>
    """
  end

  defp open_color_guide(js \\ %JS{}) do
    js
    |> JS.remove_class("pointer-events-none opacity-0", to: "#color-guide-backdrop")
    |> JS.add_class("opacity-100", to: "#color-guide-backdrop")
    |> JS.remove_class("translate-x-full", to: "#color-guide-drawer")
    |> JS.add_class("translate-x-0", to: "#color-guide-drawer")
  end

  defp close_color_guide(js \\ %JS{}) do
    js
    |> JS.remove_class("opacity-100", to: "#color-guide-backdrop")
    |> JS.add_class("pointer-events-none opacity-0", to: "#color-guide-backdrop")
    |> JS.remove_class("translate-x-0", to: "#color-guide-drawer")
    |> JS.add_class("translate-x-full", to: "#color-guide-drawer")
  end

  # The long-form text shown in the (?) drawer, one entry per color key —
  # kept here (not in Air.ThemePreset) since this is UI copy, not theme
  # data. Each entry's displayed TITLE comes from
  # Air.ThemePreset.shade_caption/1 — the same function the swatch grid
  # itself uses — so the drawer can never drift out of sync with what the
  # swatch labels actually say (e.g. both say "background", never
  # "background" in one place and "base-100" in the other).
  defp theme_color_guide do
    for {key, description} <- [
          {"base-100", "The background of panels and cards — the default surface almost everything sits on."},
          {"window", "The background of the main app window/shell behind panels (the sidebar area, the DAG editor's canvas) — deliberately separate from \"hover\" so the two don't look identical."},
          {"base-300", "The color of borders and dividers between panels, inputs, and list rows."},
          {"base-content", "The default text color used on top of base-100/window backgrounds."},
          {"base-200", "The highlight color when hovering a row, menu item, or secondary button."},
          {"focus", "The border color a text field or select switches to when focused (clicked into or tabbed to)."},
          {"field", "The background of text inputs, selects, and textareas — intentionally separate from panels so fields stand out."},
          {"field-content", "The text color typed into fields."},
          {"panel-title", "Background of section/table headers — a form panel's own uppercase section label, a table's header row."},
          {"panel-title-content", "Text color on top of panel-title backgrounds."},
          {"ghost", "Background for a tinted \"selected/active, but not a solid filled button\" look — e.g. the active sidebar nav item, or \"+ New theme\" when nothing else is selected."},
          {"ghost-content", "Text/icon color on top of ghost backgrounds — also used as the ghost element's text color when its background is fully transparent (not selected/active)."},
          {"primary", "The main call-to-action color — primary buttons (e.g. \"New DAG\", \"Save\"), links."},
          {"primary-content", "Text/icon color on top of primary-colored buttons and badges."},
          {"secondary", "Secondary button backgrounds — less prominent actions like \"Cancel\" or \"Paste\"."},
          {"secondary-content", "Text/icon color on top of secondary-colored buttons."},
          {"accent", "An alternate accent color, used sparingly for emphasis distinct from primary."},
          {"accent-content", "Text/icon color on top of accent-colored elements."},
          {"neutral", "Muted/neutral button and icon backgrounds, like toolbar icon buttons."},
          {"neutral-content", "Text/icon color on top of neutral-colored elements."},
          {"info", "Background for informational banners, badges, and status indicators."},
          {"info-content", "Text/icon color on top of info-colored elements."},
          {"success", "Background for success banners, badges, and status indicators."},
          {"success-content", "Text/icon color on top of success-colored elements."},
          {"warning", "Background for warning banners, badges, and status indicators."},
          {"warning-content", "Text/icon color on top of warning-colored elements."},
          {"error", "Background for error banners, badges, delete/danger actions, and status indicators."},
          {"error-content", "Text/icon color on top of error-colored elements."}
        ] do
      {key, ThemePreset.shade_caption(key), description}
    end
  end

  attr :label, :string, required: true
  attr :tab, :string, required: true
  attr :current, :string, required: true

  defp tab_link(assigns) do
    ~H"""
    <.link
      patch={~p"/settings?tab=#{@tab}"}
      class={[
        "pb-3 text-sm font-semibold border-b-2 transition-colors",
        @tab == @current && "border-primary text-primary",
        @tab != @current &&
          "border-transparent text-base-content/50 hover:text-base-content/70"
      ]}
    >
      {@label}
    </.link>
    """
  end

  attr :form, :map, required: true

  defp editor_tab(assigns) do
    ~H"""
    <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-6">
      <div class="bg-base-100 border border-base-300 rounded-lg p-6 space-y-5">
        <h2 class="text-sm font-semibold text-panel-title-content/70 uppercase tracking-wide">
          DAG Editor Defaults
        </h2>

        <div class="flex items-center justify-between">
          <div>
            <label class="block text-sm font-medium text-base-content">Snap to grid</label>
            <p class="text-xs text-base-content/50">Node movement snaps to the grid by default</p>
          </div>
          <.input field={@form[:snap_to_grid]} type="checkbox" />
        </div>

        <div class="flex items-center justify-between">
          <div>
            <label class="block text-sm font-medium text-base-content">Show grid</label>
            <p class="text-xs text-base-content/50">Background grid is visible by default</p>
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
          disabled={@form.source.changes == %{}}
          class="inline-flex items-center gap-1.5 px-4 py-2 bg-primary hover:bg-primary/90 disabled:bg-base-300 disabled:cursor-not-allowed text-primary-content text-sm font-semibold rounded transition-colors"
        >
          <.icon name="hero-check" class="size-4" /> Save Settings
        </button>
      </div>
    </.form>
    """
  end

  attr :presets, :list, required: true
  attr :selected_preset_id, :integer, required: true
  attr :preset_form, :map, required: true
  attr :open_scheme, :string, required: true

  defp theme_tab(assigns) do
    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-[12rem_1fr] gap-6 items-start">
      <div class="bg-base-100 border border-base-300 rounded-lg p-2 space-y-1">
        <button
          :for={preset <- @presets}
          type="button"
          phx-click="select_preset"
          phx-value-id={preset.id}
          class={[
            "w-full text-left px-3 py-2 rounded text-sm flex items-center justify-between gap-2",
            preset.id == @selected_preset_id && "bg-ghost/10 text-ghost",
            preset.id != @selected_preset_id &&
              "text-base-content/70 hover:bg-base-200"
          ]}
        >
          <span class="truncate">{preset.name}</span>
          <span :if={preset.is_system} class="text-[10px] uppercase tracking-wide text-base-content/50 shrink-0">
            System
          </span>
        </button>

        <button
          type="button"
          phx-click="new_preset"
          class={[
            "w-full text-left px-3 py-2 rounded text-sm flex items-center gap-1.5",
            # "New theme" seeds its colors from Default (see
            # assign_preset_form/2's :nil clause) so the swatches/preview
            # look unchanged right after clicking it — the ONLY visible
            # confirmation that anything happened is the name field
            # clearing and no preset row being selected. Giving this
            # button the same selected-highlight treatment as a selected
            # preset row, whenever nothing else is selected, makes "you're
            # now creating a new theme" an actual visual state instead of
            # an absence of one.
            is_nil(@selected_preset_id) && "bg-ghost/10 text-ghost",
            !is_nil(@selected_preset_id) && "text-ghost hover:bg-base-200"
          ]}
        >
          <.icon name="hero-plus" class="size-4" /> New theme
        </button>
      </div>

      <.form
        for={@preset_form}
        phx-change="validate_preset"
        phx-submit="save_preset"
        class="bg-base-100 border border-base-300 rounded-lg p-2 sm:p-6 space-y-3"
      >
        <!--
          Name field + every button on this row are each wrapped in the
          exact same "fieldset > invisible label-height spacer > control"
          structure .input/1 itself uses internally (fieldset mb-2 > label
          > span.label mb-1 + input) — matching that structure exactly
          (not just visually approximating its height) is what keeps every
          control's TOP edge aligned with the real label's text baseline,
          regardless of how each control's own intrinsic height compares
          to the text input's.

          flex-wrap + the name field forced to w-full below sm: the name
          field alone is already tight against 4 buttons' worth of
          whitespace-nowrap width on a phone-size viewport — wrapping lets
          the name field claim its own full-width row, with all 4 buttons
          flowing onto a second row together, rather than everything
          competing for space on one row and overflowing/squeezing the
          input down to near-nothing.
        -->
        <!--
          Below sm, this whole area is 3 stacked rows instead of one
          flex-wrapped line: name field, then Import/Copy/Paste/Delete
          centered together, then Apply+Save spanning the full width as a
          2-column grid — a flex-wrap of fixed-size buttons at mobile width
          left Apply/Save either overflowing or orphaned on their own
          mostly-empty line, and every button's invisible label-height
          spacer (needed at sm+ to align tops with the name field's real
          label) was adding a visible gap ABOVE every wrapped row once
          stacked, since each row no longer shares a baseline with
          anything. gap-2 on the outer column (both below and at sm+)
          compensates for losing each row's own mb-2 (hidden below sm) so
          rows still have SOME breathing room, just not doubled up with the
          spacer.
        -->
        <div class="flex flex-col gap-2 sm:flex-row sm:flex-wrap sm:items-start">
          <!--
            lg:w-[calc(100%-21.5rem)]: matches the accordion/swatch grid's
            own 1fr column width below (grid-cols-[1fr_20rem] gap-6 — the
            20rem fixed column plus its 1.5rem gap subtracted from this
            row's full width leaves exactly the same width the 1fr column
            resolves to). This field lives in a full-width row above that
            grid, not inside it, so there's no fixed number the grid itself
            exposes to inherit from directly — calc() is the only way to
            track it without duplicating the name field into the grid's own
            column (which read as visually awkward on its own, disconnected
            from the rest of this row's buttons). Only applied at lg+,
            matching the breakpoint where the grid itself actually becomes
            two columns (grid-cols-1 below that) — sm:w-auto still governs
            the range between "wrap to full width" and "match the grid".
            When Delete is also visible (a non-system preset selected), the
            button row can run just past this width and wrap Apply+Save
            onto their own line — accepted tradeoff, since widening the
            reserved space to avoid that wrap made the name/accordion width
            match visibly imprecise instead.
          -->
          <div class="fieldset mb-0 sm:mb-2 w-full sm:w-auto sm:flex-1 lg:flex-none lg:w-[calc(100%-21.5rem)]">
            <.input field={@preset_form[:name]} label="Theme name" placeholder="My custom theme" />
          </div>

          <!-- Import/Copy/Paste/Delete: centered as a group below sm,
               left-aligned in normal flow at sm+. -->
          <div class="flex items-center justify-center gap-2 sm:contents">
            <div class="fieldset mb-0 sm:mb-2">
              <span class="label mb-1 invisible hidden sm:block" aria-hidden="true">spacer</span>
              <.daisyui_paste_box />
            </div>
            <div class="fieldset mb-0 sm:mb-2">
              <span class="label mb-1 invisible hidden sm:block" aria-hidden="true">spacer</span>
              <.clipboard_copy_paste_buttons />
            </div>
            <div :if={@preset_form[:id].value && !@preset_form.source.data.is_system} class="fieldset mb-0 sm:mb-2">
              <span class="label mb-1 invisible hidden sm:block" aria-hidden="true">spacer</span>
              <button
                type="button"
                phx-click="delete_preset"
                data-confirm="Delete this theme?"
                aria-label="Delete theme"
                class={["h-8.75 w-8.75 inline-flex items-center justify-center rounded border border-error/30 text-error hover:bg-error/10" | tooltip_class(:bottom_right)]}
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </div>

          <!--
            Apply+Save: a full-width 2-column grid below sm (each button
            exactly half the panel's width, together spanning edge to
            edge), reverting to a normal inline flex group pushed to the
            row's right edge (ml-auto) at sm+ — see the comment above this
            whole section for why flex-wrap alone didn't work well here at
            mobile width.
          -->
          <div class="flex gap-2 sm:flex sm:ml-auto">
            <div class="fieldset mb-0 sm:mb-2">
              <span class="label mb-1 invisible hidden sm:block" aria-hidden="true">spacer</span>
              <button
                type="button"
                phx-click="apply_preset"
                aria-label="Apply current theme"
                class={["w-full sm:w-auto h-8.75 px-2 inline-flex items-center justify-center gap-1.5 text-sm font-semibold rounded border border-base-300 text-base-content hover:bg-base-200 whitespace-nowrap" | tooltip_class(:bottom_right)]}
              >
                <.icon name="hero-eye" class="size-4" /> Apply
              </button>
            </div>
            <div class="fieldset mb-0 sm:mb-2">
              <span class="label mb-1 invisible hidden sm:block" aria-hidden="true">spacer</span>
              <button
                type="submit"
                aria-label="Save current theme"
                disabled={@preset_form.source.changes == %{}}
                class={["w-full sm:w-auto h-8.75 px-3 inline-flex items-center justify-center gap-1.5 bg-primary hover:bg-primary/90 disabled:bg-base-300 disabled:cursor-not-allowed text-primary-content text-sm font-semibold rounded transition-colors whitespace-nowrap" | tooltip_class(:bottom_right)]}
              >
                <.icon name="hero-check" class="size-4" /> Save
              </button>
            </div>
          </div>
        </div>

        <!--
          Light/Dark swatches are an accordion (one open at a time) with a
          SINGLE preview to the right reflecting whichever is open, rather
          than both schemes' swatches + their own separate previews shown
          at once side by side — showing all ~22 swatches x 2 schemes plus
          two previews simultaneously was simply too much at once. The
          closed scheme's own colors aren't lost — they're still right
          there in @preset_form, just not rendered — switching which
          accordion section is open is purely a client-driven
          @open_scheme assign, no data changes.
        -->
        <!--
          items-stretch (not items-start) + the right column being a
          flex-col where theme_preview takes flex-1 and scratch_pad stays
          its own natural height: together these make the right column's
          TOTAL height (preview + scratch pad) always match the left
          column's (the accordion stack) exactly, whichever scheme is
          open/however tall that makes the accordion — rather than the
          right column having its own independent, possibly
          shorter-or-taller height.
        -->
        <div class="grid grid-cols-1 lg:grid-cols-[1fr_20rem] gap-6 items-stretch">
          <!--
            flex-col (not space-y-2's plain block stacking): the left
            column's own height is forced to match the right column's via
            items-stretch above, but a block-stacked column has no notion
            of "leftover space at the bottom" to give to anything — it
            just leaves it as blank space below both sections. flex-col +
            the open section's own flex-1 (see scheme_accordion_section/1)
            makes the OPEN section itself grow to consume that leftover
            space, rather than the column merely being tall enough to
            contain two normally-sized sections with a gap underneath.
          -->
          <div class="flex flex-col gap-2">
            <.scheme_accordion_section
              scheme="light"
              label="Light"
              open={@open_scheme == "light"}
              field_prefix="light_colors"
              form={@preset_form}
            />
            <.scheme_accordion_section
              scheme="dark"
              label="Dark"
              open={@open_scheme == "dark"}
              field_prefix="dark_colors"
              form={@preset_form}
            />
          </div>

          <div class="flex flex-col gap-4">
            <.theme_preview
              title={String.capitalize(@open_scheme)}
              colors={preset_colors(@preset_form, String.to_existing_atom("#{@open_scheme}_colors"))}
            />
            <!--
              Hidden below lg: the scratch pad's drag-and-drop swap
              workflow assumes a mouse (native HTML5 drag events don't
              have a touch equivalent without extra JS), and the screen is
              too narrow for it to earn its space next to the
              already-tight accordion/preview on mobile.
            -->
            <.scratch_pad class="hidden lg:block" />
          </div>
        </div>
      </.form>
    </div>
    """
  end

  defp preset_colors(form, field) do
    Map.get(form.source.changes, field) || Map.get(form.source.data, field) || %{}
  end

  attr :scheme, :string, required: true
  attr :label, :string, required: true
  attr :open, :boolean, required: true
  attr :field_prefix, :string, required: true
  attr :form, :map, required: true

  defp scheme_accordion_section(assigns) do
    ~H"""
    <div class={["border border-base-300 rounded-lg overflow-hidden flex flex-col", @open && "flex-1"]}>
      <button
        type="button"
        phx-click="toggle_scheme"
        phx-value-scheme={@scheme}
        class={[
          "w-full flex items-center justify-between px-4 py-2.5 text-sm font-semibold transition-colors",
          @open && "bg-base-200 text-base-content",
          !@open && "bg-base-100 text-base-content/70 hover:bg-base-200"
        ]}
      >
        {@label}
        <.icon name="hero-chevron-down" class={["size-4 transition-transform", @open && "rotate-180"]} />
      </button>
      <!--
        class="hidden" (NOT :if={@open}) — a closed section's color
        <input>s must stay in the DOM, just visually hidden, or they never
        get submitted with the rest of the form at all. :if={@open} was
        removing them entirely, so saving while e.g. Light was open
        submitted ONLY light_colors with no dark_colors key whatsoever —
        failing ThemePreset.changeset/2's validate_required silently (no
        flash, nothing added to the preset list) since the whole scheme
        was simply absent from params, not just sent with stale values.
      -->
      <div class={["bg-base-100", @open && "flex-1", !@open && "hidden"]}>
        <.color_swatches field_prefix={@field_prefix} form={@form} />
      </div>
    </div>
    """
  end

  # Lets a user paste a theme block exported from daisyUI's own theme
  # generator (daisyui.com/theme-generator) — a
  # `@plugin "daisyui/theme" { --color-base-100: oklch(...); ... }` block —
  # and have its colors fill in the matching Light or Dark swatch set.
  # Parsing + oklch->hex conversion happens client-side (see the colocated
  # hook) so it can write straight into the existing color <input>s and
  # piggyback on the same phx-change wiring color_swatch/1 already has,
  # rather than adding a parallel server-side import path.
  #
  # UI follows the same trigger-button + absolute-positioned popover
  # pattern as Layouts.theme_toggle (JS.toggle on a sibling panel,
  # DropdownPositionHook for viewport clamping/flipping) rather than an
  # always-visible inline box, so it doesn't permanently take up space in
  # the form for what's an occasional action.
  defp daisyui_paste_box(assigns) do
    ~H"""
    <div class="relative" id="daisyui-paste-box">
      <button
        type="button"
        phx-click={JS.toggle(to: "#daisyui-paste-popover") |> JS.toggle(to: "#daisyui-paste-backdrop")}
        aria-label="Import from daisyUI theme generator"
        class={["h-8.75 w-8.75 inline-flex items-center justify-center rounded border border-base-300 text-base-content hover:bg-base-200" | tooltip_class(:bottom_right)]}
      >
        <.icon name="hero-arrow-down-tray" class="size-4" />
      </button>

      <div
        id="daisyui-paste-backdrop"
        class="hidden fixed inset-0 z-40"
        phx-click={JS.hide(to: "#daisyui-paste-popover") |> JS.hide(to: "#daisyui-paste-backdrop")}
      />

      <div
        id="daisyui-paste-popover"
        phx-hook=".DaisyuiPasteHook"
        phx-click-away={JS.hide(to: "#daisyui-paste-popover") |> JS.hide(to: "#daisyui-paste-backdrop")}
        class="hidden absolute right-0 mt-2 w-80 p-3 rounded-lg border border-base-300 bg-base-100 shadow-lg z-50"
      >
        <script :type={Phoenix.LiveView.ColocatedHook} name=".DaisyuiPasteHook">
          export default {
            mounted() {
              this.el.querySelector("[data-paste-apply]").addEventListener("click", () => this.apply())
              this.el.querySelector("[data-paste-close]").addEventListener("click", () => this.close())

              // Viewport clamping/flipping, same approach as
              // dropdown-position-hook.js (horizontal left/right clamp +
              // vertical flip-above-trigger when there's no room below) —
              // duplicated inline rather than shared, since a LiveView
              // element can only declare one phx-hook and this element's
              // primary job is the paste/apply logic above.
              this._reposition = () => this.reposition()
              this._observer = new MutationObserver(this._reposition)
              this._observer.observe(this.el, { attributes: true, attributeFilter: ["class", "style"] })
              window.addEventListener("resize", this._reposition)
            },

            destroyed() {
              this._observer?.disconnect()
              window.removeEventListener("resize", this._reposition)
            },

            reposition() {
              if (this.el.offsetParent === null) return
              this._observer.disconnect()
              try {
                const PADDING = 8
                const rect = this.el.getBoundingClientRect()
                if (rect.right > window.innerWidth - PADDING || rect.left < PADDING) {
                  const clampedLeft = Math.min(Math.max(rect.left, PADDING), window.innerWidth - rect.width - PADDING)
                  this.el.style.right = "auto"
                  this.el.style.left = `${clampedLeft}px`
                }

                const trigger = this.el.parentElement
                const triggerRect = trigger.getBoundingClientRect()
                const menuRect = this.el.getBoundingClientRect()
                const fitsBelow = triggerRect.bottom + menuRect.height + PADDING <= window.innerHeight
                const fitsAbove = triggerRect.top - menuRect.height - PADDING >= 0
                if (fitsBelow) {
                  this.el.style.top = ""
                  this.el.style.bottom = ""
                } else if (fitsAbove) {
                  this.el.style.top = "auto"
                  this.el.style.bottom = `${trigger.offsetHeight + 8}px`
                }
              } finally {
                this._observer.observe(this.el, { attributes: true, attributeFilter: ["class", "style"] })
              }
            },

            close() {
              // JS.toggle (used by the trigger button) sets an inline
              // `style.display`, which beats the plain `hidden` CLASS on
              // specificity — adding the class back here would silently
              // no-op, same pitfall as Layouts.theme_toggle's menu.
              // Clearing the inline style directly is what actually hides
              // it, since the element's own `hidden` class in its static
              // markup takes back over once no inline style overrides it.
              const backdrop = document.getElementById("daisyui-paste-backdrop")
              this.el.style.display = "none"
              backdrop.style.display = "none"
            },

            apply() {
              const textarea = this.el.querySelector("textarea")
              const statusEl = this.el.querySelector("[data-paste-status]")
              const text = textarea.value

              const colors = this.parseColors(text)
              const colorKeys = Object.keys(colors)
              if (colorKeys.length === 0) {
                statusEl.textContent = "No --color-* values found in the pasted text."
                statusEl.className = "text-xs text-error mt-2"
                return
              }

              const scheme = this.detectScheme(text)
              const prefix = scheme === "dark" ? "dark_colors" : "light_colors"

              let applied = 0
              for (const [key, hex] of Object.entries(colors)) {
                const input = this.el.closest("form").querySelector(`input[name="theme_preset[${prefix}][${key}]"]`)
                if (!input) continue
                const proto = Object.getPrototypeOf(input)
                const setter = Object.getOwnPropertyDescriptor(proto, "value").set
                setter.call(input, hex)
                input.dispatchEvent(new Event("input", { bubbles: true }))
                applied++
              }
              // One "change" dispatch after all the inputs are updated is
              // enough to trigger LiveView's phx-change once for the whole
              // batch, instead of once per swatch.
              this.el.closest("form").querySelector(`input[name="theme_preset[${prefix}][base-100]"]`)
                ?.dispatchEvent(new Event("change", { bubbles: true }))

              statusEl.textContent = `Applied ${applied} color${applied === 1 ? "" : "s"} to ${scheme === "dark" ? "Dark" : "Light"}.`
              statusEl.className = "text-xs text-success mt-2"
            },

            // Converts oklch(L% C H) -> #rrggbb. Matches the same math used
            // server-side (priv/repo/migrations) to derive this app's own
            // built-in theme hex values from their oklch source, so pasted
            // daisyUI presets land on the same color space conversion.
            oklchToHex(l, c, h) {
              const L = l / 100
              const hRad = (h * Math.PI) / 180
              const a = c * Math.cos(hRad)
              const b = c * Math.sin(hRad)

              const l_ = L + 0.3963377774 * a + 0.2158037573 * b
              const m_ = L - 0.1055613458 * a - 0.0638541728 * b
              const s_ = L - 0.0894841775 * a - 1.291485548 * b
              const l3 = l_ ** 3, m3 = m_ ** 3, s3 = s_ ** 3

              let r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
              let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
              let bl = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.707614701 * s3

              const toSrgb = (v) => {
                v = Math.max(0, Math.min(1, v))
                return v <= 0.0031308 ? 12.92 * v : 1.055 * Math.pow(v, 1 / 2.4) - 0.055
              }
              r = toSrgb(r); g = toSrgb(g); bl = toSrgb(bl)
              const to255 = (v) => Math.round(Math.max(0, Math.min(1, v)) * 255)
              const hex = (n) => n.toString(16).padStart(2, "0")
              return `#${hex(to255(r))}${hex(to255(g))}${hex(to255(bl))}`
            },

            parseColors(text) {
              const colors = {}
              const re = /--color-([a-z0-9-]+):\s*oklch\(\s*([\d.]+)%\s+([\d.]+)\s+([\d.]+)\s*\)/gi
              let match
              while ((match = re.exec(text)) !== null) {
                const [, key, l, c, h] = match
                colors[key] = this.oklchToHex(parseFloat(l), parseFloat(c), parseFloat(h))
              }
              return colors
            },

            detectScheme(text) {
              const csMatch = text.match(/color-scheme:\s*"?(light|dark)"?/i)
              if (csMatch) return csMatch[1].toLowerCase()
              const pdMatch = text.match(/prefersdark:\s*(true|false)/i)
              if (pdMatch) return pdMatch[1].toLowerCase() === "true" ? "dark" : "light"
              return "light"
            }
          }
        </script>

        <a
          href="https://daisyui.com/theme-generator/"
          target="daisyui-theme-generator"
          rel="noopener noreferrer"
          class="flex items-center gap-1 text-sm font-semibold text-primary hover:underline mb-2"
        >
          DaisyUI theme generator <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
        </a>

        <textarea
          rows="6"
          placeholder={"@plugin \"daisyui/theme\" {\n  name: \"business\";\n  --color-base-100: oklch(...);\n  ...\n}"}
          class="w-full px-2.5 py-1.5 rounded text-xs font-mono border border-base-300 bg-field text-field-content placeholder:text-field-content/40"
        ></textarea>

        <p data-paste-status class="text-xs text-base-content/50 mt-1.5 min-h-4"></p>

        <div class="flex items-center justify-end gap-2 mt-2">
          <button
            type="button"
            data-paste-close
            class="inline-flex items-center gap-1.5 px-3 py-1.5 text-sm font-semibold rounded border border-base-300 text-base-content hover:bg-base-200"
          >
            <.icon name="hero-x-mark" class="size-4" /> Close
          </button>
          <button
            type="button"
            aria-label="Apply the pasted colors to the swatches above"
            data-paste-apply
            class="inline-flex items-center gap-1.5 px-3 py-1.5 text-sm font-semibold rounded bg-primary hover:bg-primary/90 text-primary-content"
          >
            <.icon name="hero-check" class="size-4" /> Apply
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Copy serializes the CURRENT in-progress form state (not the last-saved
  # DB row — see the hook's reading straight from the live <input
  # type="color">s) as JSON to the system clipboard; Paste reads clipboard
  # text back and reapplies it the same way Import applies a parsed
  # daisyUI block. Meant as a quick undo-style safety net while
  # experimenting: copy before making a round of changes, paste back if
  # the result doesn't look right — independent of Save Theme, so it works
  # whether or not you've saved anything yet.
  defp clipboard_copy_paste_buttons(assigns) do
    ~H"""
    <div class="relative flex gap-2" id="theme-clipboard-buttons" phx-hook=".ThemeClipboardHook">
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ThemeClipboardHook">
        export default {
          mounted() {
            this.el.querySelector("[data-clipboard-copy]").addEventListener("click", () => this.copy())
            this.el.querySelector("[data-clipboard-paste]").addEventListener("click", () => this.paste())

            // Polls the clipboard so Paste can disable itself when there's
            // nothing valid to paste — there's no event for "clipboard
            // changed", so this is the only way to track it short of
            // requiring a click first. Mounted/destroyed exactly track
            // whether the Theme Editor tab is showing (this element only
            // exists in that tab's own markup — see theme_tab/1), so the
            // timer is naturally paused whenever it's not visible.
            this.checkClipboard()
            this._clipboardTimer = setInterval(() => this.checkClipboard(), 1500)
          },

          destroyed() {
            clearInterval(this._clipboardTimer)
          },

          async checkClipboard() {
            const pasteBtn = this.el.querySelector("[data-clipboard-paste]")
            let valid = false
            try {
              const payload = JSON.parse(await navigator.clipboard.readText())
              valid =
                typeof payload === "object" && payload !== null &&
                ["light_colors", "dark_colors"].some((prefix) => {
                  const colors = payload[prefix]
                  return colors && typeof colors === "object" &&
                    Object.values(colors).some((hex) => /^#[0-9a-fA-F]{6}$/.test(hex))
                })
            } catch {
              valid = false
            }
            pasteBtn.disabled = !valid
            pasteBtn.classList.toggle("opacity-40", !valid)
            pasteBtn.classList.toggle("cursor-not-allowed", !valid)
          },

          readSchemeColors(prefix) {
            const colors = {}
            this.el.closest("form").querySelectorAll(`input[name^="theme_preset[${prefix}]"]`).forEach((input) => {
              const match = input.name.match(/\[([^\]]+)\]$/)
              if (match) colors[match[1]] = input.value
            })
            return colors
          },

          async copy() {
            const payload = {
              light_colors: this.readSchemeColors("light_colors"),
              dark_colors: this.readSchemeColors("dark_colors")
            }
            try {
              await navigator.clipboard.writeText(JSON.stringify(payload, null, 2))
              this.flashStatus("[data-clipboard-copy]", "Copied!")
            } catch {
              this.flashStatus("[data-clipboard-copy]", "Clipboard blocked")
            }
          },

          async paste() {
            let payload
            try {
              const text = await navigator.clipboard.readText()
              payload = JSON.parse(text)
            } catch {
              this.flashStatus("[data-clipboard-paste]", "Invalid clipboard")
              return
            }

            if (typeof payload !== "object" || payload === null) {
              this.flashStatus("[data-clipboard-paste]", "Invalid clipboard")
              return
            }

            let applied = 0
            for (const prefix of ["light_colors", "dark_colors"]) {
              const colors = payload[prefix]
              if (!colors || typeof colors !== "object") continue
              for (const [key, hex] of Object.entries(colors)) {
                if (!/^#[0-9a-fA-F]{6}$/.test(hex)) continue
                const input = this.el.closest("form").querySelector(`input[name="theme_preset[${prefix}][${key}]"]`)
                if (!input) continue
                const proto = Object.getPrototypeOf(input)
                const setter = Object.getOwnPropertyDescriptor(proto, "value").set
                setter.call(input, hex)
                input.dispatchEvent(new Event("input", { bubbles: true }))
                applied++
              }
            }

            if (applied === 0) {
              this.flashStatus("[data-clipboard-paste]", "Invalid clipboard")
              return
            }

            // One "change" dispatch after every input is updated triggers
            // LiveView's phx-change once for the whole batch, matching the
            // same batching trick Import's own apply() uses.
            this.el.closest("form").querySelector('input[name="theme_preset[light_colors][base-100]"]')
              ?.dispatchEvent(new Event("change", { bubbles: true }))

            this.flashStatus("[data-clipboard-paste]", `Applied ${applied}!`)
          },

          // Briefly swaps the button's OWN hover tooltip text to a result
          // message and forces it visible for a moment — a self-contained
          // popup anchored to the button that triggered it, rather than a
          // separate status element sitting in the button row's own flow.
          // A previous version used a dedicated status <span> whose
          // positioning classes got wholesale-overwritten by a className
          // reset on first use, silently turning it from a non-flow
          // absolutely-positioned element into a normal inline one that
          // pushed Apply/Save Theme sideways every time after that.
          flashStatus(buttonSelector, message) {
            const button = this.el.querySelector(buttonSelector)
            const tooltip = button.querySelector("span")
            if (!tooltip) return
            if (tooltip.dataset.originalText === undefined) tooltip.dataset.originalText = tooltip.textContent
            tooltip.textContent = message
            tooltip.classList.add("opacity-100")
            clearTimeout(this._statusTimeout)
            this._statusTimeout = setTimeout(() => {
              tooltip.classList.remove("opacity-100")
              tooltip.textContent = tooltip.dataset.originalText
            }, 1500)
          }
        }
      </script>

      <button
        type="button"
        data-clipboard-copy
        aria-label="Copy current colors to clipboard"
        class={["h-8.75 w-8.75 inline-flex items-center justify-center rounded border border-base-300 text-base-content hover:bg-base-200" | tooltip_class(:bottom_right)]}
      >
        <.icon name="hero-clipboard-document" class="size-4" />
      </button>

      <button
        type="button"
        data-clipboard-paste
        disabled
        aria-label="Paste colors from clipboard"
        class={["h-8.75 w-8.75 inline-flex items-center justify-center rounded border border-base-300 text-base-content hover:bg-base-200 opacity-40 cursor-not-allowed disabled:hover:bg-transparent" | tooltip_class(:bottom_right)]}
      >
        <.icon name="hero-clipboard-document-check" class="size-4" />
      </button>
    </div>
    """
  end

  attr :field_prefix, :string, required: true
  attr :form, :map, required: true

  defp color_swatches(assigns) do
    key = String.to_existing_atom(assigns.field_prefix)
    colors = Map.get(assigns.form.source.changes, key) || Map.get(assigns.form.source.data, key) || %{}
    assigns = assign(assigns, :colors, colors) |> assign(:rows, ThemePreset.swatch_rows())

    ~H"""
    <!--
      flex-col h-full + justify-between: this div is the accordion's
      :if={@open} content (flex-1 there — see scheme_accordion_section/1),
      so stretching to h-full and spreading its rows with justify-between
      (equal gaps, including above/below the first/last row via the
      padding below) is what makes the OPEN accordion's total height match
      the right column's (preview + scratch pad) exactly, with the swatch
      rows evenly filling whatever that height turns out to be rather than
      clumping at the top with dead space below.
    -->
    <div class="h-full flex flex-col justify-between py-5 px-10">
      <!--
        grid-cols-4 with each cell's content centered (not a flex row): every
        row has exactly 4 swatches (see Air.ThemePreset.swatch_rows/0 — the
        12 non-status colors are grouped 4-per-row to match the 4-wide
        status-color row below them), so fixing 4 equal-width columns
        spaces them out evenly across the column's actual width AND keeps
        every row's swatches vertically aligned with the row above/below —
        a flex row with a fixed gap left extra width as dead space on one
        side instead of distributing it, and didn't align column-to-column
        between rows whose captions happen to differ in width.

        :for index drives the ONE visual divider in this grid: a
        horizontal rule between the last "plain" theme row (base-200/focus/
        accent/neutral) and the status-color row (info/success/warning/
        error) — those four read as a distinct group (feedback colors, not
        UI chrome), worth visually separating from everything above. No
        divider between any other rows, and no vertical divider within a
        row. pt-5 on that row only (matching the panel's own p-5) keeps the
        rule visually balanced from the row above, same gap as everywhere
        else — every row otherwise gets identical spacing purely from the
        parent's justify-between, no per-row padding of its own.
      -->
      <div
        :for={{row, index} <- Enum.with_index(@rows)}
        class={["grid grid-cols-4 gap-x-14", index == length(@rows) - 1 && "border-t border-base-300 pt-5"]}
      >
        <div :for={spec <- row} class="flex flex-col items-center gap-1">
          <.color_swatch_pair :if={match?({:pair, _, _}, spec)} field_prefix={@field_prefix} spec={spec} colors={@colors} />
          <.color_swatch_plain :if={match?({:plain, _}, spec)} field_prefix={@field_prefix} spec={spec} colors={@colors} />
        </div>
      </div>
    </div>
    """
  end

  # A single swatch encoding a color/content PAIR at once: bg_key fills the
  # whole square, fg_key fills a smaller circle centered on top (with the
  # "A" sample) — clicking the circle edits fg_key, clicking the
  # surrounding square edits bg_key. Two real <input type="color">s still
  # exist underneath (form submission needs both as real named inputs
  # either way), just visually/interactively split by region instead of
  # shown as two separate swatches — this is what lets the swatch grid
  # show HALF as many boxes as before for every color that has a genuine
  # 1:1 "-content" pairing.
  attr :field_prefix, :string, required: true
  attr :spec, :any, required: true
  attr :colors, :map, required: true

  defp color_swatch_pair(assigns) do
    {:pair, bg_key, fg_key} = assigns.spec
    bg = Map.get(assigns.colors, bg_key, "#ffffff")
    fg = Map.get(assigns.colors, fg_key, "#000000")

    assigns = assign(assigns, bg_key: bg_key, fg_key: fg_key, bg: bg, fg: fg)

    ~H"""
    <div
      draggable="true"
      phx-hook=".ColorSwatchDragHook"
      data-pair-hex={Jason.encode!(%{bg: @bg, fg: @fg})}
      data-apply-fn="pair-input"
      id={"swatch-#{@field_prefix}-#{@bg_key}"}
      class="relative size-10 rounded-md border border-gray-300 dark:border-gray-600 cursor-grab active:cursor-grabbing shadow-sm overflow-hidden shrink-0"
      style={"background-color: #{@bg}"}
    >
      <!--
        The fg circle is a SEPARATE <label>, stacked on top via its own
        absolute positioning rather than relying on any click-region math —
        each color's native color input only ever needs to cover its own
        actual hit area (the circle for fg, the full square minus the
        circle is implicitly the bg label underneath since the circle sits
        ON TOP of it), so clicks naturally route to whichever element is
        actually under the cursor with no manual hit-testing needed.
      -->
      <label
        class="absolute inset-0 flex items-center justify-center cursor-pointer"
        title={"#{@bg_key} — background"}
      >
        <input
          type="color"
          name={"theme_preset[#{@field_prefix}][#{@bg_key}]"}
          value={@bg}
          class="absolute inset-0 opacity-0 cursor-pointer"
        />
      </label>
      <!--
        The circle is OUTLINE-ONLY (border, transparent fill) in
        contrast_color(bg) — just enough of a shape to mark out its own hit
        region against the swatch's background — rather than a solid
        backdrop: a filled circle competed visually with the swatch's own
        bg color for attention, when the circle's only real job is framing
        the "A" letter. The letter itself is fg, at full size/weight, since
        showing the actual fg color legibly is the whole point of this
        element — the circle is just scaffolding around it.
      -->
      <label
        class="absolute inset-0 m-auto size-6 rounded-full flex items-center justify-center text-xs font-bold cursor-pointer"
        style={"border: 1.5px solid #{contrast_color(@bg)}; color: #{@fg}"}
        title={"#{@fg_key} — text/icon color on #{@bg_key}"}
      >
        A
        <input
          type="color"
          name={"theme_preset[#{@field_prefix}][#{@fg_key}]"}
          value={@fg}
          class="absolute inset-0 opacity-0 cursor-pointer rounded-full"
        />
      </label>
      <.color_swatch_drag_hook_script />
    </div>
    <span class="text-xs text-base-content/50 text-center leading-tight max-w-14">
      {ThemePreset.shade_caption(@bg_key)}
    </span>
    """
  end

  # A single plain swatch for a color with no 1:1 "-content" partner —
  # either a background nothing is ever drawn on top of (window, base-300,
  # base-200, focus), or a content color shared by MULTIPLE backgrounds
  # (base-content, drawn on base-100/window/base-300 alike) where merging
  # it into just one of those would misrepresent the others. Same drag/drop
  # mechanics as a pair swatch, just carrying one hex instead of two.
  attr :field_prefix, :string, required: true
  attr :spec, :any, required: true
  attr :colors, :map, required: true

  defp color_swatch_plain(assigns) do
    {:plain, key} = assigns.spec
    value = Map.get(assigns.colors, key, "#ffffff")
    assigns = assign(assigns, key: key, value: value)

    ~H"""
    <label
      draggable="true"
      phx-hook=".ColorSwatchDragHook"
      data-hex={@value}
      data-apply-fn="input"
      id={"swatch-#{@field_prefix}-#{@key}"}
      class="relative size-10 rounded-md border border-gray-300 dark:border-gray-600 cursor-grab active:cursor-grabbing shadow-sm overflow-hidden shrink-0"
      style={"background-color: #{@value}"}
      title={"#{@key} — drag to copy, or drop a color here"}
    >
      <input
        type="color"
        name={"theme_preset[#{@field_prefix}][#{@key}]"}
        value={@value}
        class="absolute inset-0 opacity-0 cursor-pointer"
      />
      <.color_swatch_drag_hook_script />
    </label>
    <span class="text-xs text-base-content/50 text-center leading-tight max-w-14">
      {ThemePreset.shade_caption(@key)}
    </span>
    """
  end

  # Shared colocated hook definition, rendered inline by BOTH swatch kinds
  # (and the scratch pad's own slots below) — Phoenix.LiveView.ColocatedHook
  # scripts are extracted at COMPILE time keyed by name (see
  # core_components.ex's moduledoc note on tooltip/1 for the same pattern),
  # so re-rendering this same <script> tag from multiple call sites costs
  # nothing at runtime: it registers once in the JS bundle regardless of
  # how many swatches/slots end up using `phx-hook=".ColorSwatchDragHook"`.
  defp color_swatch_drag_hook_script(assigns) do
    ~H"""
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ColorSwatchDragHook">
      export default {
        mounted() {
          // Dragging a swatch (or a filled scratch-pad slot — see
          // scratch_pad/1, which uses this exact same hook/class on its
          // own slots) carries its color(s) as a small JSON payload, so
          // ANY swatch or slot can be a drop target for ANY other one —
          // they're all interchangeable, not just theme-swatch ->
          // scratch-pad in one direction. A plain swatch/slot carries
          // {hex}; a pair swatch/slot carries {bg, fg} — dragging a pair
          // always moves BOTH colors together as one unit (there's no way
          // to drag just one half of a merged swatch).
          this.el.addEventListener("dragstart", (e) => {
            // data-pair-hex is already JSON-encoded ({bg, fg}); data-hex
            // is a bare hex string that needs wrapping to the same
            // {hex: ...} shape the drop handler expects from every source.
            let payload
            if (this.el.dataset.pairHex) {
              payload = this.el.dataset.pairHex
            } else if (this.el.dataset.hex) {
              payload = JSON.stringify({ hex: this.el.dataset.hex })
            } else {
              e.preventDefault()
              return
            }
            e.dataTransfer.setData("text/plain", payload)
            e.dataTransfer.effectAllowed = "copy"
          })

          this.el.addEventListener("dragover", (e) => {
            e.preventDefault()
            e.dataTransfer.dropEffect = "copy"
            this.el.classList.add("ring-2", "ring-primary")
          })

          this.el.addEventListener("dragleave", () => {
            this.el.classList.remove("ring-2", "ring-primary")
          })

          this.el.addEventListener("drop", (e) => {
            e.preventDefault()
            this.el.classList.remove("ring-2", "ring-primary")
            let payload
            try {
              payload = JSON.parse(e.dataTransfer.getData("text/plain"))
            } catch {
              return
            }

            const applyFn = this.el.dataset.applyFn
            const setInput = (input, hex) => {
              if (!input || !/^#[0-9a-fA-F]{6}$/.test(hex)) return
              const proto = Object.getPrototypeOf(input)
              const setter = Object.getOwnPropertyDescriptor(proto, "value").set
              setter.call(input, hex)
              input.dispatchEvent(new Event("input", { bubbles: true }))
              input.dispatchEvent(new Event("change", { bubbles: true }))
            }

            if (applyFn === "input" && payload.hex) {
              setInput(this.el.querySelector("input[type=color]"), payload.hex)
            } else if (applyFn === "pair-input" && payload.bg && payload.fg) {
              const inputs = this.el.querySelectorAll("input[type=color]")
              setInput(inputs[0], payload.bg)
              setInput(inputs[1], payload.fg)
            } else if (applyFn === "scratch-slot") {
              // A scratch slot doesn't know in advance whether it'll
              // receive a plain color or a bg+fg pair — it just displays
              // whatever shape actually gets dropped on it, switching its
              // own fg circle's visibility based on the payload at hand.
              const circle = this.el.querySelector("[data-scratch-fg-circle]")
              if (payload.bg && payload.fg) {
                this.el.dataset.pairHex = JSON.stringify({ bg: payload.bg, fg: payload.fg })
                delete this.el.dataset.hex
                this.el.style.backgroundColor = payload.bg
                circle.style.backgroundColor = payload.fg
                circle.classList.remove("hidden")
              } else if (payload.hex) {
                this.el.dataset.hex = payload.hex
                delete this.el.dataset.pairHex
                this.el.style.backgroundColor = payload.hex
                circle.classList.add("hidden")
              } else {
                return
              }
              this.el.classList.remove("border-dashed")
              this.el.classList.add("border-solid")
            }
          })
        }
      }
    </script>
    """
  end

  # A row of blank slots you can drag any swatch's color onto to park it
  # there for comparison, then drag back out onto a DIFFERENT swatch to
  # apply it — an easy way to swap/compare a couple of candidate colors
  # without re-opening a native color picker each time. Slots are pure
  # client-side state (not part of the preset/form — see
  # .ColorSwatchDragHook's "scratch-slot" branch, which only ever updates
  # the slot's own appearance, never submits anything), so they reset on
  # page reload and don't get saved with the theme.
  attr :class, :any, default: nil

  defp scratch_pad(assigns) do
    ~H"""
    <div class={["border border-base-300 rounded-lg p-3 bg-base-100", @class]}>
      <h3 class="text-xs font-semibold text-panel-title-content/50 uppercase tracking-wide mb-1">
        Scratch Pad
      </h3>
      <p class="text-[11px] text-base-content/40 mb-2">
        Drag a color from the swatches here to park it, then drag it onto any swatch to apply.
      </p>
      <div class="flex flex-wrap gap-1.5">
        <div
          :for={n <- 1..6}
          draggable="true"
          phx-hook=".ColorSwatchDragHook"
          data-apply-fn="scratch-slot"
          id={"scratch-slot-#{n}"}
          class="relative size-9 rounded-md border-2 border-dashed border-base-300 flex-shrink-0 cursor-grab active:cursor-grabbing"
          title="Drag a color here to park it (a swatch pair brings both colors)"
        >
          <span data-scratch-fg-circle class="hidden absolute inset-0 m-auto size-4 rounded-full ring-1 ring-black/10" />
          <.color_swatch_drag_hook_script />
        </div>
      </div>
    </div>
    """
  end

  # Cheap relative-luminance check so the "A" sample glyph (and any future
  # swatch label) stays legible regardless of how dark/light the user picks
  # the underlying color — not meant to be a precise WCAG contrast ratio.
  defp contrast_color("#" <> <<r::binary-2, g::binary-2, b::binary-2>>) do
    luminance =
      0.299 * hex_to_int(r) + 0.587 * hex_to_int(g) + 0.114 * hex_to_int(b)

    if luminance > 140, do: "#000000", else: "#ffffff"
  end

  defp contrast_color(_), do: "#000000"

  defp hex_to_int(hex) do
    case Integer.parse(hex, 16) do
      {n, _} -> n
      :error -> 0
    end
  end

  attr :title, :string, required: true
  attr :colors, :map, required: true

  defp theme_preview(assigns) do
    ~H"""
    <div
      class="flex flex-col rounded-lg border border-gray-200 dark:border-gray-700 overflow-hidden"
      style={"background-color: #{Map.get(@colors, "base-100", "#ffffff")}"}
    >
      <!--
        A real panel-title bar (not just text in base-content) — the
        clearest way to show what panel-title/panel-title-content actually
        look like together, same role as dag_list.ex's table <thead> or
        settings.ex's own uppercase section labels.
      -->
      <p
        class="text-[11px] font-semibold uppercase tracking-wide px-4 py-3"
        style={"background-color: #{Map.get(@colors, "panel-title", "#888")}; color: #{Map.get(@colors, "panel-title-content", "#111")}"}
      >
        {@title} preview
      </p>

      <div class="grid grid-cols-2 gap-1.5 px-4 pt-2">
        <.preview_button
          label="Primary"
          bg={Map.get(@colors, "primary", "#888")}
          fg={Map.get(@colors, "primary-content", "#fff")}
        />
        <.preview_button
          label="Secondary"
          bg={Map.get(@colors, "secondary", "#888")}
          fg={Map.get(@colors, "secondary-content", "#fff")}
        />
        <.preview_button
          label="Accent"
          bg={Map.get(@colors, "accent", "#888")}
          fg={Map.get(@colors, "accent-content", "#fff")}
        />
        <.preview_button
          label="Neutral"
          bg={Map.get(@colors, "neutral", "#888")}
          fg={Map.get(@colors, "neutral-content", "#fff")}
        />
      </div>

      <!--
        A real, clickable button + icon button (not just static-colored
        boxes) so hovering/pressing them in the browser shows exactly what
        enabled/hover/active look like with this preset's actual primary
        color — plus one of each explicitly disabled, since a disabled
        control's muted look can't be previewed by hovering/clicking
        alone. hover:/active: need no scoped stylesheet since
        filter:brightness() darkens whatever background-color is already
        set inline, regardless of what color that is — unlike
        hover:bg-whatever, which would need to know the exact color
        up front as a Tailwind class name, not a runtime value. flex-wrap
        so this row doesn't overflow the preview panel on a narrow
        (mobile) viewport — the hint text is first to drop to its own line
        since it's the least essential of the five items.
      -->
      <div class="flex flex-wrap items-center gap-1.5 px-4 py-2">
        <button
          type="button"
          class="px-2.5 py-1.5 rounded text-xs font-semibold transition-[filter] hover:brightness-90 active:brightness-75"
          style={"background-color: #{Map.get(@colors, "primary", "#888")}; color: #{Map.get(@colors, "primary-content", "#fff")}"}
        >
          Button
        </button>
        <button
          type="button"
          disabled
          class="px-2.5 py-1.5 rounded text-xs font-semibold opacity-40 cursor-not-allowed"
          style={"background-color: #{Map.get(@colors, "primary", "#888")}; color: #{Map.get(@colors, "primary-content", "#fff")}"}
        >
          Disabled
        </button>
        <button
          type="button"
          class="size-7 flex items-center justify-center rounded transition-[filter] hover:brightness-90 active:brightness-75"
          style={"background-color: #{Map.get(@colors, "neutral", "#888")}; color: #{Map.get(@colors, "neutral-content", "#fff")}"}
          title="Icon button"
        >
          <.icon name="hero-trash" class="size-4" />
        </button>
        <button
          type="button"
          disabled
          class="size-7 flex items-center justify-center rounded opacity-40 cursor-not-allowed"
          style={"background-color: #{Map.get(@colors, "neutral", "#888")}; color: #{Map.get(@colors, "neutral-content", "#fff")}"}
          title="Disabled icon button"
        >
          <.icon name="hero-trash" class="size-4" />
        </button>
        <span class="text-[9px] text-base-content/40 leading-tight" style={"color: #{Map.get(@colors, "base-content", "#111")}cc"}>
          hover/click<br />to test
        </span>
      </div>

      <div class="grid grid-cols-2 gap-1.5 px-4">
        <input
          type="text"
          readonly
          value="Text field"
          class="w-full px-2.5 py-1.5 rounded text-xs border"
          style={"background-color: #{Map.get(@colors, "field", "#eee")}; color: #{Map.get(@colors, "field-content", "#111")}; border-color: #{Map.get(@colors, "base-300", "#ccc")}"}
        />
        <select
          disabled
          class="w-full px-2.5 py-1.5 rounded text-xs border"
          style={"background-color: #{Map.get(@colors, "field", "#eee")}; color: #{Map.get(@colors, "field-content", "#111")}; border-color: #{Map.get(@colors, "base-300", "#ccc")}"}
        >
          <option>Select field</option>
        </select>
      </div>

      <!--
        "+New theme" and a selected theme-list row (theme_tab/1 above) both
        render with the identical bg-ghost/10 text-ghost combo — there's no
        third variant to show separately, so one swatch stands in for both.
      -->
      <div class="px-4 pt-1.5">
        <div
          class="w-full px-2.5 py-1.5 rounded text-xs font-medium"
          style={"background-color: #{Map.get(@colors, "ghost", "#888")}1a; color: #{Map.get(@colors, "ghost", "#888")}"}
        >
          Ghost (selected/active)
        </div>
      </div>

      <div class="grid grid-cols-2 grid-rows-2 px-4 pt-2 pb-4 gap-1">
        <.preview_alert
          label="Info message"
          bg={Map.get(@colors, "info", "#888")}
          fg={Map.get(@colors, "info-content", "#fff")}
          icon="hero-information-circle-solid"
        />
        <.preview_alert
          label="Success message"
          bg={Map.get(@colors, "success", "#888")}
          fg={Map.get(@colors, "success-content", "#fff")}
          icon="hero-check-circle-solid"
        />
        <.preview_alert
          label="Warning message"
          bg={Map.get(@colors, "warning", "#888")}
          fg={Map.get(@colors, "warning-content", "#fff")}
          icon="hero-exclamation-triangle-solid"
        />
        <.preview_alert
          label="Error message"
          bg={Map.get(@colors, "error", "#888")}
          fg={Map.get(@colors, "error-content", "#fff")}
          icon="hero-x-circle-solid"
        />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :bg, :string, required: true
  attr :fg, :string, required: true

  defp preview_button(assigns) do
    ~H"""
    <button
      type="button"
      disabled
      class="px-2.5 py-1.5 rounded text-xs font-semibold cursor-default"
      style={"background-color: #{@bg}; color: #{@fg}"}
    >
      {@label}
    </button>
    """
  end

  attr :label, :string, required: true
  attr :bg, :string, required: true
  attr :fg, :string, required: true
  attr :icon, :string, required: true

  defp preview_alert(assigns) do
    ~H"""
    <div
      class="flex items-center gap-1.5 px-2.5 py-1.5 rounded text-xs font-medium"
      style={"background-color: #{@bg}; color: #{@fg}"}
    >
      <.icon name={@icon} class="size-4 flex-shrink-0" />
      {@label}
    </div>
    """
  end
end

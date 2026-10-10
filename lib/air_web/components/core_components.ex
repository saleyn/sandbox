defmodule AirWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: AirWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || field_class(), @errors != [] && (@error_class || "border-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || field_class(),
            @errors != [] && (@error_class || "border-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || field_class(),
            @errors != [] && (@error_class || "border-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc """
  Shared Tailwind classes for text inputs/selects/textareas app-wide,
  matching assets/js/grafana-date-picker.js's own field styling exactly
  (the one piece of UI whose look predates and inspired this): bg-field
  (a dedicated color, NOT base-100/200/300 — see --color-field in
  assets/css/app.css for why: it needs to read as visually distinct from
  its surrounding panel in dark mode specifically, which no single
  base-* shade does in both themes at once), a plain 1px base-300 border,
  `rounded` (not daisyUI's own `input`/`select` component classes' default
  radius), and a focus state that's a border-color change only — no glow
  ring — again matching the picker. Exposed publicly (not private) so
  other hand-rolled form controls outside `<.input>` (e.g.
  grafana-date-picker.js's own inputs, Settings' theme-name field if it
  ever stops using <.input>) can reference the exact same string instead
  of hand-copying it and drifting out of sync.
  """
  def field_class,
    do:
      "w-full px-3 py-2 rounded border border-base-300 bg-field text-field-content placeholder:text-field-content/40 focus:outline-none focus:border-focus"

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc """
  Class list for the app-wide custom hover tooltip on icon-only buttons
  (see `.hover-tooltip` in app.css for the full mechanism/rationale vs. a
  native `title`). Pure CSS, no JS: `.hover-tooltip` renders its tooltip
  text via `content: attr(aria-label)` on a `::after` pseudo-element — so
  this merges straight into the TRIGGER's own `class` list (the element
  that already carries `aria-label`), not a separate child element. The
  tooltip message is written exactly once, as the `aria-label` every one
  of these buttons already needs for accessibility.

  `direction` picks which corner/edge of the trigger the tooltip hangs off
  (see the `.hover-tooltip-*` modifier classes in app.css for the exact
  position each one renders).

  ## Examples

      <button
        type="button"
        aria-label="Delete theme"
        class={["group relative ..." | tooltip_class(:top_right)]}
      >
        <.icon name="hero-trash" />
      </button>
  """
  def tooltip_class(direction) when direction in ~w(top bottom bottom_right top_right top_left bottom_left right)a do
    ["hover-tooltip", "hover-tooltip-#{direction |> to_string() |> String.replace("_", "-")}"]
  end

  @doc """
  App-wide confirmation modal, replacing the browser's native
  `window.confirm()` (used by `data-confirm` on a `phx-click` element, and
  by any hook that wants a yes/no gate before doing something destructive)
  with a themed dialog consistent with the rest of the app's chrome.

  Mount exactly ONE of these per page (see `AirWeb.Layouts.sidebar_shell/1`)
  — it's a single shared dialog, not one per trigger. Two independent ways
  to use it:

    * Declaratively: add `data-confirm="Some question?"` to any element
      with a `phx-click` — `.ConfirmDialogHook` (mounted on this component's
      own root) listens for clicks on `[data-confirm]` anywhere in the
      document (capture phase, so it runs before LiveView's own click
      binding on `window`), stops the click from reaching LiveView
      immediately, shows this dialog with that message, and if confirmed,
      temporarily strips `data-confirm` before re-dispatching the click
      (restoring it right after) — `phoenix_html` (imported for
      data-method links) has its own independent `data-confirm` ->
      `window.confirm()` listener on `window` that would otherwise fire a
      SECOND, native confirm on the very click meant to carry the user's
      "yes" through to LiveView's `phx-click`. Exactly mirrors the
      ergonomics of the old `data-confirm` + native `confirm()`, just
      themed and non-blocking.

    * Imperatively from any hook/script: `await window.AppConfirm.ask("Some
      question?")` resolves `true`/`false` — e.g. dag-editor-hook.js's
      paste-replace-or-append check, which needs the answer as a value
      rather than a re-dispatched click.
  """
  def confirm_dialog(assigns) do
    ~H"""
    <div
      id="app-confirm-dialog"
      phx-hook=".ConfirmDialogHook"
      phx-update="ignore"
      class="contents"
    >
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ConfirmDialogHook">
        export default {
          mounted() {
            this.backdrop = this.el.querySelector("[data-confirm-backdrop]")
            this.messageEl = this.el.querySelector("[data-confirm-message]")
            this.confirmBtn = this.el.querySelector("[data-confirm-accept]")
            this.cancelBtn = this.el.querySelector("[data-confirm-cancel]")
            this._resolve = null

            // Capture phase + immediately stopping propagation: this has
            // to run and fully suppress the click BEFORE LiveView's own
            // document-level click listener (registered on bubble phase)
            // ever sees it, or phx-click would fire right alongside
            // showing the dialog instead of waiting for a real answer.
            document.addEventListener("click", (e) => this.interceptClick(e), true)

            this.confirmBtn.addEventListener("click", () => this.resolveWith(true))
            this.cancelBtn.addEventListener("click", () => this.resolveWith(false))
            this.backdrop.addEventListener("click", () => this.resolveWith(false))
            document.addEventListener("keydown", (e) => {
              if (e.key === "Escape" && this.isOpen()) this.resolveWith(false)
            })

            // Exposes ask() to any plain <script>/hook outside LiveView's
            // own hook system (e.g. dag-editor-hook.js) that needs a
            // yes/no answer as a value rather than a re-dispatched click.
            // Only one of this component is ever mounted app-wide (see
            // its moduledoc), so there's no multi-instance clash to guard
            // against on teardown.
            window.AppConfirm = { ask: (message) => this.ask(message) }
          },

          interceptClick(e) {
            const trigger = e.target.closest("[data-confirm]")
            if (!trigger) return

            e.preventDefault()
            e.stopPropagation()
            e.stopImmediatePropagation()

            const message = trigger.getAttribute("data-confirm")

            this.ask(message).then((ok) => {
              if (!ok) return
              // phoenix_html (imported in app.js for data-method links)
              // ALSO listens for data-confirm on every click that bubbles
              // to window, and fires its own native window.confirm() —
              // independently of this hook, and not stoppable by
              // e.preventDefault() on this re-dispatched click (that only
              // suppresses phoenix_html's check on the ORIGINAL click,
              // not a fresh synthetic one). Removing the attribute before
              // re-dispatching, then restoring it right after, lets the
              // click through to LiveView's phx-click binding without
              // phoenix_html ever seeing a message to confirm — and
              // leaves the button ready for its next real click.
              trigger.removeAttribute("data-confirm")
              trigger.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }))
              trigger.setAttribute("data-confirm", message)
            })
          },

          // Promise-based API for non-click callers (e.g. a hook deciding
          // between two outcomes rather than re-dispatching a click) —
          // window.AppConfirm.ask("...") resolves true/false exactly like
          // the old window.confirm(), but never blocks the JS event loop.
          ask(message) {
            this.messageEl.textContent = message
            this.open()
            return new Promise((resolve) => { this._resolve = resolve })
          },

          resolveWith(value) {
            if (!this.isOpen()) return
            this.close()
            const resolve = this._resolve
            this._resolve = null
            resolve?.(value)
          },

          isOpen() {
            return this.el.querySelector("[data-confirm-panel]").dataset.open === "true"
          },

          open() {
            const panel = this.el.querySelector("[data-confirm-panel]")
            panel.dataset.open = "true"
            this.backdrop.classList.remove("pointer-events-none", "opacity-0")
            this.backdrop.classList.add("opacity-100")
            panel.classList.remove("opacity-0", "scale-95", "pointer-events-none")
            panel.classList.add("opacity-100", "scale-100")
            this.confirmBtn.focus()
          },

          close() {
            const panel = this.el.querySelector("[data-confirm-panel]")
            panel.dataset.open = "false"
            this.backdrop.classList.add("pointer-events-none", "opacity-0")
            this.backdrop.classList.remove("opacity-100")
            panel.classList.add("opacity-0", "scale-95", "pointer-events-none")
            panel.classList.remove("opacity-100", "scale-100")
          }
        }
      </script>

      <div
        data-confirm-backdrop
        class="fixed inset-0 bg-black/30 z-[60] opacity-0 pointer-events-none transition-opacity duration-150 ease-out"
      />
      <div
        data-confirm-panel
        data-open="false"
        role="alertdialog"
        aria-modal="true"
        class="fixed inset-0 z-[60] flex items-center justify-center p-4 opacity-0 scale-95 pointer-events-none transition-[opacity,transform] duration-150 ease-out"
      >
        <div class="w-full max-w-sm rounded-lg bg-base-100 border border-base-300 shadow-xl p-5">
          <p data-confirm-message class="text-sm text-base-content"></p>
          <div class="flex items-center justify-end gap-2 mt-4">
            <button
              type="button"
              data-confirm-cancel
              class="px-3 py-1.5 text-sm font-semibold rounded border border-base-300 text-base-content hover:bg-base-200"
            >
              Cancel
            </button>
            <button
              type="button"
              data-confirm-accept
              class="px-3 py-1.5 text-sm font-semibold rounded bg-error hover:bg-error/90 text-error-content"
            >
              Confirm
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(AirWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(AirWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end

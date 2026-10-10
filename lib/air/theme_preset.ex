defmodule Air.ThemePreset do
  @moduledoc """
  A named set of light/dark colors a user (or the system) has saved from
  the Settings > Theme Editor tab. `light_colors`/`dark_colors` are maps
  from a fixed set of daisyUI color keys (see `color_keys/0`) to hex
  strings — the same keys the app's two built-in daisyUI themes define in
  assets/css/app.css: base/content, primary/secondary/accent/neutral, the
  status colors (info/success/warning/error), and non-daisyUI-standard
  additions this app makes: `field`/`field-content` (form input/select/
  textarea backgrounds — see --color-field in app.css), `window` (the
  main app-shell/canvas background, distinct from base-200's
  hover/secondary-fill role — see --color-window in app.css for why those
  two used to collide; has no -content pairing since nothing puts text
  directly on it — it's always a panel/card on top with its own
  base-content), `focus` (the field border color on focus — was
  hardcoded to always equal primary, so picking a primary color that
  didn't read well as a focus ring had no fix short of also changing every
  button's color), `panel-title`/`panel-title-content` (section/table
  header backgrounds — e.g. a table's <thead> or a form panel's own
  uppercase section label — was previously just base-200/base-content at
  reduced opacity, with no way to pick a header color independent of the
  hover-state color it happened to share), and `ghost`/`ghost-content`
  (the tinted "selected/active, but not a solid filled button" look — e.g.
  "+ New theme" when nothing else is selected, or the active sidebar nav
  item — was hardcoded to primary at a fixed 10% opacity, so it could
  never be tuned independently of primary itself). Every other key has its
  paired "-content" (the color text/icons use when sitting on top of it).
  Only non-color tokens (radius/size/border/depth/noise) are not
  user-editable here.

  `user_id` has no foreign key yet — there's no accounts system in this
  app — so it's a plain string. The "system" sentinel marks presets that
  ship with the app and are visible to everyone, same as `is_system`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @color_keys ~w(
    base-100 base-200 base-300 base-content
    primary primary-content
    secondary secondary-content
    accent accent-content
    neutral neutral-content
    info info-content
    success success-content
    warning warning-content
    error error-content
    field field-content
    window
    focus
    panel-title panel-title-content
    ghost ghost-content
  )

  # Swatch grouping/layout for the Theme Editor UI (AirWeb.Pages.Settings).
  # Each row is a list of swatch specs, one of:
  #   {:pair, bg_key, fg_key} — ONE swatch showing both colors at once:
  #     bg_key fills the whole square, fg_key fills a smaller circle
  #     centered on top (with the "A" sample letter) — clicking inside the
  #     circle opens fg_key's color picker, clicking the surrounding square
  #     opens bg_key's. This only applies where a color and its "-content"
  #     are a genuine 1:1 pair (the text color is ONLY ever drawn on that
  #     one background) — see AirWeb.Pages.Settings.color_swatch_pair/1.
  #   {:plain, key} — a single-color swatch, no inner circle, no pairing:
  #     either a "-content" that's shared by MULTIPLE backgrounds
  #     (base-content, drawn on base-100/window/base-300 alike — merging it
  #     into just one of those would misrepresent the other two), or a
  #     background with no content color at all (window, base-300,
  #     base-200, focus — nothing is ever drawn directly on top of these).
  @swatch_rows [
    [{:pair, "base-100", "base-content"}, {:plain, "window"}, {:plain, "base-300"}, {:pair, "panel-title", "panel-title-content"}],
    [{:pair, "ghost", "ghost-content"}, {:pair, "primary", "primary-content"}, {:pair, "field", "field-content"}, {:pair, "secondary", "secondary-content"}],
    [{:plain, "base-200"}, {:plain, "focus"}, {:pair, "accent", "accent-content"}, {:pair, "neutral", "neutral-content"}],
    [
      {:pair, "info", "info-content"},
      {:pair, "success", "success-content"},
      {:pair, "warning", "warning-content"},
      {:pair, "error", "error-content"}
    ]
  ]

  # Short (1-2 word) purpose label shown under EVERY swatch in the Theme
  # Editor — replaces relying on the group name alone (e.g. "primary"
  # covering both the primary swatch AND primary-content with no visual
  # distinction between them). Every "-content" key reads "on <color>",
  # consistently describing where that color is actually used: text/icons
  # placed on top of its paired background. See
  # AirWeb.Pages.Settings.theme_color_guide/0 for the longer explanation
  # of each shown in the (?) help drawer.
  @shade_captions %{
    "base-100" => "background",
    "base-200" => "hover",
    "base-300" => "border",
    "base-content" => "on background",
    "window" => "window",
    "focus" => "focus ring",
    "field" => "field background",
    "field-content" => "on field",
    "panel-title" => "panel title",
    "panel-title-content" => "on panel title",
    "ghost" => "ghost",
    "ghost-content" => "on ghost",
    "primary" => "primary",
    "primary-content" => "on primary",
    "secondary" => "secondary",
    "secondary-content" => "on secondary",
    "accent" => "accent",
    "accent-content" => "on accent",
    "neutral" => "neutral",
    "neutral-content" => "on neutral",
    "info" => "info",
    "info-content" => "on info",
    "success" => "success",
    "success-content" => "on success",
    "warning" => "warning",
    "warning-content" => "on warning",
    "error" => "error",
    "error-content" => "on error"
  }

  def shade_caption(key), do: Map.get(@shade_captions, key, key)

  @system_user_id "system"

  schema "theme_presets" do
    field :user_id, :string, default: @system_user_id
    field :name, :string
    field :is_system, :boolean, default: false
    field :light_colors, :map
    field :dark_colors, :map

    timestamps(type: :utc_datetime)
  end

  def color_keys, do: @color_keys
  def swatch_rows, do: @swatch_rows
  def system_user_id, do: @system_user_id

  def changeset(theme_preset, attrs) do
    theme_preset
    |> cast(attrs, [:user_id, :name, :is_system, :light_colors, :dark_colors])
    |> validate_required([:user_id, :name, :light_colors, :dark_colors])
    |> validate_length(:name, min: 1, max: 60)
    |> validate_colors(:light_colors)
    |> validate_colors(:dark_colors)
    |> unique_constraint([:user_id, :name], name: :theme_presets_user_id_name_index)
  end

  defp validate_colors(changeset, field) do
    validate_change(changeset, field, fn ^field, colors ->
      missing = @color_keys -- Map.keys(colors)
      invalid = for {k, v} <- colors, k in @color_keys, not valid_hex?(v), do: k

      cond do
        missing != [] -> [{field, "missing colors: #{Enum.join(missing, ", ")}"}]
        invalid != [] -> [{field, "invalid hex color for: #{Enum.join(invalid, ", ")}"}]
        true -> []
      end
    end)
  end

  defp valid_hex?(value) when is_binary(value), do: Regex.match?(~r/^#[0-9a-fA-F]{6}$/, value)
  defp valid_hex?(_), do: false
end

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
  base-content), and `focus` (the field border color on focus — was
  hardcoded to always equal primary, so picking a primary color that
  didn't read well as a focus ring had no fix short of also changing every
  button's color). Every other key has its paired "-content" (the color
  text/icons use when sitting on top of it). Only non-color tokens
  (radius/size/border/depth/noise) are not user-editable here.

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
  )

  # Swatch grouping/layout for the Theme Editor UI (AirWeb.Pages.Settings),
  # mirroring daisyUI's own theme generator: each row is a 4-column grid.
  # "base"'s row packs base-100 (background), window (the app-shell/canvas
  # surface — placed here, not with field/hover below, since it's a
  # close cousin of base-100 rather than an interactive state), base-300
  # (border), and base-content into all 4 columns, since none of those
  # four need a "-content" swatch of their own except base-content itself.
  # Every other color is a single color/content pair (2 columns), so two
  # such groups share a row with a vertical divider between them (columns
  # 2 and 3) — except the combined hover/focus pair (base-200 and focus,
  # NEITHER needing a content swatch — both are single accent colors, not
  # surfaces text sits on), which fills what would otherwise be an empty
  # 4th column next to its row partner.

  @swatch_rows [
    [{"base", ["base-100", "window", "base-300"], "base-content"}],
    [{"primary", ["primary"], "primary-content"}, {"field", ["field"], "field-content"}],
    [{"secondary", ["secondary"], "secondary-content"}, {"info", ["info"], "info-content"}],
    [{"accent", ["accent"], "accent-content"}, {"success", ["success"], "success-content"}],
    [{"hover / focus", ["base-200", "focus"], nil}, {"warning", ["warning"], "warning-content"}],
    [{"neutral", ["neutral"], "neutral-content"}, {"error", ["error"], "error-content"}]
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

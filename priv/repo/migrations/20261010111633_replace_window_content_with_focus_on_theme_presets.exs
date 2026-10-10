defmodule Air.Repo.Migrations.ReplaceWindowContentWithFocusOnThemePresets do
  use Ecto.Migration

  # Air.ThemePreset.color_keys/0 dropped "window-content" (it was required
  # by the changeset but had no swatch anywhere in the UI to set it,
  # silently failing every save's validate_colors check — nothing in the
  # app actually puts text directly on the window background to need it)
  # and added "focus" (the field border color on focus — previously
  # hardcoded to always equal primary everywhere; see
  # core_components.ex's field_class/0, dag_editor.ex, dag_list.ex, and
  # assets/js/grafana-date-picker.js, all updated in the same change to
  # read var(--color-focus) instead of the primary color directly).
  # Existing rows: drop window-content, backfill focus from each row's own
  # existing primary value (focus previously WAS primary everywhere, so
  # this preserves current appearance exactly going forward).
  def up do
    execute("""
    UPDATE theme_presets
    SET light_colors = (light_colors - 'window-content') || jsonb_build_object('focus', light_colors->'primary'),
        dark_colors = (dark_colors - 'window-content') || jsonb_build_object('focus', dark_colors->'primary')
    WHERE NOT (light_colors ? 'focus') OR NOT (dark_colors ? 'focus')
    """)
  end

  def down do
    execute("""
    UPDATE theme_presets
    SET light_colors = (light_colors - 'focus') || jsonb_build_object('window-content', light_colors->'base-content'),
        dark_colors = (dark_colors - 'focus') || jsonb_build_object('window-content', dark_colors->'base-content')
    """)
  end
end

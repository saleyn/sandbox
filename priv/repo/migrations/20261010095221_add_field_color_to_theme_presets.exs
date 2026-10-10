defmodule Air.Repo.Migrations.AddFieldColorToThemePresets do
  use Ecto.Migration

  # Air.ThemePreset.color_keys/0 grew a new "field"/"field-content" pair
  # (form input/select/textarea background — see --color-field in
  # assets/css/app.css), matching the grafana-date-picker's own field
  # styling: white fields in light mode (same as the panel), but a
  # lighter-than-panel gray-700 in dark mode (where the panel itself is
  # gray-800), giving fields visible depth instead of blending into their
  # container. Backfill every existing row so the next save of any of them
  # doesn't fail ThemePreset.changeset/2's validate_colors check.
  def up do
    execute("""
    UPDATE theme_presets
    SET light_colors = light_colors || '{"field":"#ffffff","field-content":"#111827"}'::jsonb,
        dark_colors = dark_colors || '{"field":"#374151","field-content":"#f9fafb"}'::jsonb
    WHERE NOT (light_colors ? 'field') OR NOT (dark_colors ? 'field')
    """)
  end

  def down do
    execute(
      "UPDATE theme_presets SET light_colors = light_colors - 'field' - 'field-content', " <>
        "dark_colors = dark_colors - 'field' - 'field-content'"
    )
  end
end

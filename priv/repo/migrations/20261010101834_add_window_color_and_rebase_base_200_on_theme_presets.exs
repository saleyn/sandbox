defmodule Air.Repo.Migrations.AddWindowColorAndRebaseBase200OnThemePresets do
  use Ecto.Migration

  # Air.ThemePreset.color_keys/0 grew a new "window"/"window-content" pair
  # (the main app-shell/canvas background — see --color-window in
  # assets/css/app.css) carved out of base-200's old dual role as BOTH the
  # window background AND the hover/secondary-fill color. Existing rows:
  #   1. Get "window"/"window-content" backfilled from their OWN existing
  #      base-200/base-content values, so whatever a preset's window
  #      looked like before this change keeps looking the same after it
  #      (window takes over base-200's old job, pixel for pixel).
  #   2. Get base-200 itself REPLACED with the new, visually-distinct
  #      hover/secondary-fill shade (gray-100 light / gray-600 dark) —
  #      since base-200 no longer means "window", it should mean the one
  #      thing it has left: a hover highlight that's actually visible
  #      against both the window AND the panel it sits near.
  def up do
    execute("""
    UPDATE theme_presets
    SET light_colors = (light_colors
          || jsonb_build_object('window', light_colors->'base-200', 'window-content', light_colors->'base-content'))
          || '{"base-200":"#f3f4f6"}'::jsonb,
        dark_colors = (dark_colors
          || jsonb_build_object('window', dark_colors->'base-200', 'window-content', dark_colors->'base-content'))
          || '{"base-200":"#4b5563"}'::jsonb
    WHERE NOT (light_colors ? 'window') OR NOT (dark_colors ? 'window')
    """)
  end

  def down do
    execute("""
    UPDATE theme_presets
    SET light_colors = (light_colors - 'window' - 'window-content') || jsonb_build_object('base-200', light_colors->'window'),
        dark_colors = (dark_colors - 'window' - 'window-content') || jsonb_build_object('base-200', dark_colors->'window')
    """)
  end
end

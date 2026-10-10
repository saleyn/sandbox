defmodule Air.Repo.Migrations.AddPanelTitleAndGhostColorsToThemePresets do
  use Ecto.Migration

  # Air.ThemePreset.color_keys/0 added "panel-title"/"panel-title-content"
  # (section/table header backgrounds — e.g. dag_list.ex's <thead>,
  # settings.ex's uppercase panel section labels — previously just
  # base-200/base-content at reduced opacity) and "ghost"/"ghost-content"
  # (the tinted "selected/active, but not a solid filled button" look —
  # e.g. "+ New theme" when nothing else is selected, the active sidebar
  # nav item — previously hardcoded to primary at a fixed 10% opacity).
  # Existing rows: backfill panel-title/panel-title-content from each row's
  # own existing base-200/base-content values, and ghost/ghost-content from
  # primary — exactly what each was hardcoded to before, so this preserves
  # current appearance exactly going forward.
  def up do
    execute("""
    UPDATE theme_presets
    SET light_colors = light_colors || jsonb_build_object(
          'panel-title', light_colors->'base-200',
          'panel-title-content', light_colors->'base-content',
          'ghost', light_colors->'primary',
          'ghost-content', light_colors->'primary'
        ),
        dark_colors = dark_colors || jsonb_build_object(
          'panel-title', dark_colors->'base-200',
          'panel-title-content', dark_colors->'base-content',
          'ghost', dark_colors->'primary',
          'ghost-content', dark_colors->'primary'
        )
    WHERE NOT (light_colors ? 'ghost') OR NOT (dark_colors ? 'ghost')
    """)
  end

  def down do
    execute("""
    UPDATE theme_presets
    SET light_colors = light_colors - 'panel-title' - 'panel-title-content' - 'ghost' - 'ghost-content',
        dark_colors = dark_colors - 'panel-title' - 'panel-title-content' - 'ghost' - 'ghost-content'
    """)
  end
end

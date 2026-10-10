defmodule Air.Repo.Migrations.BackfillStatusColorsOnThemePresets do
  use Ecto.Migration

  # Air.ThemePreset.color_keys/0 grew to include info/success/warning/error
  # (+content) alongside the original base/primary/secondary/accent/neutral
  # set. Existing rows' light_colors/dark_colors jsonb maps are missing
  # these new keys, which would fail ThemePreset.changeset/2's
  # validate_colors check the next time such a row is saved. Backfill with
  # the same oklch-derived hex values the "Default" system preset's
  # migration (20261010080028) used for its other colors, so every
  # existing row ends up with a complete, valid palette.
  def up do
    light_additions =
      ~s({"info":"#2a7eff","info-content":"#eff6ff",) <>
        ~s("success":"#00baa6","success-content":"#effcf9",) <>
        ~s("warning":"#df6f00","warning-content":"#fdf9e8",) <>
        ~s("error":"#ea003e","error-content":"#fceeef"})

    dark_additions =
      ~s({"info":"#0082ce","info-content":"#edf7fd",) <>
        ~s("success":"#009689","success-content":"#effcf9",) <>
        ~s("warning":"#df6f00","warning-content":"#fdf9e8",) <>
        ~s("error":"#ea003e","error-content":"#fceeef"})

    execute("""
    UPDATE theme_presets
    SET light_colors = light_colors || '#{light_additions}'::jsonb,
        dark_colors = dark_colors || '#{dark_additions}'::jsonb
    WHERE NOT (light_colors ? 'info') OR NOT (dark_colors ? 'info')
    """)
  end

  def down do
    keys = ~w(info info-content success success-content warning warning-content error error-content)

    for key <- keys do
      execute("UPDATE theme_presets SET light_colors = light_colors - '#{key}', dark_colors = dark_colors - '#{key}'")
    end
  end
end

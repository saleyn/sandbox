defmodule Air.Repo.Migrations.UpdateDefaultThemePresetToMatchAppChrome do
  use Ecto.Migration

  # The "Default" system preset was originally seeded from daisyUI's own
  # stock light/dark theme colors (oklch values from assets/css/app.css).
  # The app's actual chrome (sidebar, cards, buttons — see
  # lib/air_web/components/layouts.ex and friends) was always hand-styled
  # with plain Tailwind gray/blue/red classes that never matched those
  # oklch values. Now that the app's own components are being migrated to
  # read daisyUI's --color-* variables instead of hardcoded Tailwind
  # classes, "Default" needs to actually BE those Tailwind colors (so
  # switching to/saving over "Default" doesn't visibly change anything),
  # not daisyUI's stock palette.
  def up do
    light =
      ~s({"base-100":"#ffffff","base-200":"#f9fafb","base-300":"#e5e7eb","base-content":"#111827",) <>
        ~s("primary":"#2563eb","primary-content":"#ffffff","secondary":"#e5e7eb","secondary-content":"#374151",) <>
        ~s("accent":"#2563eb","accent-content":"#ffffff","neutral":"#374151","neutral-content":"#ffffff",) <>
        ~s("info":"#2563eb","info-content":"#ffffff","success":"#16a34a","success-content":"#ffffff",) <>
        ~s("warning":"#f59e0b","warning-content":"#78350f","error":"#dc2626","error-content":"#ffffff"})

    dark =
      ~s({"base-100":"#1f2937","base-200":"#111827","base-300":"#374151","base-content":"#f9fafb",) <>
        ~s("primary":"#2563eb","primary-content":"#ffffff","secondary":"#374151","secondary-content":"#d1d5db",) <>
        ~s("accent":"#3b82f6","accent-content":"#ffffff","neutral":"#4b5563","neutral-content":"#f9fafb",) <>
        ~s("info":"#3b82f6","info-content":"#ffffff","success":"#22c55e","success-content":"#052e16",) <>
        ~s("warning":"#f59e0b","warning-content":"#451a03","error":"#ef4444","error-content":"#ffffff"})

    execute("""
    UPDATE theme_presets
    SET light_colors = '#{light}'::jsonb,
        dark_colors = '#{dark}'::jsonb
    WHERE user_id = 'system' AND name = 'Default'
    """)
  end

  def down do
    light =
      ~s({"base-100":"#f8f8f8","base-200":"#f2f2f2","base-300":"#e4e4e7","base-content":"#18181b",) <>
        ~s("primary":"#ff6700","primary-content":"#fff7ed","secondary":"#6a7282","secondary-content":"#f7f8fa",) <>
        ~s("accent":"#000000","accent-content":"#ffffff","neutral":"#51515c","neutral-content":"#f8f8f8",) <>
        ~s("info":"#2a7eff","info-content":"#eff6ff","success":"#00baa6","success-content":"#effcf9",) <>
        ~s("warning":"#df6f00","warning-content":"#fdf9e8","error":"#ea003e","error-content":"#fceeef"})

    dark =
      ~s({"base-100":"#292f37","base-200":"#1e2329","base-300":"#13171c","base-content":"#ecf9ff",) <>
        ~s("primary":"#605dff","primary-content":"#edf1fe","secondary":"#605dff","secondary-content":"#edf1fe",) <>
        ~s("accent":"#8c4fff","accent-content":"#f2f0fc","neutral":"#314157","neutral-content":"#f7f9fa",) <>
        ~s("info":"#0082ce","info-content":"#edf7fd","success":"#009689","success-content":"#effcf9",) <>
        ~s("warning":"#df6f00","warning-content":"#fdf9e8","error":"#ea003e","error-content":"#fceeef"})

    execute("""
    UPDATE theme_presets
    SET light_colors = '#{light}'::jsonb,
        dark_colors = '#{dark}'::jsonb
    WHERE user_id = 'system' AND name = 'Default'
    """)
  end
end

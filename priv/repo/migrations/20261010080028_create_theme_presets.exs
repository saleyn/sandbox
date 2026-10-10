defmodule Air.Repo.Migrations.CreateThemePresets do
  use Ecto.Migration

  def change do
    create table(:theme_presets) do
      # No users table yet — a plain string keeps this column ready to
      # hold a real user identifier later without a type change. System
      # presets (ship-with-the-app, visible to everyone) use the
      # "system" sentinel rather than NULL so every preset query can
      # filter/order on this column uniformly.
      add :user_id, :string, default: "system", null: false
      add :name, :string, null: false
      add :is_system, :boolean, default: false, null: false
      add :light_colors, :map, null: false
      add :dark_colors, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:theme_presets, [:user_id, :name])
    create index(:theme_presets, [:user_id])

    # Seed one system preset mirroring the app's two built-in daisyUI
    # themes (assets/css/app.css), converted from oklch to hex, so the
    # Theme Editor tab always has at least one preset to show/clone from.
    light =
      ~s({"base-100":"#f8f8f8","base-200":"#f2f2f2","base-300":"#e4e4e7","base-content":"#18181b",) <>
        ~s("primary":"#ff6700","primary-content":"#fff7ed","secondary":"#6a7282","secondary-content":"#f7f8fa",) <>
        ~s("accent":"#000000","accent-content":"#ffffff","neutral":"#51515c","neutral-content":"#f8f8f8"})

    dark =
      ~s({"base-100":"#292f37","base-200":"#1e2329","base-300":"#13171c","base-content":"#ecf9ff",) <>
        ~s("primary":"#605dff","primary-content":"#edf1fe","secondary":"#605dff","secondary-content":"#edf1fe",) <>
        ~s("accent":"#8c4fff","accent-content":"#f2f0fc","neutral":"#314157","neutral-content":"#f7f9fa"})

    execute(
      "INSERT INTO theme_presets (user_id, name, is_system, light_colors, dark_colors, inserted_at, updated_at) " <>
        "VALUES ('system', 'Default', true, '#{light}'::jsonb, '#{dark}'::jsonb, NOW(), NOW())",
      "DELETE FROM theme_presets WHERE user_id = 'system' AND name = 'Default'"
    )
  end
end

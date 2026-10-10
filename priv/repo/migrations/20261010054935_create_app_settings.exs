defmodule Air.Repo.Migrations.CreateAppSettings do
  use Ecto.Migration

  def change do
    create table(:app_settings) do
      add :snap_to_grid, :boolean, default: false, null: false
      add :show_grid, :boolean, default: true, null: false
      add :line_shape, :string, default: "angled", null: false
      add :line_width, :integer, default: 2, null: false
      add :arrow_position, :string, default: "end", null: false
      add :layout_direction, :string, default: "horizontal", null: false

      timestamps(type: :utc_datetime)
    end

    # Single-row config table (no auth/per-user system yet — see
    # Air.AppSettingsQuery) — seed the one row here so get/0 never has to
    # special-case "no row exists yet".
    execute(
      "INSERT INTO app_settings (snap_to_grid, show_grid, line_shape, line_width, arrow_position, layout_direction, inserted_at, updated_at) VALUES (false, true, 'angled', 2, 'end', 'horizontal', NOW(), NOW())",
      "DELETE FROM app_settings"
    )
  end
end

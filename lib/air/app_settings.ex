defmodule Air.AppSettings do
  @moduledoc """
  Schema for app-wide editor default settings — a single row, no per-user
  scoping (there's no auth/accounts system yet). Controls what a freshly
  mounted DAG editor starts with (snap-to-grid, grid visibility, line
  style/width, arrow position, auto-layout direction) before the user
  changes anything for that session via the editor's own toolbar/context
  menu. See Air.AppSettingsQuery for the single-row get/update API.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "app_settings" do
    field :snap_to_grid, :boolean, default: false
    field :show_grid, :boolean, default: true
    field :line_shape, :string, default: "angled"
    field :line_width, :integer, default: 2
    field :arrow_position, :string, default: "end"
    field :layout_direction, :string, default: "horizontal"

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(app_settings, attrs) do
    app_settings
    |> cast(attrs, [
      :snap_to_grid,
      :show_grid,
      :line_shape,
      :line_width,
      :arrow_position,
      :layout_direction
    ])
    |> validate_inclusion(:line_shape, ~w(straight curved angled))
    |> validate_inclusion(:arrow_position, ~w(end none))
    |> validate_inclusion(:layout_direction, ~w(horizontal vertical))
    |> validate_inclusion(:line_width, [1, 2, 3, 4, 6])
  end
end

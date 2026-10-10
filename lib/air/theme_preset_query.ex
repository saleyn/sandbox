defmodule Air.ThemePresetQuery do
  @moduledoc """
  CRUD for theme_presets. Unlike Air.AppSettingsQuery (one singleton row),
  this is a genuinely multi-row table: many presets can exist per
  user_id, plus system presets (user_id "system") visible to everyone.
  """

  import Ecto.Query
  alias Air.{Repo, ThemePreset}

  @doc """
  Lists presets visible to `user_id`: that user's own presets plus every
  system preset, system presets first, then alphabetical by name.
  """
  def list_for_user(user_id) do
    system_id = ThemePreset.system_user_id()

    from(p in ThemePreset,
      where: p.user_id == ^user_id or p.user_id == ^system_id,
      order_by: [desc: p.is_system, asc: p.name]
    )
    |> Repo.all()
  end

  def get!(id), do: Repo.get!(ThemePreset, id)

  def create(attrs) do
    %ThemePreset{}
    |> ThemePreset.changeset(attrs)
    |> Repo.insert()
  end

  def update(%ThemePreset{} = preset, attrs) do
    preset
    |> ThemePreset.changeset(attrs)
    |> Repo.update()
  end

  def delete(%ThemePreset{} = preset), do: Repo.delete(preset)
end

defmodule Air.AppSettingsQuery do
  @moduledoc """
  Reads/writes the single app_settings row. The migration seeds exactly one
  row, but `get/0` also tolerates an empty table (e.g. a database restored
  from a backup taken before that row existed) by inserting the schema's
  own defaults on first read, rather than raising.
  """

  alias Air.{AppSettings, Repo}

  @doc """
  Returns the one %AppSettings{} row, creating it with default values if
  the table is somehow empty.
  """
  def get do
    case Repo.one(AppSettings) do
      nil -> Repo.insert!(%AppSettings{})
      settings -> settings
    end
  end

  @doc """
  Updates the single settings row. `attrs` keys may be atoms or strings.
  Returns `{:ok, %AppSettings{}}` or `{:error, changeset}`.
  """
  def update(attrs) do
    get()
    |> AppSettings.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns the current settings as the plain string-keyed map shape
  AirWeb.Pages.DagEditor expects for its `data-settings` payload (and as
  the fallback defaults for a freshly mounted editor).
  """
  def as_editor_defaults do
    settings = get()

    %{
      snap_to_grid: settings.snap_to_grid,
      show_grid: settings.show_grid,
      line_shape: settings.line_shape,
      line_width: settings.line_width,
      arrow_position: settings.arrow_position,
      layout_direction: settings.layout_direction
    }
  end
end

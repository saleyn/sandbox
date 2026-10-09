defmodule Air.DAG do
  @moduledoc """
  Schema for DAG (Directed Acyclic Graph) definitions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:dag_id, :string, autogenerate: false}
  schema "dag" do
    # Mandatory display name — distinct from the free-text description.
    field :title, :string
    field :description, :string
    field :owner, :string
    field :maintainers, {:array, :string}, default: []
    field :supporters, {:array, :string}, default: []
    field :labels, {:array, :string}, default: []
    # No auth/session system yet, so these stay nil until one exists.
    field :created_by, :string
    field :updated_by, :string
    field :is_paused, :boolean, default: false
    # Canvas positions/pan/zoom keyed by task_id — UI state only, not scheduling
    field :layout, :map, default: %{}
    field :source_code, :string
    field :source_language, :string, default: "python"

    has_many :runs, Air.DagRun, foreign_key: :dag_id, references: :dag_id
    has_many :tasks, Air.DagTask, foreign_key: :dag_id, references: :dag_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(dag, attrs) do
    dag
    |> cast(attrs, [
      :dag_id,
      :title,
      :description,
      :owner,
      :maintainers,
      :supporters,
      :labels,
      :created_by,
      :updated_by,
      :is_paused,
      :layout,
      :source_code,
      :source_language
    ])
    |> validate_required([:dag_id, :title])
    |> unique_constraint(:dag_id)
  end
end

defmodule Air.DAG do
  @moduledoc """
  Schema for DAG (Directed Acyclic Graph) definitions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:dag_id, :string, autogenerate: false}
  schema "dag" do
    field :description, :string
    field :owner, :string
    field :is_paused, :boolean, default: false

    has_many :runs, Air.DagRun, foreign_key: :dag_id, references: :dag_id
    has_many :tasks, Air.DagTask, foreign_key: :dag_id, references: :dag_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(dag, attrs) do
    dag
    |> cast(attrs, [:dag_id, :description, :owner, :is_paused])
    |> validate_required([:dag_id])
    |> unique_constraint(:dag_id)
  end
end

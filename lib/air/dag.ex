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
    # Soft-delete marker — set means deleted (hidden from all normal
    # queries); a background job hard-deletes rows 30 days after this is
    # set (see Air.DagRetentionJob). Deliberately NOT in changeset/2's cast
    # list below — set only via DagEditorQuery.delete_dag/1 /
    # restore_dag/1, never through the generic properties-editing form.
    field :deleted_at, :utc_datetime

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
    # dag_id is the primary key, not just a separately-indexed unique
    # column — Postgres reports a violation against the "dag_pkey"
    # constraint, not the "dag_dag_id_index" name unique_constraint/3
    # assumes by default from the field name. Without pointing at the
    # right name explicitly, a duplicate dag_id insert raises
    # Ecto.ConstraintError instead of returning {:error, changeset}.
    |> unique_constraint(:dag_id, name: :dag_pkey)
  end
end

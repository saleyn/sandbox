defmodule Air.DagTask do
  @moduledoc """
  Schema for DAG task definitions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "dag_task" do
    field :task_id, :string
    field :dag_id, :string
    field :task_type, :string
    field :downstream_list, {:array, :string}, default: []
    field :pool, :string, default: "default_pool"
    field :pool_slots, :integer, default: 1
    field :priority_weight, :integer, default: 1
    field :queue, :string, default: "default"
    field :max_tries, :integer, default: 0
    field :retries, :integer, default: 0

    belongs_to :dag, Air.DAG, foreign_key: :dag_id, references: :dag_id, define_field: false
    has_many :instances, Air.TaskInstance, foreign_key: :task_id, references: :task_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(dag_task, attrs) do
    dag_task
    |> cast(attrs, [
      :task_id,
      :dag_id,
      :task_type,
      :downstream_list,
      :pool,
      :pool_slots,
      :priority_weight,
      :queue,
      :max_tries,
      :retries
    ])
    |> validate_required([:task_id, :dag_id, :task_type])
    |> unique_constraint([:dag_id, :task_id], name: :dag_task_dag_id_task_id_index)
  end
end

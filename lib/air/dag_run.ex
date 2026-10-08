defmodule Air.DagRun do
  @moduledoc """
  Schema for DAG execution runs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:success, :failed, :running, :queued, :skipped]

  @primary_key {:run_id, :string, autogenerate: false}
  schema "dag_run" do
    field :dag_id, :string
    field :status, Ecto.Enum, values: @statuses
    field :start_time, :utc_datetime
    field :end_time, :utc_datetime
    field :duration_ms, :integer
    field :data_interval_start, :utc_datetime
    field :data_interval_end, :utc_datetime
    field :run_type, :string, default: "manual"
    field :notes, :string

    belongs_to :dag, Air.DAG, foreign_key: :dag_id, references: :dag_id, define_field: false
    has_many :task_instances, Air.TaskInstance, foreign_key: :run_id, references: :run_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(dag_run, attrs) do
    dag_run
    |> cast(attrs, [
      :run_id,
      :dag_id,
      :status,
      :start_time,
      :end_time,
      :duration_ms,
      :data_interval_start,
      :data_interval_end,
      :run_type,
      :notes
    ])
    |> validate_required([:run_id, :dag_id, :status, :start_time])
    |> unique_constraint(:run_id)
  end

  def statuses, do: @statuses
end

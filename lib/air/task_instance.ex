defmodule Air.TaskInstance do
  @moduledoc """
  Schema for task instances (actual executions of tasks within a DAG run).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:success, :failed, :upstream_failed, :running, :queued, :skipped, :waiting, :cancelled]

  schema "task_instance" do
    field :task_id, :string
    field :run_id, :string
    field :dag_id, :string
    field :status, Ecto.Enum, values: @statuses
    field :reason, :string
    field :start_time, :utc_datetime
    field :end_time, :utc_datetime
    field :duration_ms, :integer
    field :try_number, :integer, default: 1
    field :max_tries, :integer, default: 0
    field :hostname, :string
    field :logs, :string
    field :notes, :string

    belongs_to :run, Air.DagRun, foreign_key: :run_id, references: :run_id, define_field: false
    belongs_to :task, Air.DagTask, foreign_key: :task_id, references: :task_id, define_field: false
    belongs_to :dag, Air.DAG, foreign_key: :dag_id, references: :dag_id, define_field: false

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(task_instance, attrs) do
    task_instance
    |> cast(attrs, [
      :task_id,
      :run_id,
      :dag_id,
      :status,
      :reason,
      :start_time,
      :end_time,
      :duration_ms,
      :try_number,
      :max_tries,
      :hostname,
      :logs,
      :notes
    ])
    |> validate_required([:task_id, :run_id, :dag_id, :status])
    |> unique_constraint([:run_id, :task_id, :try_number],
      name: :task_instance_run_id_task_id_try_number_index
    )
  end

  def statuses, do: @statuses
end

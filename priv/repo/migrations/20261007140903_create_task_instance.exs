defmodule Air.Repo.Migrations.CreateTaskInstances do
  use Ecto.Migration

  def change do
    create table(:task_instance) do
      add :task_id, :string, null: false, references: :dag_task
      add :run_id, :string, null: false, references: :dag_run
      add :dag_id, :string, null: false, references: :dag
      add :status, :string, null: false
      add :start_time, :utc_datetime
      add :end_time, :utc_datetime
      add :duration_ms, :integer
      add :try_number, :integer, default: 1
      add :max_tries, :integer, default: 0
      add :hostname, :string
      add :logs, :text
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:task_instance, [:run_id, :task_id, :try_number],
      name: :task_instance_run_id_task_id_try_number_index
    )

    create index(:task_instance, [:dag_id])
    create index(:task_instance, [:run_id])
    create index(:task_instance, [:task_id])
    create index(:task_instance, [:status])
    create index(:task_instance, [:start_time])
  end
end

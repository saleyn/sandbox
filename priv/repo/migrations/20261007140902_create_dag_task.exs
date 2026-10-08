defmodule Air.Repo.Migrations.CreateDagTasks do
  use Ecto.Migration

  def change do
    create table(:dag_task) do
      add :task_id, :string, null: false
      add :dag_id, :string, null: false, references: :dag
      add :task_type, :string, null: false
      add :downstream_list, {:array, :string}, default: []
      add :pool, :string, default: "default_pool"
      add :pool_slots, :integer, default: 1
      add :priority_weight, :integer, default: 1
      add :queue, :string, default: "default"
      add :max_tries, :integer, default: 0
      add :retries, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:dag_task, [:dag_id, :task_id], name: :dag_task_dag_id_task_id_index)
    create index(:dag_task, [:dag_id])
    create index(:dag_task, [:task_id])
  end
end

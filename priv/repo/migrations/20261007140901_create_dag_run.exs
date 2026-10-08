defmodule Air.Repo.Migrations.CreateDagRuns do
  use Ecto.Migration

  def change do
    create table(:dag_run, primary_key: false) do
      add :run_id, :string, primary_key: true
      add :dag_id, :string, null: false, references: :dag
      add :status, :string, null: false
      add :start_time, :utc_datetime, null: false
      add :end_time, :utc_datetime
      add :duration_ms, :integer
      add :data_interval_start, :utc_datetime
      add :data_interval_end, :utc_datetime
      add :run_type, :string, default: "manual"
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:dag_run, [:run_id])
    create index(:dag_run, [:dag_id])
    create index(:dag_run, [:status])
    create index(:dag_run, [:start_time])
  end
end

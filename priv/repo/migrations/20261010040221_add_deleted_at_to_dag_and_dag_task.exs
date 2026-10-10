defmodule Air.Repo.Migrations.AddDeletedAtToDagAndDagTask do
  use Ecto.Migration

  def change do
    alter table(:dag) do
      add :deleted_at, :utc_datetime, comment: "Soft-delete marker; set = deleted. Purged 30 days after deletion by the background job."
    end

    alter table(:dag_task) do
      add :deleted_at, :utc_datetime, comment: "Soft-delete marker; set = deleted (cascades with its parent DAG's deletion)."
    end

    create index(:dag, [:deleted_at])
    create index(:dag_task, [:deleted_at])
  end
end

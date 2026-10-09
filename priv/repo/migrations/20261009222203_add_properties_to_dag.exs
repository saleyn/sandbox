defmodule Air.Repo.Migrations.AddPropertiesToDag do
  use Ecto.Migration

  def change do
    alter table(:dag) do
      add :title, :string, comment: "Mandatory display name, distinct from the free-text description"
      add :maintainers, {:array, :string}, default: [], comment: "Names/emails of people who maintain this DAG"
      add :supporters, {:array, :string}, default: [], comment: "Names/emails of people who support/use this DAG"
      add :labels, {:array, :string}, default: [], comment: "Free-form tags for categorizing/filtering DAGs"
      add :created_by, :string, comment: "No auth system yet — left null until one exists"
      add :updated_by, :string, comment: "No auth system yet — left null until one exists"
      add :source_code, :text, comment: "DAG-level source code, editable in the Source tab of DAG Properties"
      add :source_language, :string, default: "python"
    end

    execute(
      "UPDATE dag SET title = COALESCE(NULLIF(description, ''), dag_id), description = NULL",
      "SELECT 1"
    )
  end
end

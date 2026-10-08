defmodule Air.Repo.Migrations.CreateDags do
  use Ecto.Migration

  def change do
    create table(:dag, primary_key: false) do
      add :dag_id, :string, primary_key: true
      add :description, :text
      add :owner, :string
      add :is_paused, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:dag, [:dag_id])
  end
end

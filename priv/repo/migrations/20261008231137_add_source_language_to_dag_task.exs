defmodule Air.Repo.Migrations.AddSourceLanguageToDagTask do
  use Ecto.Migration

  def change do
    alter table(:dag_task) do
      add :source_language, :string,
        default: "python",
        comment: "Language of source_code: python, shell, javascript, or elixir"
    end
  end
end

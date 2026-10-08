defmodule Air.Repo.Migrations.AddReasonToTaskInstance do
  use Ecto.Migration

  def change do
    alter table(:task_instance) do
      add :reason, :string, null: true, comment: "Reason for task status (e.g., 'upstream_failed')"
    end
  end
end

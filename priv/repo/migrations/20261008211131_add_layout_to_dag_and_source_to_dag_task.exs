defmodule Air.Repo.Migrations.AddLayoutToDagAndSourceToDagTask do
  use Ecto.Migration

  def change do
    alter table(:dag) do
      add :layout, :map, default: %{}, comment: "Canvas positions/pan/zoom keyed by task_id"
    end

    alter table(:dag_task) do
      add :source_code, :text, comment: "Task's editable source code"
    end

    # Evolve downstream_list from {:array, :string} (plain task_id list)
    # to jsonb so each connection can carry metadata — currently just
    # data_size (XS/S/M/L/XL/XXL/XXXL), which determines where
    # intermediate data is stored (filesystem, S3, ObjectStore, etc.).
    #
    # Postgres doesn't allow subqueries in ALTER COLUMN TYPE ... USING,
    # so we add a new column, populate it, drop the old, and rename.
    alter table(:dag_task) do
      add :downstream_list_new, :jsonb, default: "[]"
    end

    flush()

    # Migrate existing data: ["task_b"] -> [{"task_id":"task_b","data_size":"M"}]
    execute(
      """
      UPDATE dag_task SET downstream_list_new = (
        SELECT coalesce(jsonb_agg(jsonb_build_object('task_id', elem, 'data_size', 'M')), '[]'::jsonb)
        FROM unnest(downstream_list) AS elem
      )
      """,
      "SELECT 1"
    )

    alter table(:dag_task) do
      remove :downstream_list
    end

    rename table(:dag_task), :downstream_list_new, to: :downstream_list
  end
end

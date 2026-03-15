defmodule Cortex.Store.Repo.Migrations.AddWorkspacePathToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :workspace_path, :string
    end
  end
end

defmodule Cortex.Repo.Migrations.AddModeToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :mode, :string, default: "orchestration"
    end
  end
end

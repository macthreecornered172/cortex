defmodule Cortex.Repo.Migrations.AddOutputKeyToTeamRuns do
  use Ecto.Migration

  def change do
    alter table(:team_runs) do
      add :output_key, :string
    end
  end
end

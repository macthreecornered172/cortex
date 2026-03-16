defmodule Cortex.Repo.Migrations.AddGossipRoundsToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :gossip_rounds_completed, :integer, default: 0
      add :gossip_rounds_total, :integer, default: 0
    end
  end
end

defmodule Cortex.Repo.Migrations.AddGates do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :gated_at_tier, :integer
    end

    create table(:gate_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
      add :tier, :integer, null: false
      add :decision, :string, null: false
      add :decided_by, :string
      add :notes, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:gate_decisions, [:run_id, :tier])
  end
end

defmodule Cortex.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  def change do
    create table(:runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :config_yaml, :text
      add :status, :string, null: false, default: "pending"
      add :mode, :string, default: "workflow"
      add :team_count, :integer, default: 0
      add :total_cost_usd, :float, default: 0.0
      add :total_input_tokens, :integer
      add :total_output_tokens, :integer
      add :total_cache_read_tokens, :integer
      add :total_cache_creation_tokens, :integer
      add :total_duration_ms, :integer
      add :workspace_path, :string
      add :gossip_rounds_completed, :integer, default: 0
      add :gossip_rounds_total, :integer, default: 0
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:runs, [:status])
    create index(:runs, [:inserted_at])
  end
end

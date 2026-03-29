defmodule Cortex.Store.Schemas.GateDecision do
  @moduledoc """
  Ecto schema for a gate decision in a human-in-the-loop workflow.

  Each row records a single gate event: when a tier boundary gate fires
  (decision = "pending"), when a human approves ("approved") or rejects
  ("rejected") it, who made the decision, and optional notes that get
  injected into downstream agent prompts.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Cortex.Store.Schemas.Run

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "gate_decisions" do
    field(:tier, :integer)
    field(:decision, :string, default: "pending")
    field(:decided_by, :string)
    field(:notes, :string)

    belongs_to(:run, Run)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(run_id tier decision)a
  @optional_fields ~w(decided_by notes)a

  @doc "Changeset for creating or updating a gate decision."
  def changeset(gate_decision, attrs) do
    gate_decision
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:decision, ~w(pending approved rejected))
    |> foreign_key_constraint(:run_id)
  end
end

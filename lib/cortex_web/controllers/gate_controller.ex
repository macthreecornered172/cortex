defmodule CortexWeb.GateController do
  @moduledoc """
  JSON API controller for gate operations on orchestration runs.

  Exposes:
    GET  /api/runs/:run_id/gates          — list gate decisions
    POST /api/runs/:run_id/gates/approve  — approve a gated run
    POST /api/runs/:run_id/gates/reject   — reject a gated run
  """
  use CortexWeb, :controller

  alias Cortex.Orchestration.Runner
  alias Cortex.Store

  require Logger

  @doc "List all gate decisions for a run."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"run_id" => run_id}) do
    decisions = Store.get_gate_decisions(run_id)
    json(conn, %{data: Enum.map(decisions, &serialize_decision/1)})
  end

  @doc """
  Approve a gated run and continue execution in the background.

  Body params:
    - decided_by (optional) — who approved
    - notes (optional) — notes injected into downstream agent prompts
  """
  @spec approve(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def approve(conn, %{"run_id" => run_id} = params) do
    opts = build_gate_opts(params)

    # approve_gate calls continue_run which blocks until the next gate or
    # completion. Run it async so the API returns immediately.
    Task.Supervisor.start_child(Cortex.TaskSupervisor, fn ->
      case Runner.approve_gate(run_id, opts) do
        {:ok, :noop} ->
          Logger.info("Gate approve noop for run #{run_id}")

        {:ok, result} ->
          Logger.info("Gate approved for run #{run_id}: #{inspect(result)}")

        {:error, reason} ->
          Logger.warning("Gate approve failed for run #{run_id}: #{inspect(reason)}")
      end
    end)

    json(conn, %{status: "approved", run_id: run_id})
  end

  @doc """
  Reject a gated run.

  Body params:
    - decided_by (optional) — who rejected
    - notes (optional) — reason for rejection
  """
  @spec reject(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reject(conn, %{"run_id" => run_id} = params) do
    opts = build_gate_opts(params)

    case Runner.reject_gate(run_id, opts) do
      {:ok, :noop} ->
        json(conn, %{status: "noop", message: "Run is not gated"})

      {:ok, :rejected} ->
        json(conn, %{status: "rejected", run_id: run_id})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", error: inspect(reason)})
    end
  end

  defp build_gate_opts(params) do
    [
      decided_by: params["decided_by"],
      notes: params["notes"]
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp serialize_decision(gd) do
    %{
      id: gd.id,
      run_id: gd.run_id,
      tier: gd.tier,
      decision: gd.decision,
      decided_by: gd.decided_by,
      notes: gd.notes,
      inserted_at: gd.inserted_at,
      updated_at: gd.updated_at
    }
  end
end

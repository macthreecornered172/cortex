defmodule Cortex.Orchestration.TeamResult do
  @moduledoc """
  Result struct captured from a completed `claude -p` spawner process.

  Every spawner invocation produces a `TeamResult` regardless of outcome.
  The `:status` field indicates whether the run succeeded, errored, or
  timed out, and the remaining fields carry the details extracted from
  the NDJSON stream-json output.

  ## Fields

    - `team` — the team name this result belongs to (required)
    - `status` — outcome of the run: `:success`, `:error`, or `:timeout` (required)
    - `result` — the result text from the final `"type": "result"` NDJSON line
    - `cost_usd` — total API cost in USD
    - `num_turns` — number of conversation turns consumed
    - `duration_ms` — wall-clock duration in milliseconds
    - `session_id` — the Claude session identifier from the `"type": "system"` init line

  """

  @enforce_keys [:team, :status]
  defstruct [:team, :status, :result, :cost_usd, :num_turns, :duration_ms, :session_id]

  @type status :: :success | :error | :timeout

  @type t :: %__MODULE__{
          team: String.t(),
          status: status(),
          result: String.t() | nil,
          cost_usd: float() | nil,
          num_turns: non_neg_integer() | nil,
          duration_ms: non_neg_integer() | nil,
          session_id: String.t() | nil
        }
end

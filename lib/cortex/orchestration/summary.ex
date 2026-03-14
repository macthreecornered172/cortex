defmodule Cortex.Orchestration.Summary do
  @moduledoc """
  Formats orchestration run results into a human-readable summary table.

  Takes a `State` struct (with per-team statuses, costs, and durations) and
  produces a Unicode box-drawing table showing the outcome of each team,
  along with totals.

  ## Example Output

      =============================================
        Cortex: my-project -- Complete
      =============================================
        Team        | Status  | Cost   | Duration
        ------------+---------+--------+----------
        backend     | done    | $1.20  | 4m 12s
        frontend    | done    | $0.85  | 3m 05s
        ------------+---------+--------+----------
        Total       |         | $2.05  | 7m 17s

  """

  alias Cortex.Orchestration.State

  @doc """
  Formats an orchestration `State` into a summary string.

  Iterates through all teams in the state, builds a table with status,
  cost, and duration columns, and appends a totals row.

  ## Parameters

    - `state` -- a `%State{}` struct with populated team entries

  ## Returns

  A multi-line string suitable for printing to the terminal.
  """
  @spec format(State.t()) :: String.t()
  def format(%State{} = state) do
    team_names = state.teams |> Map.keys() |> Enum.sort()

    total_cost =
      state.teams
      |> Map.values()
      |> Enum.map(fn ts -> ts.cost_usd || 0.0 end)
      |> Enum.sum()

    total_duration =
      state.teams
      |> Map.values()
      |> Enum.map(fn ts -> ts.duration_ms || 0 end)
      |> Enum.sum()

    overall_status = compute_overall_status(state)

    rows =
      Enum.map(team_names, fn name ->
        ts = Map.fetch!(state.teams, name)

        {name, ts.status || "pending", format_cost(ts.cost_usd), format_duration(ts.duration_ms)}
      end)

    # Compute column widths
    name_width = max_width(rows, 0, "Team", 12)
    status_width = max_width(rows, 1, "Status", 7)
    cost_width = max_width(rows, 2, "Cost", 6)
    duration_width = max_width(rows, 3, "Duration", 8)

    header_line =
      "  #{pad("Team", name_width)} | #{pad("Status", status_width)} | #{pad("Cost", cost_width)} | #{pad("Duration", duration_width)}"

    separator =
      "  #{String.duplicate("-", name_width)}-+-#{String.duplicate("-", status_width)}-+-#{String.duplicate("-", cost_width)}-+-#{String.duplicate("-", duration_width)}"

    title = "  Cortex: #{state.project} -- #{overall_status}"
    banner_width = max(String.length(title) + 4, String.length(header_line) + 2)
    banner = String.duplicate("=", banner_width)

    data_rows =
      Enum.map(rows, fn {name, status, cost, duration} ->
        "  #{pad(name, name_width)} | #{pad(status, status_width)} | #{pad(cost, cost_width)} | #{pad(duration, duration_width)}"
      end)

    total_row =
      "  #{pad("Total", name_width)} | #{pad("", status_width)} | #{pad(format_cost(total_cost), cost_width)} | #{pad(format_duration(total_duration), duration_width)}"

    lines =
      [banner, title, banner, header_line, separator] ++
        data_rows ++
        [separator, total_row]

    Enum.join(lines, "\n")
  end

  @doc """
  Formats a duration in milliseconds to a human-readable string.

  Returns strings like `"0s"`, `"45s"`, `"3m 05s"`, `"1h 23m 45s"`.

  ## Parameters

    - `nil` -- returns `"--"`
    - `ms` -- non-negative integer of milliseconds

  ## Examples

      iex> Cortex.Orchestration.Summary.format_duration(0)
      "0s"

      iex> Cortex.Orchestration.Summary.format_duration(45_000)
      "45s"

      iex> Cortex.Orchestration.Summary.format_duration(252_000)
      "4m 12s"

      iex> Cortex.Orchestration.Summary.format_duration(5_025_000)
      "1h 23m 45s"

  """
  @spec format_duration(non_neg_integer() | nil) :: String.t()
  def format_duration(nil), do: "--"
  def format_duration(0), do: "0s"

  def format_duration(ms) when is_integer(ms) and ms > 0 do
    total_seconds = div(ms, 1_000)
    hours = div(total_seconds, 3_600)
    remaining = rem(total_seconds, 3_600)
    minutes = div(remaining, 60)
    seconds = rem(remaining, 60)

    cond do
      hours > 0 ->
        "#{hours}h #{minutes}m #{pad_num(seconds)}s"

      minutes > 0 ->
        "#{minutes}m #{pad_num(seconds)}s"

      true ->
        "#{seconds}s"
    end
  end

  @doc """
  Formats a cost value in USD.

  ## Parameters

    - `nil` -- returns `"--"`
    - `cost` -- a float or integer cost in USD

  ## Examples

      iex> Cortex.Orchestration.Summary.format_cost(1.5)
      "$1.50"

      iex> Cortex.Orchestration.Summary.format_cost(0.0)
      "$0.00"

  """
  @spec format_cost(number() | nil) :: String.t()
  def format_cost(nil), do: "--"

  def format_cost(cost) when is_number(cost),
    do: "$#{:erlang.float_to_binary(cost / 1, decimals: 2)}"

  # -- Private -----------------------------------------------------------------

  defp compute_overall_status(%State{teams: teams}) when map_size(teams) == 0, do: "Empty"

  defp compute_overall_status(%State{teams: teams}) do
    statuses = teams |> Map.values() |> Enum.map(& &1.status)

    cond do
      Enum.any?(statuses, &(&1 == "failed")) -> "Failed"
      Enum.all?(statuses, &(&1 == "done")) -> "Complete"
      Enum.any?(statuses, &(&1 == "running")) -> "Running"
      true -> "Pending"
    end
  end

  defp pad(text, width) when is_binary(text) do
    String.pad_trailing(text, width)
  end

  defp pad_num(n) when n < 10, do: "0#{n}"
  defp pad_num(n), do: "#{n}"

  defp max_width(rows, index, header, minimum) do
    row_max =
      rows
      |> Enum.map(fn row -> row |> elem(index) |> String.length() end)
      |> Enum.max(fn -> 0 end)

    max(max(row_max, String.length(header)), minimum)
  end
end

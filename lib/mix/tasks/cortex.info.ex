defmodule Mix.Tasks.Cortex.Info do
  @shortdoc "Show Cortex project and environment info"

  @moduledoc """
  Prints Cortex version, Elixir/OTP versions, and basic system info.
  Useful for quick diagnostics and issue reports.

  ## Usage

      mix cortex.info

  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    cortex_version = Application.spec(:cortex, :vsn) |> to_string()
    elixir_version = System.version()
    otp_release = :erlang.system_info(:otp_release) |> to_string()

    lines = [
      "",
      "Cortex #{cortex_version}",
      "",
      "  Elixir:       #{elixir_version}",
      "  OTP:          #{otp_release}",
      "  Mix env:      #{Mix.env()}",
      "  Project dir:  #{File.cwd!()}",
      ""
    ]

    Mix.shell().info(Enum.join(lines, "\n"))
  end
end

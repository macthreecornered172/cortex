defmodule Cortex.TestTools.Echo do
  @moduledoc "Test tool that returns args as-is."
  @behaviour Cortex.Tool.Behaviour

  @impl true
  def name, do: "echo"

  @impl true
  def description, do: "Returns the arguments map as-is"

  @impl true
  def schema, do: %{"type" => "object"}

  @impl true
  def execute(args), do: {:ok, args}
end

defmodule Cortex.TestTools.Slow do
  @moduledoc "Test tool that sleeps for a configurable duration."
  @behaviour Cortex.Tool.Behaviour

  @impl true
  def name, do: "slow"

  @impl true
  def description, do: "Sleeps for sleep_ms milliseconds then returns :done"

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "sleep_ms" => %{"type" => "integer"}
      },
      "required" => ["sleep_ms"]
    }
  end

  @impl true
  def execute(%{"sleep_ms" => ms}) do
    Process.sleep(ms)
    {:ok, :done}
  end
end

defmodule Cortex.TestTools.Crasher do
  @moduledoc "Test tool that raises a RuntimeError."
  @behaviour Cortex.Tool.Behaviour

  @impl true
  def name, do: "crasher"

  @impl true
  def description, do: "Always raises a RuntimeError"

  @impl true
  def schema, do: %{"type" => "object"}

  @impl true
  def execute(_args), do: raise("deliberate crash")
end

defmodule Cortex.TestTools.Killer do
  @moduledoc "Test tool that kills its own process with :kill signal."
  @behaviour Cortex.Tool.Behaviour

  @impl true
  def name, do: "killer"

  @impl true
  def description, do: "Kills its own process with Process.exit(self(), :kill)"

  @impl true
  def schema, do: %{"type" => "object"}

  @impl true
  def execute(_args) do
    Process.exit(self(), :kill)
    # This line is never reached
    {:ok, :unreachable}
  end
end

defmodule Cortex.TestTools.BadReturn do
  @moduledoc "Test tool that returns an invalid (non-tuple) value."
  @behaviour Cortex.Tool.Behaviour

  @impl true
  def name, do: "bad_return"

  @impl true
  def description, do: "Returns an invalid non-tuple value"

  @impl true
  def schema, do: %{"type" => "object"}

  @impl true
  def execute(_args), do: :not_a_tuple
end

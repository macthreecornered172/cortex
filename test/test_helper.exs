ExUnit.start(exclude: [:pending, :integration])
Ecto.Adapters.SQL.Sandbox.mode(Cortex.Repo, :manual)

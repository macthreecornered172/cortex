defmodule Cortex.Test.Sense do
  @moduledoc """
  Semantic assertion helpers for verifying agent output "makes sense"
  in context.

  `assert_sense/2` checks that a text contains concepts related to
  expected keywords/phrases — more flexible than exact string matching,
  but deterministic (no LLM calls in tests).

  `refute_sense/2` is the inverse: asserts that a text does NOT contain
  any of the given concepts.
  """

  import ExUnit.Assertions

  @doc """
  Asserts that `text` semantically contains the given concept.

  `concept` can be:
    - A string — checks case-insensitive substring match
    - A regex — checks regex match
    - A list of strings/regexes — asserts ALL are present (AND)
    - A keyword list with `:any` — asserts at least one is present (OR)

  ## Examples

      assert_sense(output, "REST API")
      assert_sense(output, ~r/rest|restful/i)
      assert_sense(output, ["REST", "endpoints", "JSON"])
      assert_sense(output, any: ["REST", "GraphQL"])

  """
  def assert_sense(text, concept) when is_binary(concept) do
    downcased = String.downcase(text)
    needle = String.downcase(concept)

    assert String.contains?(downcased, needle),
           "Expected text to contain concept #{inspect(concept)}, but it didn't.\n\nText:\n#{truncate(text)}"
  end

  def assert_sense(text, %Regex{} = pattern) do
    assert Regex.match?(pattern, text),
           "Expected text to match #{inspect(pattern)}, but it didn't.\n\nText:\n#{truncate(text)}"
  end

  def assert_sense(text, concepts) when is_list(concepts) do
    case Keyword.get(concepts, :any) do
      nil ->
        # AND — all must match
        Enum.each(concepts, &assert_sense(text, &1))

      alternatives ->
        # OR — at least one must match
        matched =
          Enum.any?(alternatives, fn concept ->
            try do
              assert_sense(text, concept)
              true
            rescue
              ExUnit.AssertionError -> false
            end
          end)

        assert matched,
               "Expected text to contain at least one of #{inspect(alternatives)}, but none matched.\n\nText:\n#{truncate(text)}"
    end
  end

  @doc """
  Asserts that `text` does NOT contain the given concept.

  Same argument shapes as `assert_sense/2`.
  """
  def refute_sense(text, concept) when is_binary(concept) do
    downcased = String.downcase(text)
    needle = String.downcase(concept)

    refute String.contains?(downcased, needle),
           "Expected text NOT to contain concept #{inspect(concept)}, but it did.\n\nText:\n#{truncate(text)}"
  end

  def refute_sense(text, %Regex{} = pattern) do
    refute Regex.match?(pattern, text),
           "Expected text NOT to match #{inspect(pattern)}, but it did.\n\nText:\n#{truncate(text)}"
  end

  def refute_sense(text, concepts) when is_list(concepts) do
    Enum.each(concepts, &refute_sense(text, &1))
  end

  defp truncate(text) when byte_size(text) > 500 do
    String.slice(text, 0, 500) <> "... (truncated)"
  end

  defp truncate(text), do: text
end

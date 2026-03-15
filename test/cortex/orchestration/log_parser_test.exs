defmodule Cortex.Orchestration.LogParserTest do
  use ExUnit.Case, async: true

  alias Cortex.Orchestration.LogParser

  describe "parse_content/1" do
    test "parses system init line" do
      content =
        ~s|{"type":"system","subtype":"init","session_id":"abc-123","tools":["Read","Write"]}|

      report = LogParser.parse_content(content)

      assert report.session_id == "abc-123"
      assert report.line_count == 1
      assert [entry] = report.entries
      assert entry.type == :session_start
      assert entry.detail =~ "abc-123"
    end

    test "parses assistant with tool_use" do
      content =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "model" => "claude-sonnet-4-6",
            "content" => [
              %{
                "type" => "tool_use",
                "name" => "Read",
                "input" => %{"file_path" => "/tmp/foo/bar/baz.txt"}
              }
            ],
            "stop_reason" => nil,
            "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
          }
        })

      report = LogParser.parse_content(content)

      assert report.model == "claude-sonnet-4-6"
      assert report.total_input_tokens == 100
      assert report.total_output_tokens == 50

      tool_entry = Enum.find(report.entries, &(&1.type == :tool_use))
      assert tool_entry
      assert tool_entry.tools == ["Read"]
      assert tool_entry.detail =~ "baz.txt"
    end

    test "parses assistant with text" do
      content =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{"type" => "text", "text" => "Let me read the files now."}
            ],
            "stop_reason" => nil
          }
        })

      report = LogParser.parse_content(content)

      text_entry = Enum.find(report.entries, &(&1.type == :text))
      assert text_entry
      assert text_entry.detail == "Let me read the files now."
    end

    test "parses assistant with thinking" do
      content =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{"type" => "thinking", "thinking" => "I need to check the database first."}
            ],
            "stop_reason" => nil
          }
        })

      report = LogParser.parse_content(content)

      thinking_entry = Enum.find(report.entries, &(&1.type == :thinking))
      assert thinking_entry
      assert thinking_entry.detail =~ "check the database"
    end

    test "parses user tool_result" do
      content =
        Jason.encode!(%{
          "type" => "user",
          "message" => %{
            "role" => "user",
            "content" => [
              %{
                "tool_use_id" => "tool_123",
                "type" => "tool_result",
                "content" => "file contents here",
                "is_error" => false
              }
            ]
          }
        })

      report = LogParser.parse_content(content)

      result_entry = Enum.find(report.entries, &(&1.type == :tool_result))
      assert result_entry
      assert result_entry.detail =~ "file contents"
    end

    test "parses user tool_result with error" do
      content =
        Jason.encode!(%{
          "type" => "user",
          "message" => %{
            "role" => "user",
            "content" => [
              %{
                "tool_use_id" => "tool_456",
                "type" => "tool_result",
                "content" => "Permission denied",
                "is_error" => true
              }
            ]
          }
        })

      report = LogParser.parse_content(content)

      error_entry = Enum.find(report.entries, &(&1.type == :tool_error))
      assert error_entry
      assert error_entry.detail =~ "Permission denied"
    end

    test "parses result line" do
      content =
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "success",
          "result" => "All tasks completed successfully.",
          "total_cost_usd" => 0.1234,
          "session_id" => "sess-456",
          "usage" => %{"input_tokens" => 500, "output_tokens" => 200}
        })

      report = LogParser.parse_content(content)

      assert report.has_result == true
      assert report.exit_subtype == "success"
      assert report.result_text =~ "All tasks completed"
      assert report.cost_usd == 0.1234
      assert report.session_id == "sess-456"
      assert report.diagnosis == :completed
    end

    test "diagnoses empty log" do
      report = LogParser.parse_content("")

      assert report.diagnosis == :empty_log
      assert report.entries == []
    end

    test "diagnoses log without session init" do
      content =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [%{"type" => "text", "text" => "hello"}],
            "stop_reason" => nil
          }
        })

      report = LogParser.parse_content(content)

      assert report.session_id == nil
      assert report.diagnosis == :no_session
    end

    test "diagnoses died during tool" do
      lines = [
        Jason.encode!(%{
          "type" => "system",
          "subtype" => "init",
          "session_id" => "s1"
        }),
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "name" => "Bash",
                "input" => %{"command" => "mkdir -p /tmp/foo"}
              }
            ],
            "stop_reason" => nil
          }
        }),
        Jason.encode!(%{
          "type" => "user",
          "message" => %{
            "role" => "user",
            "content" => [
              %{
                "tool_use_id" => "t1",
                "type" => "tool_result",
                "content" => "",
                "is_error" => false
              }
            ]
          }
        })
      ]

      report = LogParser.parse_content(Enum.join(lines, "\n"))

      assert report.session_id == "s1"
      assert report.has_result == false
      assert report.diagnosis == :died_after_tool_result
      assert report.diagnosis_detail =~ "died before next response"
    end

    test "diagnoses max turns" do
      content =
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "error_max_turns",
          "result" => "Max turns reached",
          "usage" => %{}
        })

      report = LogParser.parse_content(content)

      assert report.diagnosis == :max_turns
    end

    test "full session with multiple lines" do
      lines = [
        Jason.encode!(%{"type" => "system", "subtype" => "init", "session_id" => "full-sess"}),
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [%{"type" => "thinking", "thinking" => "Let me plan"}],
            "stop_reason" => nil,
            "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
          }
        }),
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "name" => "Read",
                "input" => %{"file_path" => "/tmp/test.txt"}
              }
            ],
            "stop_reason" => nil,
            "usage" => %{"input_tokens" => 20, "output_tokens" => 10}
          }
        }),
        Jason.encode!(%{
          "type" => "user",
          "message" => %{
            "content" => [
              %{
                "tool_use_id" => "t1",
                "type" => "tool_result",
                "content" => "file data",
                "is_error" => false
              }
            ]
          }
        }),
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "success",
          "result" => "Done!",
          "total_cost_usd" => 0.05,
          "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
        })
      ]

      report = LogParser.parse_content(Enum.join(lines, "\n"))

      assert report.session_id == "full-sess"
      assert report.has_result == true
      assert report.diagnosis == :completed
      assert report.cost_usd == 0.05
      assert report.total_input_tokens == 130
      assert report.total_output_tokens == 65
      assert report.line_count == 5
      assert length(report.entries) >= 4
    end

    test "summarizes Bash tool input with description" do
      content =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "name" => "Bash",
                "input" => %{
                  "command" => "mkdir -p /tmp/foo",
                  "description" => "Create output directory"
                }
              }
            ],
            "stop_reason" => nil
          }
        })

      report = LogParser.parse_content(content)

      tool_entry = Enum.find(report.entries, &(&1.type == :tool_use))
      assert tool_entry.detail =~ "Create output directory"
    end

    test "handles non-JSON lines gracefully" do
      content =
        "not json at all\n{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s1\"}"

      report = LogParser.parse_content(content)

      assert report.session_id == "s1"
      parse_error = Enum.find(report.entries, &(&1.type == :parse_error))
      assert parse_error
    end
  end

  describe "parse/1" do
    test "returns error for missing file" do
      assert {:error, :enoent} =
               LogParser.parse("/tmp/nonexistent_#{System.unique_integer()}.log")
    end

    test "parses actual file" do
      path = Path.join(System.tmp_dir!(), "log_parser_test_#{System.unique_integer()}.log")

      content =
        [
          Jason.encode!(%{"type" => "system", "subtype" => "init", "session_id" => "file-test"}),
          Jason.encode!(%{
            "type" => "result",
            "subtype" => "success",
            "result" => "ok",
            "usage" => %{}
          })
        ]
        |> Enum.join("\n")

      File.write!(path, content)

      assert {:ok, report} = LogParser.parse(path)
      assert report.session_id == "file-test"
      assert report.diagnosis == :completed

      File.rm!(path)
    end
  end
end

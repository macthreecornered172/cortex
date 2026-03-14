defmodule Cortex.EventsTest do
  use ExUnit.Case, async: true

  alias Cortex.Events

  describe "subscribe/0 and broadcast/2" do
    test "subscriber receives broadcast messages" do
      :ok = Events.subscribe()

      :ok = Events.broadcast(:test_event, %{key: "value"})

      assert_receive %{type: :test_event, payload: %{key: "value"}, timestamp: %DateTime{}}
    end

    test "broadcast message has the correct shape" do
      :ok = Events.subscribe()

      :ok = Events.broadcast(:agent_started, %{agent_id: "abc-123"})

      assert_receive message
      assert %{type: :agent_started, payload: payload, timestamp: timestamp} = message
      assert %{agent_id: "abc-123"} = payload
      assert %DateTime{} = timestamp
    end

    test "broadcast with default empty payload" do
      :ok = Events.subscribe()

      :ok = Events.broadcast(:ping)

      assert_receive %{type: :ping, payload: %{}, timestamp: %DateTime{}}
    end

    test "multiple events are received in order" do
      :ok = Events.subscribe()

      :ok = Events.broadcast(:event_1, %{n: 1})
      :ok = Events.broadcast(:event_2, %{n: 2})
      :ok = Events.broadcast(:event_3, %{n: 3})

      assert_receive %{type: :event_1, payload: %{n: 1}}
      assert_receive %{type: :event_2, payload: %{n: 2}}
      assert_receive %{type: :event_3, payload: %{n: 3}}
    end

    test "non-subscriber does not receive broadcast messages" do
      # Do NOT call subscribe here
      :ok = Events.broadcast(:secret_event, %{data: "hidden"})

      refute_receive %{type: :secret_event}, 50
    end

    test "timestamp is a UTC DateTime close to now" do
      :ok = Events.subscribe()
      before = DateTime.utc_now()

      :ok = Events.broadcast(:timed_event, %{})

      assert_receive %{type: :timed_event, timestamp: timestamp}
      after_time = DateTime.utc_now()

      assert DateTime.compare(timestamp, before) in [:gt, :eq]
      assert DateTime.compare(timestamp, after_time) in [:lt, :eq]
    end
  end

  describe "topic/0" do
    test "returns the event topic string" do
      assert Events.topic() == "cortex:events"
    end
  end
end

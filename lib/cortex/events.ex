defmodule Cortex.Events do
  @moduledoc """
  PubSub helper for broadcasting and subscribing to Cortex events.

  All events are published on the `"cortex:events"` topic using Phoenix.PubSub.
  Events are ephemeral — there is no persistence or replay in Phase 1.

  ## Event shape

  Each broadcast message is a map with three keys:

      %{
        type: atom(),        # e.g. :agent_started, :agent_stopped
        payload: map(),      # arbitrary data relevant to the event
        timestamp: DateTime  # UTC timestamp of when the event was emitted
      }

  ## Usage

      # Subscribe the current process to all events:
      Cortex.Events.subscribe()

      # Broadcast an event:
      Cortex.Events.broadcast(:agent_started, %{agent_id: "abc-123"})

      # Receive in a GenServer:
      def handle_info(%{type: :agent_started, payload: payload}, state) do
        # ...
      end
  """

  @pubsub Cortex.PubSub
  @topic "cortex:events"

  @type event_type :: atom()

  @doc """
  Subscribes the calling process to the `"cortex:events"` PubSub topic.

  The process will receive all events broadcast via `broadcast/2` as
  messages in its mailbox.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc """
  Broadcasts an event to all subscribers on the `"cortex:events"` topic.

  The broadcast message is a map with `:type`, `:payload`, and `:timestamp` keys.
  Returns `:ok` on success.
  """
  @spec broadcast(event_type(), map()) :: :ok | {:error, term()}
  def broadcast(type, payload \\ %{}) when is_atom(type) and is_map(payload) do
    message = %{
      type: type,
      payload: payload,
      timestamp: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(@pubsub, @topic, message)
  end

  @doc """
  Returns the PubSub topic string used for all Cortex events.
  """
  @spec topic() :: String.t()
  def topic, do: @topic
end

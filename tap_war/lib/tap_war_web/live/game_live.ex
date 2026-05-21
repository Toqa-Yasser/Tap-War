defmodule TapWarWeb.GameLive do
  @moduledoc """
  Per-player LiveView.

  Bug 1 fix — per-player ready system
  ────────────────────────────────────
  The old "Start Game" button was a global cast: one player pressed it and
  everyone was pulled into the game regardless of their state.  It is replaced
  by a per-player "Ready / Cancel" toggle.  The GameServer checks after every
  toggle: if all connected players (≥ 2) are ready it starts the countdown.
  Players who have not set their name or have not clicked Ready are simply not
  counted as ready, so they can never be dragged into a game they didn't agree
  to start.

  Bug 2 fix — no rejoin needed after reset
  ─────────────────────────────────────────
  Previously the server called fresh_state() on reset, wiping the players map.
  Now it keeps players and just zeros their taps/ready.  The LiveView processes
  are still subscribed to PubSub and receive the new :waiting broadcast with
  themselves already in the players map.  No extra join call is required.
  """

  use TapWarWeb, :live_view

  alias TapWar.GameServer
  alias Phoenix.PubSub

  @pubsub TapWar.PubSub
  @topic "game"

  # ── Mount ─────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    player_id = generate_id()

    if connected?(socket) do
      PubSub.subscribe(@pubsub, @topic)
      # Generate the name once so the lobby and the input field always match.
      name = default_name()
      {:ok, game_state} = GameServer.join(player_id, name)

      socket =
        socket
        |> assign(:player_id, player_id)
        |> assign_game(game_state)
        |> assign(:name_input, name)
        |> assign(:name_set, false)

      {:ok, socket}
    else
      socket =
        socket
        |> assign(:player_id, player_id)
        |> assign(:phase, :waiting)
        |> assign(:players, %{})
        |> assign(:countdown, nil)
        |> assign(:game_start_ts, nil)
        |> assign(:game_duration_ms, 15_000)
        |> assign(:name_input, "")
        |> assign(:name_set, false)

      {:ok, socket}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    GameServer.leave(socket.assigns.player_id)
    :ok
  end

  # ── Events ────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("tap", _params, socket) do
    GameServer.tap(socket.assigns.player_id)
    {:noreply, socket}
  end

  # Each player toggles their own ready flag independently.
  # The server starts the countdown when ALL players are ready.
  def handle_event("toggle_ready", _params, socket) do
    GameServer.toggle_ready(socket.assigns.player_id)
    {:noreply, socket}
  end

  def handle_event("set_name", %{"name" => name}, socket) do
    trimmed = String.trim(name)

    if trimmed != "" do
      # Use rename instead of leave+join so we don't lose the ready flag
      # and don't briefly remove the player from the lobby.
      GameServer.rename(socket.assigns.player_id, trimmed)

      socket =
        socket
        |> assign(:name_input, trimmed)
        |> assign(:name_set, true)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # ── PubSub handler ────────────────────────────────────────────────────────

  @impl true
  def handle_info({:game_update, game_state}, socket) do
    socket = assign_game(socket, game_state)

    socket =
      if game_state.phase == :playing do
        push_event(socket, "game_started", %{
          start_ts: game_state.game_start_ts,
          duration_ms: game_state.game_duration_ms
        })
      else
        socket
      end

    {:noreply, socket}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp assign_game(socket, game_state) do
    socket
    |> assign(:phase, game_state.phase)
    |> assign(:players, game_state.players)
    |> assign(:countdown, game_state.countdown)
    |> assign(:game_start_ts, game_state.game_start_ts)
    |> assign(:game_duration_ms, game_state.game_duration_ms)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp default_name, do: "Player #{:rand.uniform(9999)}"

  # ── Template helpers ──────────────────────────────────────────────────────

  def sorted_players(players) do
    players |> Map.values() |> Enum.sort_by(& &1.taps, :desc)
  end

  def winner(players) do
    case sorted_players(players) do
      [] -> nil
      [top | _] -> top
    end
  end

  def my_taps(players, player_id) do
    case Map.get(players, player_id) do
      nil -> 0
      p -> p.taps
    end
  end

  def my_ready?(players, player_id) do
    case Map.get(players, player_id) do
      nil -> false
      p -> p.ready
    end
  end

  def ready_count(players) do
    players |> Map.values() |> Enum.count(& &1.ready)
  end

  # Returns :won, :lost, or :tied for the given player_id.
  def my_result(players, player_id) do
    case Map.get(players, player_id) do
      nil -> :lost
      me ->
        top_taps = players |> Map.values() |> Enum.map(& &1.taps) |> Enum.max(fn -> 0 end)
        winners = players |> Map.values() |> Enum.filter(&(&1.taps == top_taps))
        cond do
          length(winners) > 1 and me.taps == top_taps -> :tied
          me.taps == top_taps -> :won
          true -> :lost
        end
    end
  end
end

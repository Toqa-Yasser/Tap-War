defmodule TapWar.GameServer do
  @moduledoc """
  Singleton GenServer that owns all authoritative game state.

  State machine
  ─────────────
    :waiting   – lobby; players join, set names, and toggle "ready"
    :countdown – 3-second "get ready" phase; tapping disabled
    :playing   – 15-second sprint; taps are accepted
    :finished  – results shown for 10 s, then back to :waiting

  Start condition (Bug 1 fix)
  ───────────────────────────
  The game no longer starts when a single player presses a button.
  Instead, each player independently toggles their own ready flag.
  The countdown begins automatically only when:
    • at least 2 players are connected, AND
    • every connected player has their ready flag set to true.

  Reconnect after round (Bug 2 fix)
  ───────────────────────────────────
  On reset we do NOT call fresh_state/0 (which wiped the players map).
  Instead we keep every existing player entry and merely zero their
  taps and ready flags.  The LiveView processes never left – they
  stay subscribed and continue receiving broadcasts without needing
  to re-join.
  """

  use GenServer

  alias Phoenix.PubSub

  @pubsub TapWar.PubSub
  @topic "game"

  @game_duration_ms 15_000
  @results_duration_ms 10_000

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Join the lobby with a display name."
  def join(player_id, name) do
    GenServer.call(__MODULE__, {:join, player_id, name})
  end

  @doc "Update display name for an existing player."
  def rename(player_id, name) do
    GenServer.cast(__MODULE__, {:rename, player_id, name})
  end

  @doc "Remove a player (called when their LiveView terminates)."
  def leave(player_id) do
    GenServer.cast(__MODULE__, {:leave, player_id})
  end

  @doc "Toggle the calling player's ready flag. Starts countdown when all ready."
  def toggle_ready(player_id) do
    GenServer.cast(__MODULE__, {:toggle_ready, player_id})
  end

  @doc "Record one tap. Rejected silently outside :playing phase."
  def tap(player_id) do
    GenServer.cast(__MODULE__, {:tap, player_id})
  end

  @doc "Return the current snapshot without modifying state."
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  # ── Callbacks ─────────────────────────────────────────────────────────────

  @impl true
  def init(:ok), do: {:ok, fresh_state()}

  @impl true
  def handle_call({:join, player_id, name}, _from, state) do
    # Only add if not already present (handles stale re-mounts)
    player = %{id: player_id, name: name, taps: 0, ready: false}
    new_players = Map.put_new(state.players, player_id, player)
    new_state = %{state | players: new_players}
    broadcast(new_state)
    {:reply, {:ok, new_state}, new_state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:rename, player_id, name}, state) do
    new_players =
      Map.update(state.players, player_id, %{id: player_id, name: name, taps: 0, ready: false}, fn p ->
        %{p | name: name}
      end)
    new_state = %{state | players: new_players}
    broadcast(new_state)
    {:noreply, new_state}
  end

  def handle_cast({:leave, player_id}, state) do
    new_players = Map.delete(state.players, player_id)
    new_state = %{state | players: new_players}
    broadcast(new_state)
    {:noreply, new_state}
  end

  # Toggle ready only allowed in the waiting phase
  def handle_cast({:toggle_ready, player_id}, %{phase: :waiting} = state) do
    new_players =
      Map.update(state.players, player_id, nil, fn p -> %{p | ready: !p.ready} end)

    new_state = %{state | players: new_players}
    # Check whether all players are now ready → auto-start
    new_state = maybe_start_countdown(new_state)
    broadcast(new_state)
    {:noreply, new_state}
  end

  def handle_cast({:toggle_ready, _}, state), do: {:noreply, state}

  def handle_cast({:tap, player_id}, %{phase: :playing} = state) do
    new_players =
      Map.update(state.players, player_id, %{id: player_id, name: "?", taps: 1, ready: false}, fn p ->
        %{p | taps: p.taps + 1}
      end)
    new_state = %{state | players: new_players}
    broadcast(new_state)
    {:noreply, new_state}
  end

  def handle_cast({:tap, _}, state), do: {:noreply, state}

  # ── Internal timer messages ────────────────────────────────────────────────

  @impl true
  def handle_info(:countdown_tick, %{countdown: 1} = state) do
    {:noreply, begin_playing(state)}
  end

  def handle_info(:countdown_tick, %{phase: :countdown} = state) do
    new_state = %{state | countdown: state.countdown - 1}
    Process.send_after(self(), :countdown_tick, 1_000)
    broadcast(new_state)
    {:noreply, new_state}
  end

  def handle_info(:game_over, %{phase: :playing} = state) do
    new_state = %{state | phase: :finished, countdown: nil}
    broadcast(new_state)
    Process.send_after(self(), :reset, @results_duration_ms)
    {:noreply, new_state}
  end

  def handle_info(:reset, state) do
    # ── Bug 2 fix ────────────────────────────────────────────────────────────
    # Keep all existing players; only clear their per-round data.
    # This means every LiveView that is still connected immediately sees
    # themselves in the new lobby without having to re-join.
    reset_players =
      Map.new(state.players, fn {id, p} -> {id, %{p | taps: 0, ready: false}} end)

    new_state = %{
      phase: :waiting,
      players: reset_players,
      countdown: nil,
      game_start_ts: nil,
      game_duration_ms: @game_duration_ms
    }

    broadcast(new_state)
    {:noreply, new_state}
  end

  # Stale timer messages are ignored
  def handle_info(_, state), do: {:noreply, state}

  # ── Private helpers ───────────────────────────────────────────────────────

  defp fresh_state do
    %{
      phase: :waiting,
      players: %{},
      countdown: nil,
      game_start_ts: nil,
      game_duration_ms: @game_duration_ms
    }
  end

  # ── Bug 1 fix ─────────────────────────────────────────────────────────────
  # Start the countdown only when every connected player (≥2) is ready.
  defp maybe_start_countdown(%{phase: :waiting} = state) do
    player_list = Map.values(state.players)
    enough = length(player_list) >= 2
    all_ready = Enum.all?(player_list, & &1.ready)

    if enough and all_ready do
      begin_countdown(state)
    else
      state
    end
  end

  defp maybe_start_countdown(state), do: state

  defp begin_countdown(state) do
    # Zero taps and clear ready flags for the new round
    reset_players =
      Map.new(state.players, fn {id, p} -> {id, %{p | taps: 0, ready: false}} end)

    new_state = %{state | phase: :countdown, countdown: 3, players: reset_players}
    Process.send_after(self(), :countdown_tick, 1_000)
    new_state
  end

  defp begin_playing(state) do
    start_ts = System.system_time(:millisecond)
    new_state = %{state | phase: :playing, countdown: nil, game_start_ts: start_ts}
    Process.send_after(self(), :game_over, @game_duration_ms)
    broadcast(new_state)
    new_state
  end

  defp broadcast(state) do
    PubSub.broadcast(@pubsub, @topic, {:game_update, state})
  end
end

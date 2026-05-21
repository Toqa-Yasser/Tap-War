# TapWar — Multiplayer Keyboard Tap Game

A real-time multiplayer game built with **Elixir** and **Phoenix LiveView**.  
Players compete to tap a button as many times as possible in a 15-second sprint.  
The server is the single source of truth for all timing, so geographic location cannot give any player an unfair advantage.

---

## 🎮 Gameplay Demo

▶️ [Watch the game being played](https://drive.google.com/file/d/1HelagselYM9fjxku6gbpCN_tSgsuw4hj/view?usp=share_link)

---

## 📋 Table of Contents

1. [Quick Start](#-quick-start)
2. [Why Elixir + LiveView?](#-why-elixir--liveview)
3. [System Design](#-system-design)
4. [Architecture](#-architecture)
5. [File Structure](#-file-structure)
6. [State Machine](#-state-machine)
7. [Data Flow](#-data-flow)
8. [Geographic Fairness](#-geographic-fairness)
9. [Key Design Decisions](#-key-design-decisions)
10. [Testing](#-testing)
11. [AI Challenges](#-ai-challenges)

---

## 🚀 Quick Start

**Requirements:** Elixir 1.14+, Erlang/OTP 25+

```bash
cd tap_war
mix deps.get
mix phx.server
```

Open `http://localhost:4000` in **two or more browser tabs** (or on different machines on the same network).

**How to play:**
1. Set your display name in the input field and click **Set**
2. Click **I'm Ready!** — the button turns green
3. The countdown starts automatically once **every connected player** is ready (minimum 2)
4. Tap the button or press **any key** as fast as you can for 15 seconds
5. Results are shown — winner, scores, and your personal outcome (Won / Lost / Tied)
6. After 10 seconds the lobby resets automatically and everyone can play again

---

## 💡 Why Elixir + LiveView?

This game has three hard requirements that pushed toward this stack:

| Requirement | Why Elixir/OTP handles it well |
|---|---|
| **Shared mutable state** across many players | A `GenServer` owns the state; Erlang guarantees messages are processed one at a time, so tap counts never race without locks |
| **Real-time push** to every browser simultaneously | `Phoenix.PubSub` broadcasts to all subscribers in one call; LiveView diffs and patches the DOM over WebSocket |
| **Authoritative server-side timer** | `Process.send_after/3` uses the node's monotonic clock; the `:game_over` message fires exactly once, ending the game for every player at the identical moment |
| **Fault tolerance** | If the GameServer crashes, the OTP supervisor restarts it automatically in under a millisecond |

A traditional HTTP + polling approach would require client-side timers (which drift), manual lock management for shared state, and repeated network requests. LiveView eliminates all three problems.

---

## 🏗️ System Design

### High-Level Overview

```
Browser A          Browser B          Browser C
(LiveView)         (LiveView)         (LiveView)
    │                  │                  │
    │  WebSocket        │  WebSocket        │  WebSocket
    └──────────────────┴──────────────────┘
                        │
                  Phoenix Endpoint
                        │
              ┌─────────┴──────────┐
              │   Phoenix PubSub   │  ← broadcasts to all LiveViews
              └─────────┬──────────┘
                        │
                 ┌──────┴──────┐
                 │  GameServer  │  ← single GenServer process
                 │  (GenServer) │     owns all game state
                 └─────────────┘
```

### Component Responsibilities

```
┌──────────────────────────────────────────────────────────────────┐
│  GameServer (lib/tap_war/game_server.ex)                         │
│                                                                  │
│  • Owns the single authoritative copy of game state              │
│  • Runs the countdown and game-over timers                       │
│  • Validates taps (rejects outside :playing phase)               │
│  • Broadcasts every state change via PubSub                      │
│  • Keeps players between rounds (no data wipe on reset)          │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│  GameLive (lib/tap_war_web/live/game_live.ex)                    │
│                                                                  │
│  • One process per browser tab                                   │
│  • Subscribes to PubSub on mount, unsubscribes on disconnect     │
│  • Converts user events (click / keypress) into GameServer calls │
│  • Re-renders only changed assigns (LiveView diffing)            │
│  • Pushes start timestamp to JS hook for smooth progress bar     │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│  TapGame JS Hook (assets/js/app.js)                              │
│                                                                  │
│  • Intercepts keydown events → pushEvent("tap") to LiveView      │
│  • Receives "game_started" push → drives progress bar via        │
│    requestAnimationFrame (smooth, no round-trip per frame)       │
│  • Turns bar red in the final 20% of time                        │
└──────────────────────────────────────────────────────────────────┘
```

---

## 📁 File Structure

```
tap_war/
├── lib/
│   ├── tap_war/
│   │   ├── application.ex          OTP supervisor — starts GameServer + PubSub
│   │   └── game_server.ex          All game logic (GenServer)
│   └── tap_war_web/
│       ├── live/
│       │   ├── game_live.ex        LiveView per player (server logic)
│       │   └── game_live.html.heex HEEx template (UI rendering)
│       ├── components/
│       │   └── layouts/
│       │       └── root.html.heex  HTML shell (meta, CSS, JS tags)
│       ├── router.ex               Routes: live "/" → GameLive
│       └── endpoint.ex             HTTP + WebSocket entry point
├── assets/
│   ├── css/app.css                 Tailwind + custom animations
│   └── js/app.js                   TapGame hook + LiveSocket setup
└── mix.exs                         Dependencies
```

### Key Dependency Chain

```
mix phx.server
      │
      ▼
TapWar.Application (supervisor)
      ├── TapWarWeb.Telemetry
      ├── Phoenix.PubSub  (name: TapWar.PubSub)
      ├── TapWar.GameServer               ← registered as module name
      └── TapWarWeb.Endpoint
               └── LiveView WebSocket
                        └── GameLive (one per tab)
```

---

## 🔄 State Machine

The `GameServer` moves through four phases. Every transition triggers a PubSub broadcast so all LiveViews repaint simultaneously.

```
                      ┌─────────────────────────────────────┐
                      │                                     │
                      ▼                                     │
              ┌───────────────┐                             │
              │   :waiting    │  ← players join, set names, │
              │   (lobby)     │    toggle ready             │
              └──────┬────────┘                             │
                     │ all players ready (≥ 2)              │
                     ▼                                       │
              ┌───────────────┐                             │
              │  :countdown   │  ← 3 ticks × 1 s           │
              │  (3, 2, 1…)   │    tapping disabled         │
              └──────┬────────┘                             │
                     │ countdown reaches 0                  │
                     ▼                                       │
              ┌───────────────┐                             │
              │   :playing    │  ← 15 000 ms                │
              │   (sprint)    │    taps accepted             │
              └──────┬────────┘                             │
                     │ :game_over fires                     │
                     ▼                                       │
              ┌───────────────┐                             │
              │   :finished   │  ← 10 000 ms results        │
              │   (results)   │    display                  │
              └──────┬────────┘                             │
                     │ :reset fires                         │
                     └─────────────────────────────────────┘
```

### Phase Rules

| Phase | Taps accepted? | Ready toggle allowed? | New players can join? |
|---|---|---|---|
| `:waiting` | ✗ | ✓ | ✓ |
| `:countdown` | ✗ | ✗ | ✓ (spectate) |
| `:playing` | ✓ | ✗ | ✓ (spectate) |
| `:finished` | ✗ | ✗ | ✓ (spectate) |

---

## 🔀 Data Flow

### Player joins the lobby

```
Browser               LiveView process          GameServer
   │                       │                       │
   │── HTTP GET / ────────▶│                       │
   │◀─ HTML (dead render) ─│                       │
   │                       │                       │
   │── WebSocket connect ─▶│                       │
   │                       │── PubSub.subscribe ──▶│ (TapWar.PubSub)
   │                       │── GameServer.join ───▶│
   │                       │◀─ {:ok, game_state} ──│
   │◀─ assign + re-render ─│                       │
   │                       │◀── {:game_update, s} ─│ (broadcast to all)
```

### Player taps during :playing

```
Browser               LiveView process          GameServer          Other LiveViews
   │                       │                       │                      │
   │── phx-click "tap" ───▶│                       │                      │
   │                       │── GameServer.tap ─────▶│                      │
   │                       │                       │── broadcast ─────────▶│
   │◀─ {:game_update, s} ──│                       │◀─ {:game_update, s} ──│
   │  (re-render counts)   │                       │   (re-render counts)  │
```

### Game ends

```
GameServer (internal)      All LiveViews           All Browsers
       │                        │                       │
       │── :game_over fires     │                       │
       │   (Process.send_after) │                       │
       │── broadcast :finished ▶│                       │
       │                        │── assign phase ──────▶│
       │                        │   (results shown)     │
       │                        │                       │
       │── :reset fires (10 s)  │                       │
       │── broadcast :waiting ─▶│                       │
       │   (players kept,       │── assign phase ──────▶│
       │    taps/ready zeroed)  │   (lobby reappears)   │
```

---

## 🌍 Geographic Fairness

This is the core design challenge: players in different countries must have an equal game window.

### The problem with client-side timers

If each browser started its own 15-second countdown independently:
- Clock drift, CPU throttling, and browser tab suspension would make timers inconsistent
- A player could manipulate their system clock to get more time
- Network latency would mean players receive "start" at slightly different moments

### The server-authoritative solution

```
                  SERVER (single clock)
                        │
       ┌────────────────┼────────────────┐
       │                │                │
  Player (Tokyo)   Player (London)  Player (New York)
       │                │                │
       ▼                ▼                ▼
  Receives         Receives         Receives
  :playing         :playing         :playing
  broadcast        broadcast        broadcast
  (same instant)   (same instant)   (same instant)
       │                │                │
       └────────────────┼────────────────┘
                        │
                  :game_over fires
                  on SERVER after
                  exactly 15 000 ms
                  (one message, one moment)
```

**How it works in code:**
1. When `:playing` begins, `System.system_time(:millisecond)` captures the server's Unix timestamp
2. `Process.send_after(self(), :game_over, 15_000)` schedules the end on the server
3. The timestamp is broadcast to all LiveViews in the same message
4. Each LiveView pushes it to its JS hook via `push_event/3`
5. The JS hook uses `Date.now()` against that timestamp to animate the progress bar
6. The bar is **cosmetic only** — the server's `:game_over` message ends the game, not the bar

This means:
- A player with a slow connection sees the bar tick down a little slower — but their taps still count until the server says stop
- A player who tries to manipulate their clock gets an incorrect bar but no extra game time
- Every player's 15 seconds is identical — measured by one clock on one machine

---

## 🧠 Key Design Decisions

### 1. Single GenServer for all players

Rather than one process per game room or per player, a single named `GenServer` manages the entire game. This works because:
- There is only one active game at a time
- Erlang message queues serialize all state changes automatically — no mutex, no `Agent`, no ETS table needed
- The process name (`TapWar.GameServer`) makes it trivially accessible from any LiveView

### 2. PubSub broadcast on every state change

Every mutation in `GameServer` calls `broadcast/1` at the end. This means every connected LiveView always has the latest snapshot pushed to it automatically — there is no polling, no request-response loop, and no way for one player's view to get out of sync with another.

### 3. Per-player ready system

The lobby requires **all players** to click Ready before the game starts. This was a deliberate correction from the initial AI-generated design (which let one player force-start for everyone). The server enforces this with a guard:

```
all_ready? = Enum.all?(players, fn p -> p.ready end)
enough?    = length(players) >= 2
start      = all_ready? AND enough?
```

### 4. Players are kept across rounds

On `:reset`, the server does **not** clear the player map. It only zeros taps and ready flags. This means:
- LiveView processes never need to re-join — they are still subscribed
- Players see themselves in the lobby instantly after results
- No "ghost player" issue where someone appears twice

### 5. Rename instead of leave + rejoin for name changes

When a player sets their display name, the original code called `leave` then `join`. This briefly removed the player from the lobby and re-added them, which could:
- Clear their ready flag mid-session
- Cause a flash in other players' views
- Lose the player if `join` failed

The fix uses a dedicated `rename` cast that updates only the `name` field in place.

### 6. Tap validation is server-side only

The server pattern-matches on `%{phase: :playing}` before accepting a tap. Any tap cast that arrives in any other phase is silently dropped with `{:noreply, state}`. Client-side code cannot override this — there is no "tap accepted" flag the browser controls.

---

## 🧪 Testing

### Manual testing checklist

Run the server and open multiple tabs to verify each scenario:

**Lobby behaviour**
- [ ] Name in the player list matches the name pre-filled in the input box
- [ ] Setting a name updates the lobby instantly without removing the player
- [ ] "I'm Ready!" button turns green and shows "✓ Ready! (click to cancel)"
- [ ] Clicking again un-readies the player
- [ ] The `X/Y ready` counter updates for all tabs in real time
- [ ] The game does **not** start until **all** players are ready
- [ ] The game does **not** start with only 1 player

**Gameplay**
- [ ] Countdown shows 3 → 2 → 1 with 1-second intervals
- [ ] Taps via mouse click increment the counter
- [ ] Taps via any keyboard key increment the counter
- [ ] Tapping inside the name input field does **not** register as a game tap
- [ ] Progress bar drains over 15 seconds and turns red at 20%
- [ ] Taps during countdown or after game over are silently ignored

**Results**
- [ ] 🏆 "You Won!" shown to the player with the highest tap count
- [ ] 😔 "You Lost" shown to players with a lower tap count
- [ ] 🤝 "It's a Tie!" shown to all players who share the top score
- [ ] Final scores list is sorted from highest to lowest

**Round reset**
- [ ] After 10 seconds on results, lobby reappears automatically
- [ ] All players are still present in the lobby without refreshing
- [ ] All tap counts are reset to 0
- [ ] All players are shown as "NOT READY"
- [ ] Players can click Ready and start another round immediately

**Disconnection**
- [ ] Closing a tab removes the player from the lobby for everyone else
- [ ] If the last player leaves, the lobby shows "No players yet"

### Running the test suite

```bash
cd tap_war
mix test
```

The generated Phoenix test suite covers the router and controller layer. To add custom game logic tests:

```bash
# Example: test GameServer state transitions
mix test test/tap_war/game_server_test.exs
```

### Load / stress testing (manual)

Open 5+ tabs and have them all click Ready simultaneously to verify:
- The server handles concurrent broadcasts without duplicating the countdown
- Tap counts increment correctly under rapid fire (hold a key down)
- The game ends at exactly 15 s regardless of tap frequency

---

## 🤖 AI Challenges — Where the AI Failed and What I Had to Fix

### Problem 1 — Lobby Name and Input Placeholder Were Always Different

**Where the problem was:**  
On the lobby screen, the name next to "YOU" and the name pre-filled in the input box showed different random numbers — for example "Player 1818" in the lobby but "Player 4234" in the input.

**Why the AI failed:**  
The random name generator was called twice in two separate lines of code. Because it uses a random-number function, each call returns a different value. The AI wrote the two calls independently without realising they needed to share the same result. It was a subtle variable reuse mistake that only appears at runtime, not during code review of a single line.

**The solution:**  
Generate the random name once, store it in a variable, and pass that same variable to both the server registration and the input field. One call, one value, used in two places.

---

### Problem 2 — One Player Could Force-Start the Game for Everyone

**Where the problem was:**  
The lobby had a single "Start Game" button. Any player who pressed it immediately started the countdown for all players in the room — including players who had not yet set their name or had not consented to play.

**Why the AI failed:**  
The AI modelled the start mechanism as a global server command: one player sends it, the server acts on it, everyone is affected. This is a natural pattern in host-controlled games but breaks fairness in a symmetric peer game. The AI did not consider that in a game where all players are equal, every player must individually agree before the game begins.

**The solution:**  
Replace the single Start button with a per-player **Ready toggle**. Each player independently clicks "I'm Ready!" on their own screen. The server only begins the countdown when every connected player has their ready flag set to true and at least two players are present. No single player can force-start for others.

---

### Problem 3 — Players Lost Their Connection After the Round Ended

**Where the problem was:**  
After the results screen disappeared, the lobby reappeared empty. Players could not play another round together without refreshing their browser tabs. After refreshing they would appear as brand-new players with no memory of the previous round.

**Why the AI failed:**  
The reset function rebuilt the game state from scratch — creating a completely empty players map. The server forgot every player who had just played. The AI treated "reset" as "wipe everything and start from zero," which is correct for the game data (scores, timers) but wrong for player identities. The LiveView processes were still running and still subscribed to PubSub, but the server had no record of them.

**The solution:**  
The reset keeps the existing player map intact and only clears the per-round fields: tap counts and ready flags. Player IDs, names, and PubSub subscriptions survive the reset untouched. When the lobby appears again, every player is already in it with their name ready to go.

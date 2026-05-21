# Task 3 — TapWar: Multiplayer Keyboard Tap Game

A real-time multiplayer game built with **Elixir** and **Phoenix LiveView**.  
Players compete to tap a button as many times as possible within a 15-second sprint. The server is the single authority for all timing, so geographic location cannot give any player an unfair advantage.

---

## 🎮 Gameplay Demo

▶️ [Watch the game being played](https://drive.google.com/file/d/1HelagselYM9fjxku6gbpCN_tSgsuw4hj/view?usp=share_link)

---

## 🚀 How to Run

```bash
cd tap_war
mix deps.get
mix phx.server
```

Open `http://localhost:4000` in two or more browser tabs, set your names, click **I'm Ready!**, and tap as fast as you can.

---

## 🤖 AI Challenges — Where the AI Failed and What I Had to Fix

This section documents the real problems that emerged during development with AI assistance, what caused them, and how they were resolved.

---

### Problem 1 — The Lobby Name and the Input Placeholder Were Always Different

**Where the problem was:**  
On the lobby screen, when a new player opened the game, the name displayed next to "YOU" in the player list was different from the name pre-filled in the "Set your display name" input box. For example, the lobby would say "Player 1818" while the input showed "Player 4234".

**Why the AI failed:**  
The AI generated a random player name by calling a random-number function, but it called that function **twice** in separate places — once to register the player with the game server, and once to fill the input field. Because the function returns a new random number every time it is called, the two values were always different. The AI did not notice that the same function call was being reused, and neither call was sharing its result with the other.

**The solution :**  
The random name is generated once and stored in a single variable. That same variable is then passed to both the server registration and the input field pre-fill. Generating the value once and reusing it means both places are guaranteed to be identical.

---

### Problem 2 — One Player Could Force-Start the Game for Everyone

**Where the problem was:**  
The lobby had a single "Start Game" button. Any player who clicked it would immediately trigger the countdown for all players in the room — even players who had not yet set their name or had not agreed to start. A player could join, see the lobby, and be thrown into a live game before doing anything.

**Why the AI failed:**  
The AI designed the start mechanism as a global action: one player fires a command, the server starts the game for everyone. This is a common pattern in single-player or host-based games but is unfair in a symmetric multiplayer setting. The AI did not consider that each player needs individual consent before the game begins.

**The solution :**  
The single "Start Game" button was replaced with a **per-player Ready toggle**. Each player independently clicks "I'm Ready!" on their own screen. The server monitors the ready flags of all connected players and only triggers the countdown when every single player — with no exceptions — has marked themselves as ready, and at least two players are present. This makes it impossible for one player to start the game without the full consent of all others.

---

### Problem 3 — Players Lost Their Connection After the Round Ended

**Where the problem was:**  
After a game finished and the results screen faded away, the players could not play another round together. The lobby would appear empty or show the players as if they were new strangers. Players had to refresh the page to reconnect, and even then they would see each other as new entrants rather than the same group who just played.

**Why the AI failed:**  
When the game reset at the end of a round, the AI's code called a function that built a completely empty server state — wiping the entire player list. The game server had no memory of who was in the previous round. The browser tabs (LiveView processes) were still running and subscribed, but the server had forgotten them entirely. The AI treated "reset" as "start from absolute zero."

**The solution (without code):**  
The reset logic was changed so that it **keeps all existing players** rather than deleting them. Instead of rebuilding empty state, the server takes the current player list and clears only the per-round data — tap counts and ready flags — while preserving player identity and names. When the lobby reappears, every connected player finds themselves already present in it with their name intact, and can immediately click Ready to start the next round without any page refresh.

---

## 🏗️ Architecture Summary

| Layer | Technology | Role |
|---|---|---|
| Game logic | `GenServer` (Elixir OTP) | Single process owns all state; messages are serialised so tap counts never race |
| Real-time sync | `Phoenix.PubSub` | Broadcasts every state change to all connected LiveViews simultaneously |
| UI | `Phoenix LiveView` | Server-rendered HTML pushed over WebSocket; no separate API |
| Timer fairness | `Process.send_after` | All game timers run on the server clock — geography is irrelevant |
| Progress bar | JavaScript hook | Smooth client-side animation driven by the server's start timestamp; outcome is still server-determined |
# Tap-War

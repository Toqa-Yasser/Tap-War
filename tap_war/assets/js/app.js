import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

// ── TapGame Hook ─────────────────────────────────────────────────────────────
//
// Attached to the root <div id="game-root">.
//
// Responsibilities:
//   1. Forward every keydown event on the document as a "tap" LiveView event
//      (so players can use any key, not just click the button).
//   2. Listen for the "game_started" server push and drive the countdown
//      progress bar entirely client-side — this gives a smooth animation
//      without a WebSocket round-trip on every frame.
//
// Geographic fairness note:
//   The server sends `start_ts` (Unix ms from System.system_time(:millisecond)
//   on the Elixir node) and `duration_ms` (15 000).  The bar width is derived
//   from  (start_ts + duration_ms - Date.now()) / duration_ms  which means:
//   - A player whose clock is 1 second fast will see the bar run out 1 s early
//     but the SERVER still ends the game at the right time — they just get
//     a slightly inaccurate visual.
//   - The game outcome is 100% server-determined; the bar is cosmetic only.
const TapGame = {
  mounted() {
    // Forward any key press as a tap during the game
    this._keyHandler = (e) => {
      // Ignore modifier-only keys and key repeats to avoid accidental spam
      if (e.repeat) return
      if (["Tab", "Escape", "F5", "F12"].includes(e.key)) return
      // Don't steal focus from the name input
      if (document.activeElement && document.activeElement.tagName === "INPUT") return
      this.pushEvent("tap", {})
    }
    document.addEventListener("keydown", this._keyHandler)

    // Listen for the server push that signals the game has started
    this.handleEvent("game_started", ({start_ts, duration_ms}) => {
      this._startTimer(start_ts, duration_ms)
    })
  },

  destroyed() {
    document.removeEventListener("keydown", this._keyHandler)
    this._stopTimer()
  },

  _startTimer(start_ts, duration_ms) {
    this._stopTimer()

    const bar = document.getElementById("timer-bar")
    const label = document.getElementById("timer-label")

    const tick = () => {
      const now = Date.now()
      const elapsed = now - start_ts
      const remaining = Math.max(0, duration_ms - elapsed)
      const pct = (remaining / duration_ms) * 100

      if (bar) {
        bar.style.width = pct.toFixed(2) + "%"
        // Change colour as time runs low
        if (pct < 20) {
          bar.className = bar.className.replace("bg-yellow-400", "bg-red-500")
        }
      }
      if (label) {
        label.textContent = Math.ceil(remaining / 1000) + "s"
      }

      if (remaining > 0) {
        this._raf = requestAnimationFrame(tick)
      }
    }

    this._raf = requestAnimationFrame(tick)
  },

  _stopTimer() {
    if (this._raf) {
      cancelAnimationFrame(this._raf)
      this._raf = null
    }
  }
}

// ── LiveSocket setup ──────────────────────────────────────────────────────────

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {TapGame},
})

topbar.config({barColors: {0: "#facc15"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()
window.liveSocket = liveSocket

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if (keyDown === "c") {
        e.preventDefault(); e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if (keyDown === "d") {
        e.preventDefault(); e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)
    window.liveReloader = reloader
  })
}

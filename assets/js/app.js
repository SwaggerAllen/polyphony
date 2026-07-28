// Polyphony client. Bundled by esbuild; `phoenix` and `phoenix_live_view` are
// resolved from deps/ (NODE_PATH) — the same JS that ships with the Elixir deps.
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content")

const Hooks = {}

// Keep a scrollable transcript pinned to the bottom as new beats stream in,
// unless the reader has scrolled up to read history.
Hooks.Autoscroll = {
  isPinned() {
    const el = this.el
    return el.scrollHeight - el.clientHeight - el.scrollTop < 80
  },
  mounted() {
    this.pinned = true
    this.el.addEventListener("scroll", () => (this.pinned = this.isPinned()))
    this.el.scrollTop = this.el.scrollHeight
  },
  updated() {
    if (this.pinned) this.el.scrollTop = this.el.scrollHeight
  },
}

// Auto-grow a textarea to fit its content (no inner scroll), so long authored
// paragraphs are fully readable. Used by the block-field editor.
Hooks.AutoGrow = {
  grow() {
    this.el.style.height = "auto"
    this.el.style.height = this.el.scrollHeight + "px"
  },
  mounted() {
    this.grow()
    this.el.addEventListener("input", () => this.grow())
  },
  updated() {
    this.grow()
  },
}

// The scene composer: an auto-growing textarea that sends on Enter (Shift+Enter for a
// newline) and clears itself after submit. Distinct from AutoGrow — that one backs
// persistent editor fields and must never self-clear.
Hooks.ComposerInput = {
  grow() {
    this.el.style.height = "auto"
    this.el.style.height = this.el.scrollHeight + "px"
  },
  mounted() {
    this.grow()
    this.el.addEventListener("input", () => this.grow())
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()
        if (this.el.form) this.el.form.requestSubmit()
      }
    })
    if (this.el.form) {
      this.el.form.addEventListener("submit", () => {
        setTimeout(() => {
          this.el.value = ""
          this.grow()
        }, 0)
      })

      // ✨ Expand: send the current draft to the server for a generated turn.
      const expand = this.el.form.querySelector("[data-composer-expand]")
      if (expand) {
        expand.addEventListener("click", (e) => {
          e.preventDefault()
          this.pushEvent("compose", { text: this.el.value })
        })
      }
    }

    // The server pushes the drafted turn back into the composer to edit before sending.
    this.handleEvent("set_composer", ({ text }) => {
      this.el.value = text
      this.grow()
      this.el.focus()
    })
  },
  updated() {
    this.grow()
  },
}

// Confirm before following a link that opts in via data-confirm (used to guard
// navigation away from an editor with unsaved changes). Capture phase so it runs
// before the browser navigates; the attribute is only rendered when there's
// something to lose, so a clean page never prompts.
window.addEventListener(
  "click",
  (e) => {
    const link = e.target.closest && e.target.closest("a[data-confirm]")
    if (link && !window.confirm(link.getAttribute("data-confirm"))) {
      e.preventDefault()
      e.stopPropagation()
    }
  },
  true,
)

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
})

// The debug drawer (bring-up aid). Its open/close, copy, and socket-status
// indicator are wired here in plain JS — deliberately NOT via phx-click / hooks —
// so the drawer stays usable and keeps reporting connection state even when the
// LiveView socket never connects, which is the exact failure it exists to surface.
function initDebugDrawer(liveSocket) {
  const drawer = document.getElementById("debug-drawer")
  if (!drawer) return // drawer disabled — nothing rendered

  const body = document.getElementById("debug-drawer-body")
  const toggle = document.getElementById("debug-drawer-toggle")
  const closeBtn = document.getElementById("debug-drawer-close")
  const copyBtn = document.getElementById("debug-copy")

  if (toggle && body) {
    toggle.addEventListener("click", () => {
      body.style.display = "flex"
      toggle.style.display = "none"
    })
  }
  if (closeBtn && body && toggle) {
    closeBtn.addEventListener("click", () => {
      body.style.display = "none"
      toggle.style.display = ""
    })
  }
  if (copyBtn) {
    copyBtn.addEventListener("click", () => {
      const list = document.getElementById("debug-log-list")
      if (!list) return
      navigator.clipboard.writeText(list.innerText).then(() => {
        const original = copyBtn.textContent
        copyBtn.textContent = "Copied!"
        setTimeout(() => (copyBtn.textContent = original), 1200)
      })
    })
  }

  // Reflect the Phoenix socket lifecycle onto the status pill (drawer head) and
  // the dot on the collapsed toggle, so connection state is visible either way.
  const pill = document.getElementById("socket-status")
  const dot = document.getElementById("socket-status-toggle")
  const setStatus = (state, label) => {
    if (pill) {
      pill.className = `socket-status ${state}`
      pill.textContent = label
    }
    if (dot) dot.className = `socket-dot ${state}`
  }

  setStatus("connecting", "connecting…")
  const socket = liveSocket.socket
  if (socket) {
    socket.onOpen(() => setStatus("connected", "connected"))
    socket.onError(() => setStatus("disconnected", "disconnected"))
    socket.onClose(() => setStatus("disconnected", "disconnected"))
  }
}

initDebugDrawer(liveSocket)
liveSocket.connect()
window.liveSocket = liveSocket

// Polyphony client. Bundled by esbuild; `phoenix` and `phoenix_live_view` are
// resolved from deps/ (NODE_PATH) — the same JS that ships with the Elixir deps.
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content")

const Hooks = {}

// Modern browsers size textareas to their content in pure CSS (`field-sizing: content`);
// where that's available, the auto-grow hooks below are unnecessary and stand down so
// nothing sets an inline height (which is what morphdom used to strip, collapsing fields).
// The JS path remains only as a fallback for browsers without field-sizing.
const FIELD_SIZING =
  typeof CSS !== "undefined" && CSS.supports && CSS.supports("field-sizing", "content")

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
    if (FIELD_SIZING) return // CSS handles sizing — do nothing.
    // A hidden textarea (inside a collapsed <details>) has scrollHeight 0; measuring it
    // would set height:0, so it shows collapsed when re-opened. Skip until it's visible —
    // the details `toggle` handler re-grows it on open.
    if (this.el.offsetParent === null) return
    // Setting height:auto momentarily collapses the textarea to one row; across many
    // fields that collapse/expand yanks the whole page. Preserve the scroll position
    // around the reflow so growing never scrolls the page.
    const y = window.scrollY
    this.el.style.height = "auto"
    this.el.style.height = this.el.scrollHeight + "px"
    if (window.scrollY !== y) window.scrollTo(window.scrollX, y)
  },
  mounted() {
    this.grow()
    this.el.addEventListener("input", () => this.grow())
  },
  updated() {
    // Re-apply the height on EVERY patch. A LiveView DOM patch (e.g. typing in one field,
    // or a Generate button's label flipping) syncs each textarea to the server node, which
    // carries no inline height — so morphdom strips the height we set, collapsing every
    // OTHER field when any one of them re-renders. grow() no-ops while hidden (collapsed
    // <details>), preserves scroll, and its auto→scrollHeight writes are synchronous (no
    // flicker), so re-growing here restores the size without jumping the page.
    this.grow()
  },
}

// The scene composer: an auto-growing textarea that sends on Enter (Shift+Enter for a
// newline) and clears itself after submit. Distinct from AutoGrow — that one backs
// persistent editor fields and must never self-clear.
Hooks.ComposerInput = {
  grow() {
    if (FIELD_SIZING) return // CSS handles sizing; clearing the value shrinks it natively.
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

      // Full screen. A class on <body>, not on the bar: the bar belongs to a
      // LiveView that re-renders on every event in the scene, and an attribute set
      // here would be dropped by the next patch — the same reason the dock's
      // open state lives there. Escape closes it, because a control that takes the
      // whole screen has to have an exit that needs no aim.
      const full = document.getElementById("composer-fullscreen")
      if (full) {
        const setFull = (on) => {
          document.body.classList.toggle("say-full", on)
          full.setAttribute("aria-pressed", String(on))
          if (on) this.el.focus()
          this.grow()
        }

        full.addEventListener("click", (e) => {
          e.preventDefault()
          setFull(!document.body.classList.contains("say-full"))
        })

        this.el.addEventListener("keydown", (e) => {
          if (e.key === "Escape" && document.body.classList.contains("say-full")) setFull(false)
        })

        // Sending is the end of the turn, so it is the end of the room it needed.
        this.el.form.addEventListener("submit", () => setFull(false))
      }

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

// Copy the text of another element to the clipboard. `data-copy-target` names the id
// of the source element; its textContent is copied (so hidden/collapsed content comes
// along). Used by the scene debug-timeline "Copy debug" button.
Hooks.CopyText = {
  mounted() {
    this.el.addEventListener("click", () => {
      const src = document.getElementById(this.el.dataset.copyTarget)
      if (!src) return
      navigator.clipboard.writeText(src.textContent || "").then(() => {
        const original = this.el.textContent
        this.el.textContent = "Copied!"
        setTimeout(() => (this.el.textContent = original), 1200)
      })
    })
  },
}

// When a collapsible section (<details>) opens, re-measure the auto-growing textareas
// inside it — they couldn't be sized while hidden. `toggle` doesn't bubble, so listen in
// the capture phase.
document.addEventListener(
  "toggle",
  (e) => {
    if (FIELD_SIZING) return // CSS sizes the fields when the section becomes visible.
    const d = e.target
    if (d.tagName !== "DETAILS" || !d.open) return
    d.querySelectorAll("textarea.para-input").forEach((ta) => {
      ta.style.height = "auto"
      ta.style.height = ta.scrollHeight + "px"
    })
  },
  true,
)

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

  const toggle = document.getElementById("debug-drawer-toggle")
  const closeBtn = document.getElementById("debug-drawer-close")
  const tuckBtn = document.getElementById("debug-drawer-tuck")
  const copyBtn = document.getElementById("debug-copy")

  // Open/closed is a class on <body>, deliberately not an inline style on the panel.
  // The drawer is a nested LiveView: every server round-trip (Events, Trace, Clear)
  // patches its DOM, re-asserting the template's attributes and discarding whatever
  // we had set. That closed the panel and hid the toggle with it, leaving no way back
  // to the log short of a reload. <body> belongs to the root layout, which no
  // LiveView patches, so the state survives.
  const setOpen = (open) => document.body.classList.toggle("dock-open", open)

  // Tucked shrinks the closed tab to a sliver at the right edge, because the dock is
  // pinned over an app with its own controls in that corner. Remembered across loads:
  // a tab that un-tucks itself on the next page is back in the way, which is the whole
  // point of tucking it. localStorage may throw (private mode, storage disabled), and
  // failing to remember a preference must never take the drawer down with it.
  const TUCK_KEY = "polyphony:dock-tucked"
  const isTucked = () => document.body.classList.contains("dock-tucked")

  const setTucked = (tucked) => {
    document.body.classList.toggle("dock-tucked", tucked)
    try {
      if (tucked) { localStorage.setItem(TUCK_KEY, "1") } else { localStorage.removeItem(TUCK_KEY) }
    } catch (_e) { /* preference not remembered; the class still applies */ }
  }

  try { if (localStorage.getItem(TUCK_KEY)) setTucked(true) } catch (_e) {}

  // Un-tuck first, open second. A sliver on the screen edge is easy to hit by
  // accident, and having that throw a full-height panel over the app would undo the
  // reason it was tucked.
  if (toggle) toggle.addEventListener("click", () => (isTucked() ? setTucked(false) : setOpen(true)))
  if (closeBtn) closeBtn.addEventListener("click", () => setOpen(false))
  if (tuckBtn) tuckBtn.addEventListener("click", () => { setTucked(true); setOpen(false) })
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
  // Colour comes from the kit's semantic tokens, applied inline to a plain .pill
  // and .dot — the same "colour by meaning" rule the mocks use. Nothing here needs
  // a class of its own, which is why the drawer has no stylesheet of its own.
  const COLOUR = {
    connecting: "var(--lamp)",
    connected: "var(--ok)",
    disconnected: "var(--pencil)"
  }
  const setStatus = (state, label) => {
    const colour = COLOUR[state] || "var(--bcm)"
    if (pill) {
      pill.style.color = colour
      pill.style.borderColor = colour
      pill.textContent = label
    }
    if (dot) dot.style.background = colour
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

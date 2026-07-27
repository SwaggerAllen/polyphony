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

// Copy the full debug-log buffer (the `data-target` element's text) to the
// clipboard, with a brief "Copied!" confirmation on the button.
Hooks.CopyLog = {
  mounted() {
    this.el.addEventListener("click", () => {
      const target = document.getElementById(this.el.dataset.target)
      if (!target) return
      navigator.clipboard.writeText(target.innerText).then(() => {
        const original = this.el.textContent
        this.el.textContent = "Copied!"
        setTimeout(() => (this.el.textContent = original), 1200)
      })
    })
  },
}

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
})

liveSocket.connect()
window.liveSocket = liveSocket

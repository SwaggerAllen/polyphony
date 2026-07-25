// Polyphony client. No bundler: phoenix.min.js and phoenix_live_view.min.js are
// vendored IIFE globals (window.Phoenix, window.LiveView), loaded before this file.
(function () {
  const { Socket } = window.Phoenix;
  const { LiveSocket } = window.LiveView;

  const csrfToken = document
    .querySelector("meta[name='csrf-token']")
    .getAttribute("content");

  const Hooks = {};

  // Keep a scrollable transcript pinned to the bottom as new beats stream in,
  // unless the reader has scrolled up to read history.
  Hooks.Autoscroll = {
    isPinned() {
      const el = this.el;
      return el.scrollHeight - el.clientHeight - el.scrollTop < 80;
    },
    mounted() {
      this.pinned = true;
      this.el.addEventListener("scroll", () => (this.pinned = this.isPinned()));
      this.el.scrollTop = this.el.scrollHeight;
    },
    updated() {
      if (this.pinned) this.el.scrollTop = this.el.scrollHeight;
    },
  };

  const liveSocket = new LiveSocket("/live", Socket, {
    params: { _csrf_token: csrfToken },
    hooks: Hooks,
  });

  liveSocket.connect();
  window.liveSocket = liveSocket;
})();

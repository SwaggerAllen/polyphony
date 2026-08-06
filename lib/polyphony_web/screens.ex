defmodule PolyphonyWeb.Screens do
  @moduledoc """
  Whole screens as **function components**, one module per screen, markup only.

  ## Why the markup lives apart from the LiveView

  A LiveView owns three things at once: how data is loaded, how events are handled, and
  what gets drawn. The first two need a session, a database and a running socket. The
  third needs neither — it is a function of assigns — but while it sits inside the
  LiveView it inherits all of those dependencies, and the consequence is that **there is
  no way to look at a screen except by driving the real app into that state**.

  That is fine for the states a live app falls into on its own. It is useless for the
  ones that matter most: empty, failed, mid-generation, spend-cap reached, socket
  disconnected. Those are exactly the states a design session needs to see and exactly
  the ones a live site will never happen to be in.

  So each screen's markup moves here as a public, `attr`-declared function component, and
  the LiveView's `render/1` becomes a single call into it. Then `/storybook` renders every
  state from fixture assigns, and the design thread reads composed screens over HTTP
  instead of being handed a session token for the real app.

  ## The property that keeps it safe

  **A screen component reads no domain data.** It takes assigns and returns markup — no
  repo calls, no context calls, no `Polyphony.*` lookups. That is what makes it renderable
  from fixtures, and it is also the reason `STORYBOOK=true` is safe in production. A story
  that loaded a campaign would quietly turn that flag into an authorization hole, so the
  discipline is load-bearing rather than stylistic: **do the work in the LiveView, pass
  the answer in.**

  A useful side effect is that a screen becomes directly testable with
  `Phoenix.LiveViewTest.render_component/2` — no session, no database, no LiveView
  lifecycle — which is what makes pinning a behaviors doc against tests affordable.

  ## The shape

      # lib/polyphony_web/screens/login.ex
      def screen(assigns), do: ~H"..."

      # lib/polyphony_web/live/login_live.ex
      def render(assigns) do
        ~H"<Screens.Login.screen sent_to={@sent_to} dev_link={@dev_link} />"
      end

  Pass named attrs rather than `{assigns}`. Splatting works and hides the screen's real
  dependency surface — which is the number worth seeing, because a screen taking thirty
  attrs is telling you something true about how much state it needs.

  Every screen module here has a story under `storybook/screens/`, and a test fails if one
  doesn't.
  """
end

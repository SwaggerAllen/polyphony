defmodule Polyphony.SceneClose.Handler do
  @moduledoc """
  The production trigger for the scene-close fan-out (§10).

  `SceneClose.enqueue/2` produces the per-character summaries and arc extraction,
  but nothing invoked it: `SceneClosed` was emitted by the `Scene` aggregate and
  observed by no one, so the whole memory/arc layer was dark in production. This
  handler closes that gap — on each `SceneClosed`, it fans the close out into the
  retryable Oban jobs.

  Like `Broadcast.Publisher`, it is a `start_from: :current` Commanded handler: it
  tails new closes rather than replaying history, so a deploy against an existing
  event store does not re-summarize every scene ever closed. Its persisted
  subscription position then carries it forward, processing each future close once
  and resuming across restarts.

  `enqueue/2` is passed no provider/embedder, so the jobs resolve the configured
  defaults at run time (`Provider.default()` / the configured embedder). It is
  supervised alongside the projectors and, like them, is **off in tests** — its
  work touches Postgres through `Oban.insert!`, which an out-of-test process can't
  reach through the SQL sandbox. Tests drive `SceneClose.run/2` (or this handler's
  `handle/2`) directly instead.
  """
  use Commanded.Event.Handler,
    application: Polyphony.App,
    name: "scene_close_fanout",
    start_from: :current

  require Logger

  alias Polyphony.SceneClose
  alias PolyphonyCore.Events.SceneClosed

  @impl Commanded.Event.Handler
  def handle(%SceneClosed{scene_id: scene_id}, _metadata) do
    {:ok, _counts} = SceneClose.enqueue(scene_id)
    :ok
  end
end

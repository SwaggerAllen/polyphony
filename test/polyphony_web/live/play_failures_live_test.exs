defmodule PolyphonyWeb.PlayFailuresLiveTest do
  @moduledoc "Generation failures surface in the play view (author-only) with a retry."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Failures}
  alias Polyphony.Commands.{OpenScene, EnterCharacter}

  setup :register_and_log_in_user

  defp scene do
    s = "fail-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: s, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: s, character_id: "mira", beat: 1})
    s
  end

  test "an open failure is shown to the author with a retry, hidden from characters",
       %{conn: conn} do
    s = scene()

    Failures.record(%{
      scene_id: s,
      beat: 2,
      subject: "mira",
      operation: :generation,
      kind: :error,
      reason: "provider unavailable",
      worker: Polyphony.Jobs.GeneratePacket,
      args: %{"scene_id" => s}
    })

    {:ok, _view, author_html} = live(conn, ~p"/play/#{s}")
    assert author_html =~ "Couldn&#39;t generate"
    assert author_html =~ "mira"
    assert author_html =~ "provider unavailable"
    assert author_html =~ "phx-click=\"retry_failure\""
    # The failure is interleaved into the transcript (inline), not a standalone pane.
    assert author_html =~ "turn-fail"
    refute author_html =~ "fail-panel"

    # A character must not see the author's failure panel.
    {:ok, _mira, mira_html} = live(conn, ~p"/play/#{s}?as=mira")
    refute mira_html =~ "Couldn&#39;t generate"
  end

  test "a beat-less scene-close failure defaults to the current beat, not the top",
       %{conn: conn} do
    s = scene()
    # Advance the scene's current beat to 2 so the beat-less default is distinguishable.
    :ok = App.dispatch(%EnterCharacter{scene_id: s, character_id: "bram", beat: 2})

    # An early turn failure at beat 1…
    Failures.record(%{
      scene_id: s,
      beat: 1,
      subject: "earlybeat",
      operation: :generation,
      kind: :error,
      reason: "boom",
      worker: Polyphony.Jobs.GeneratePacket,
      args: %{"scene_id" => s}
    })

    # …and a scene-close failure with no beat (arc extraction), emitted at the current beat.
    Failures.record(%{
      scene_id: s,
      subject: "closeup",
      operation: :arc,
      kind: :error,
      reason: "boom",
      worker: Polyphony.Jobs.ExtractArc,
      args: %{"scene_id" => s}
    })

    {:ok, _view, html} = live(conn, ~p"/play/#{s}")
    # The beat-less failure defaults to the current beat, so it lands after the earlier one
    # (not pinned to the top).
    assert :binary.match(html, "earlybeat") < :binary.match(html, "closeup")
  end
end

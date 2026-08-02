defmodule Mix.Tasks.Scene.Reset do
  @moduledoc """
  Wipe every scene and everything derived from one. Library entries are kept.

  The clean-slate the character-identity flip requires — see `Polyphony.SceneReset`
  for why a backfill isn't available (events are immutable; rule 6). This destroys
  play, so it asks first unless given `--yes`.

      mix scene.reset          # prompts
      mix scene.reset --yes    # doesn't

  In production, run it from the release instead:

      bin/polyphony eval "Polyphony.SceneReset.run!()"
  """
  @shortdoc "Wipe all scenes (keeps characters, worlds and campaigns)"

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    if "--yes" in argv or confirm?() do
      result = Polyphony.SceneReset.run!()

      Mix.shell().info("""
      Scenes wiped.
        streams:   #{result.streams}
        rows:      #{inspect(result.rows)}
        campaigns: #{result.campaigns} scene list(s) cleared
      """)
    else
      Mix.shell().info("Nothing was changed.")
    end
  end

  defp confirm? do
    Mix.shell().yes?(
      "This deletes every scene, transcript, summary and arc proposal in " <>
        "#{Mix.env()}. Characters, worlds and campaigns are kept. Continue?"
    )
  end
end

defmodule Polyphony.Jobs.RunBeatUniqueTest do
  @moduledoc """
  One beat coordinator per scene-beat at a time.

  A `RunBeat` firing makes the Director judgment call — an LLM call — and then opens the
  beat. Two of them for the same `{scene_id, beat}` is two payments for one exchange, two
  `OpenBeat`s racing to declare a turn order, and a transcript with an exchange that
  happened twice. Nothing in the design produces that, but four call sites enqueue here
  and a double-click or a retry landing beside a fresh trigger arrives as an ordinary
  duplicate insert.

  Both directions matter, and the second is the one that would break the product rather
  than merely cost money: the loop advances by enqueueing itself, so a uniqueness rule
  drawn one notch too wide stalls every scene in the app.
  """
  use ExUnit.Case, async: false

  alias Polyphony.Jobs.RunBeat
  alias Polyphony.Repo

  import Ecto.Query

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp queued(scene) do
    Repo.all(
      from(j in "oban_jobs",
        where: j.worker == "Polyphony.Jobs.RunBeat",
        where: fragment("? ->> 'scene_id' = ?", j.args, ^scene),
        select: fragment("? ->> 'beat'", j.args)
      )
    )
  end

  defp scene, do: "rbu-" <> Integer.to_string(System.unique_integer([:positive]))

  test "a second coordinator for the same beat does not queue" do
    s = scene()

    Oban.Testing.with_testing_mode(:manual, fn ->
      RunBeat.enqueue(%{"scene_id" => s, "beat" => 2, "control_hint" => "auto"})
      RunBeat.enqueue(%{"scene_id" => s, "beat" => 2, "control_hint" => "yield_to_user"})
    end)

    assert queued(s) == ["2"], "the beat coordinator ran twice for one exchange"
  end

  test "the args that differ do not make it a different job" do
    # Only `scene_id` and `beat` are compared. A duplicate arriving with a different
    # provider or control hint is still the same exchange — comparing every arg would
    # make the rule true and useless.
    s = scene()

    Oban.Testing.with_testing_mode(:manual, fn ->
      RunBeat.enqueue(%{"scene_id" => s, "beat" => 1, "provider" => "Elixir.Polyphony.LLM.Mock"})
      RunBeat.enqueue(%{"scene_id" => s, "beat" => 1, "depth" => 3, "max_depth" => 9})
    end)

    assert queued(s) == ["1"]
  end

  test "the loop's own next beat is never blocked" do
    # Truncation and the walk both enqueue `beat + 1`, which is what makes a
    # `{scene_id, beat}` key safe. If this ever fails, every scene in the app stops
    # advancing and nothing raises.
    s = scene()

    Oban.Testing.with_testing_mode(:manual, fn ->
      RunBeat.enqueue(%{"scene_id" => s, "beat" => 1})
      RunBeat.enqueue(%{"scene_id" => s, "beat" => 2, "depth" => 1})
      RunBeat.enqueue(%{"scene_id" => s, "beat" => 3, "depth" => 2})
    end)

    assert Enum.sort(queued(s)) == ["1", "2", "3"]
  end

  test "another scene at the same beat is a different job" do
    a = scene()
    b = scene()

    Oban.Testing.with_testing_mode(:manual, fn ->
      RunBeat.enqueue(%{"scene_id" => a, "beat" => 2})
      RunBeat.enqueue(%{"scene_id" => b, "beat" => 2})
    end)

    assert queued(a) == ["2"]
    assert queued(b) == ["2"]
  end
end

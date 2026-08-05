defmodule Polyphony.QuickBuildEnsembleTest do
  @moduledoc """
  Two blank character slots must not produce the same person twice.

  What went wrong is a single word in a prompt. Quick Build hands each character the
  cast written so far, and it passed them through `Autofill`'s `:relations` — the block
  whose heading is *"Related characters — this character's connections; keep them
  consistent with these people"*. For a slot the author left **blank** there is no brief
  and no seed, so another character's whole sheet was the only substantial content in
  the prompt, under an instruction to be consistent with it. The model did the reasonable
  thing and wrote them again.

  Both jobs the block was doing are real, and they pull opposite ways: **continuity** of
  world detail, so the cast doesn't each invent a different landlord for the same
  building, and **distinctness** of person. Only saying both gets both, so the ensemble
  is now its own block that says both.

  These assert on the prompt rather than the output, because the failure was never in
  the model — it was in what we asked for. The offline Mock is deterministic and would
  happily "reproduce" the bug or not depending on hashing, which proves nothing.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.QuickBuild

  @sheet_prompt "You are helping an author create a role-play character"

  setup do
    previous = Application.get_env(:polyphony, :llm)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    %{user: user_fixture()}
  end

  # Capture every prompt, and answer each call with something schema-valid so the build
  # runs to the end. The character responses are distinct so two entries really are
  # written — the point is what we *asked*, but a build that collapses to one character
  # would make the prompt assertions vacuous.
  defp capture_prompts do
    test = self()

    responder = fn messages ->
      prompt = Enum.map_join(messages, "\n", & &1.content)
      send(test, {:prompt, prompt})

      cond do
        String.contains?(prompt, "world bible for a role-play setting") ->
          {:ok, Jason.encode!(%{"name" => "Saltmarch", "setting" => "A tidal port."})}

        String.contains?(prompt, @sheet_prompt) ->
          n = :erlang.unique_integer([:positive])
          {:ok, Jason.encode!(%{"name" => "Person #{n}", "premise" => "Someone #{n}."})}

        true ->
          {:ok, Jason.encode!(%{})}
      end
    end

    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Stub, stub_response: responder)
  end

  # The whole-sheet call specifically. "role-play character" also appears in the
  # boundaries prompt ("places a role-play character can be pushed") and the cover's,
  # both of which run per character and would triple the list.
  defp character_prompts, do: Enum.filter(collect([]), &String.contains?(&1, @sheet_prompt))

  defp collect(acc) do
    receive do
      {:prompt, p} -> collect([p | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "the second blank slot is told the first person already exists", %{user: user} do
    capture_prompts()

    {:ok, result} =
      QuickBuild.build(
        owner: Owner.of(user),
        world_seed: "a rain-drowned harbour",
        character_seeds: ["", ""]
      )

    assert length(result.characters) == 2
    [_first, second] = character_prompts()

    # The instruction that was missing. Without it, a blank slot's prompt is somebody
    # else's sheet and nothing else.
    assert second =~ "Already written into this story — this character is somebody ELSE"
    assert second =~ "Do NOT reuse a name, a role, a premise, a voice or a backstory"

    # And the one that caused it. `relations` still exists and still means "keep them
    # consistent" — it is the character editor's, for people this character is actually
    # connected to. The cast-so-far must not travel under it.
    refute second =~ "keep them consistent with these people"
  end

  test "a blank brief is named as the thing the ensemble should fill", %{user: user} do
    capture_prompts()

    {:ok, _} =
      QuickBuild.build(
        owner: Owner.of(user),
        world_seed: "a rain-drowned harbour",
        character_seeds: ["", ""]
      )

    [_first, second] = character_prompts()

    # With no brief there is nothing to differentiate on except who already exists, so
    # the gap in the ensemble has to be handed over as the brief.
    assert second =~ "If the author's brief above is blank"
    assert second =~ "write the person this story still needs"
  end

  test "the first slot has no ensemble at all — there is nobody yet", %{user: user} do
    capture_prompts()

    {:ok, _} =
      QuickBuild.build(
        owner: Owner.of(user),
        world_seed: "a rain-drowned harbour",
        character_seeds: ["", ""]
      )

    [first, _second] = character_prompts()
    refute first =~ "Already written into this story"
  end

  test "world detail is still asked to line up — distinctness isn't isolation",
       %{user: user} do
    capture_prompts()

    {:ok, _} =
      QuickBuild.build(
        owner: Owner.of(user),
        world_seed: "a rain-drowned harbour",
        character_seeds: ["", ""]
      )

    [_first, second] = character_prompts()

    # The reason the cast is generated in order rather than in parallel. Dropping the
    # ensemble entirely would have fixed the duplicates and lost this.
    assert second =~ "Use them for CONTINUITY"
    assert second =~ "should line up with what these people establish"
  end

  test "everyone still lands in the library", %{user: user} do
    capture_prompts()

    {:ok, result} =
      QuickBuild.build(
        owner: Owner.of(user),
        world_seed: "a rain-drowned harbour",
        character_seeds: ["", ""]
      )

    names =
      for e <- result.characters, do: Library.payload(Library.get(e.id)).name

    assert length(Enum.uniq(names)) == 2
  end
end

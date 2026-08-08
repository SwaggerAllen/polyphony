defmodule Polyphony.Director.SceneBrief do
  @moduledoc """
  The Director's omniscient scene context (§9, §10) — the counterpart of a
  character's `Polyphony.Context`, but from the all-seeing vantage.

  A character conditions on: world bible, their own sheet, their filtered live
  history, and their own distant-scene summaries. The Director makes the casting
  and pacing judgment, so it needs the *same shape* of context but **omniscient**:

    * **Frozen at scene open** (`materialize/2`, cached in `Context.Store` under the
      reserved `"omniscient"` key, exactly like the per-character prefixes): the
      world framing, the scene premise, the whole cast's identities, and the
      cross-scene **omniscient** summaries — the table-of-contents rows scene-close
      already writes for the `"omniscient"` viewer and that nothing read until now.
    * **Assembled per decision** (`messages/3`, in the Oban job): the frozen brief,
      the roster present *right now*, the cast instruction, and the **full** scene
      transcript — unfiltered (thoughts and whispers included; the Director is
      omniscient) and token-budgeted so a long scene keeps its opening instead of
      falling off a fixed window.

  Without this the Director saw only a roster of names and a keyhole of recent
  events — a continuity bug in any scene that ran longer than the window or leaned
  on the world or prior scenes. The transcript is read through
  `PolyphonyCore.Packets.canonical/1` (rule 6) so a re-rolled take never reappears.
  """

  alias Polyphony.Authoring.{WorldBible, CharacterSheet, Effective}
  alias Polyphony.Context
  alias Polyphony.Context.{Rebuild, SceneContext, Store, StaticRetriever}
  alias Polyphony.Director.BeatOps
  alias PolyphonyCore.Packets
  alias Polyphony.ReadModels.SceneSummary
  alias PolyphonyCore.Scene.Cast

  alias PolyphonyCore.Events.{
    SpeechUttered,
    ActionTaken,
    ThoughtOccurred,
    DemeanorReported,
    WorldEventOccurred,
    CharacterEntered,
    CharacterExited
  }

  # Leave headroom under the model window for the frozen brief + the decision itself.
  @transcript_token_budget 4_000

  @doc """
  Build and cache the Director's frozen omniscient brief for a scene.

  Options: `:world_bible` (`%WorldBible{}`), `:premise`, `:roster`
  (`[%CharacterSheet{}]` — the cast to render identities for), and retrieval opts
  passed straight through for the cross-scene summaries (`:retriever`, `:repo`,
  `:embedder`, `:summary_limit`, `:distant_summaries`). Retrieval defaults to
  `StaticRetriever` (no pgvector) so the domain core and tests need no DB; the live
  caller passes `PgvectorRetriever` to read the real omniscient summaries.
  """
  @spec materialize(term(), keyword()) :: SceneContext.t()
  def materialize(scene_id, opts \\ []) do
    premise = Keyword.get(opts, :premise)
    location = Keyword.get(opts, :location)

    meta = %{
      world: render_world(Keyword.get(opts, :world_bible)),
      premise: premise,
      location: location,
      roster: opts |> Keyword.get(:roster, []) |> Enum.flat_map(&identity_line/1),
      summaries: fetch_summaries(scene_id, premise, opts)
    }

    ctx = %SceneContext{
      scene_id: scene_id,
      character_id: SceneSummary.omniscient_key(),
      premise: premise,
      prefix: render_prefix(meta),
      meta: meta
    }

    Store.put(scene_id, SceneSummary.omniscient_key(), ctx)
    ctx
  end

  @doc """
  Fold one more character into the cached brief (a mid-scene entry). Re-renders the
  frozen prefix so the newcomer's identity is in the Director's context on the next
  beat. If no brief was materialized yet, seeds a minimal one from this character.
  """
  @spec note_character(term(), CharacterSheet.t() | term()) :: :ok
  def note_character(scene_id, %CharacterSheet{} = sheet) do
    case Store.fetch(scene_id, SceneSummary.omniscient_key()) do
      {:ok, %SceneContext{meta: meta} = ctx} ->
        roster = Enum.uniq((meta[:roster] || []) ++ identity_line(sheet))
        meta = Map.put(meta, :roster, roster)

        Store.put(scene_id, SceneSummary.omniscient_key(), %{
          ctx
          | prefix: render_prefix(meta),
            meta: meta
        })

      :error ->
        materialize(scene_id, roster: [sheet])
    end

    :ok
  end

  def note_character(_scene_id, _other), do: :ok

  @doc """
  The Director's `[system, user]` judgment messages for a beat: the frozen brief
  (if cached), the roster present now, the cast instruction, and the full
  token-budgeted omniscient transcript.

  Options: `:system` (the caller's system message — content register etc.; a
  default is used if absent).
  """
  @spec messages(term(), [term()], keyword()) :: [%{role: String.t(), content: String.t()}]
  def messages(scene_id, members, opts \\ []) do
    # Translate stored character ids → display names for the Director (§5.2).
    cast = Rebuild.cast_for(scene_id)

    user =
      [
        frozen_prefix(scene_id),
        roster_line(members, cast),
        cast_instruction(),
        transcript_section(scene_id, cast)
      ]
      |> compact_join()

    [
      %{role: "system", content: Keyword.get(opts, :system) || default_system()},
      %{role: "user", content: user}
    ]
  end

  # ── Frozen brief ──────────────────────────────────────────────────────────────

  defp frozen_prefix(scene_id) do
    case Store.fetch(scene_id, SceneSummary.omniscient_key()) do
      {:ok, %SceneContext{prefix: prefix}} -> prefix
      :error -> rebuilt_prefix(scene_id)
    end
  end

  # Cold cache (e.g. a node restart wiped ETS mid-scene): rebuild the frozen brief from
  # durable data — the campaign's world, premise, and whole cast — and re-cache, so the
  # Director keeps full parity with the characters (§9) instead of degrading to roster +
  # transcript only. The per-character counterpart is `Context.Rebuild`.
  defp rebuilt_prefix(scene_id) do
    case Rebuild.opened(scene_id) do
      %{} = opened ->
        materialize(scene_id,
          # The Director is omniscient: fold in ALL canon world arc (§2.8), not just
          # facts local to this scene's place.
          world_bible:
            Effective.world_bible(
              Rebuild.world_bible(scene_id),
              Map.get(opened, :campaign_id),
              :all
            ),
          premise: Map.get(opened, :premise),
          location: Map.get(opened, :location_id),
          roster: Rebuild.roster(scene_id),
          retriever: Rebuild.retriever()
        ).prefix

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp render_prefix(meta) do
    [
      meta[:world],
      meta[:location] && "Location: #{meta[:location]}",
      meta[:premise] && "Scene: #{meta[:premise]}",
      render_roster(meta[:roster]),
      render_summaries(meta[:summaries])
    ]
    |> compact_join()
  end

  # **The omniscient read**, and deliberately unfiltered. The Director knows the
  # world's secrets — knowing them is how it aims a scene at one — where a character
  # gets `WorldBible.public/1` in `Polyphony.Context`. The asymmetry is the feature;
  # it is the same asymmetry `Visibility` draws for events.
  defp render_world(%WorldBible{} = b) do
    rules = WorldBible.statements(b.rules)
    canon = WorldBible.statements(b.starting_canon)

    [
      b.name && "World: #{b.name}",
      b.setting && "Setting: #{b.setting}",
      b.tone && "Tone: #{b.tone}",
      rules != [] && "Rules:\n" <> bullets(rules),
      canon != [] && "Canon:\n" <> bullets(canon)
    ]
    |> compact_join("\n")
  end

  defp render_world(_), do: nil

  defp identity_line(%CharacterSheet{name: name} = s) when is_binary(name) and name != "" do
    trait = [s.premise, s.voice] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" — ")
    ["#{name}#{if trait == "", do: "", else: " — " <> trait}"]
  end

  defp identity_line(_), do: []

  defp render_roster([]), do: nil
  defp render_roster(nil), do: nil
  defp render_roster(lines), do: "The cast:\n" <> bullets(lines)

  defp render_summaries([]), do: nil
  defp render_summaries(nil), do: nil

  defp render_summaries(texts),
    do: "Earlier in this story (summarized):\n" <> Enum.join(texts, "\n")

  defp fetch_summaries(scene_id, premise, opts) do
    retriever = Keyword.get(opts, :retriever, StaticRetriever)

    retriever.fetch_summaries(
      %{character_id: SceneSummary.omniscient_key(), scene_id: scene_id},
      premise || "",
      limit: Keyword.get(opts, :summary_limit),
      summaries: Keyword.get(opts, :distant_summaries, []),
      repo: Keyword.get(opts, :repo),
      embedder: Keyword.get(opts, :embedder)
    )
    |> Enum.map(& &1.text)
  rescue
    _ -> []
  end

  # ── Volatile decision context ───────────────────────────────────────────────

  defp roster_line([], _cast), do: "(no characters are present)"

  defp roster_line(members, cast),
    do:
      "Characters present in the scene: " <>
        (members |> Enum.map(&Cast.render_name(cast, &1)) |> Enum.join(", "))

  defp cast_instruction do
    """
    Cast the characters who should act in this beat. Unless a character just exited
    or clearly has nothing to do, cast every present character, in a natural order —
    an empty cast means no one acts. Use these exact ids in `cast`.
    """
    |> String.trim()
  end

  # The full scene, oldest first, budgeted by tokens keeping the most recent — so a
  # long scene keeps its opening context instead of dropping off a fixed window.
  @doc """
  The last `limit` lines of the scene, as the Director sees them.

  Omniscient, and that is the point: the canonical log **is** the omniscient projection
  (`Visibility` lets `:omniscient` see everything), so reading the stream is the same
  answer as projecting it, and it is the answer the Director already conditions on
  through `transcript_section/2`.

  Exists because the play screen's Narrate control needed the same read and had grown
  its own — over `socket.assigns.messages`, which is a **viewer-filtered** projection, so
  the context a human Director wrote from depended on which perspective they happened to
  be looking through. It also filtered by a hand-kept list of "public" event kinds, which
  is `Visibility`'s job and gets a new event type wrong by omission rather than by
  default-deny.

  The filtering was deliberate and is now deliberately gone: the world does not care what
  is secret, and **has to know** in order to stay consistent with it. A door is locked
  because somebody locked it quietly; a world that cannot see the quiet part writes the
  door open. What stops the secret being said out loud is the prompt (a world event is
  seen by everyone) and the author, who edits the draft before committing it.

  Goes through `Packets.canonical/1` like every other read that feeds fiction (rule 6,
  §7), so a re-rolled turn never reappears in the context.
  """
  @spec recent_lines(term(), pos_integer()) :: [String.t()]
  def recent_lines(scene_id, limit \\ 12) do
    cast = Rebuild.cast_for(scene_id)

    scene_id
    |> BeatOps.stored_events()
    |> Packets.canonical()
    |> Enum.flat_map(&transcript_line(&1, cast))
    |> Enum.take(-limit)
  end

  defp transcript_section(scene_id, cast) do
    lines =
      scene_id
      |> BeatOps.stored_events()
      |> Packets.canonical()
      |> Enum.flat_map(&transcript_line(&1, cast))
      |> budget_tail(@transcript_token_budget)

    case lines do
      [] -> "The scene so far: nothing has happened yet."
      kept -> "The scene so far (oldest first):\n" <> Enum.join(kept, "\n")
    end
  end

  # Keep the most recent lines that fit the budget, preserving chronological order.
  defp budget_tail(lines, budget) do
    lines
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn line, {acc, total} ->
      next = total + Context.estimate_tokens(line)

      if acc != [] and next > budget do
        {:halt, {acc, total}}
      else
        {:cont, {[line | acc], next}}
      end
    end)
    |> elem(0)
  end

  defp transcript_line(
         %SpeechUttered{speaker_id: s, content: c, audibility: a, addressed_to: to},
         cast
       ) do
    whisper = if a == :private, do: " (whispered#{addressed(to, cast)})", else: ""
    ["#{Cast.render_name(cast, s)}#{whisper}: #{c}"]
  end

  defp transcript_line(%ActionTaken{character_id: s, content: c}, cast),
    do: ["#{Cast.render_name(cast, s)} #{c}"]

  defp transcript_line(%ThoughtOccurred{character_id: s, content: c}, cast),
    do: ["(#{Cast.render_name(cast, s)} thinks: #{c})"]

  defp transcript_line(%DemeanorReported{character_id: s, demeanor: d}, cast)
       when is_binary(d) and d != "",
       do: ["[#{Cast.render_name(cast, s)} seems #{d}]"]

  defp transcript_line(%WorldEventOccurred{content: c}, _cast), do: ["#{c}"]

  defp transcript_line(%CharacterEntered{character_id: s}, cast),
    do: ["(#{Cast.render_name(cast, s)} enters)"]

  defp transcript_line(%CharacterExited{character_id: s}, cast),
    do: ["(#{Cast.render_name(cast, s)} leaves)"]

  defp transcript_line(_, _cast), do: []

  defp addressed(to, cast) when is_list(to) and to != [],
    do: " to #{to |> Enum.map(&Cast.render_name(cast, &1)) |> Enum.join(", ")}"

  defp addressed(_, _cast), do: ""

  defp default_system, do: "You are the Director. Cast and pace the scene."

  # ── Small helpers ────────────────────────────────────────────────────────────

  defp bullets(items), do: Enum.map_join(items, "\n", &"- #{&1}")

  defp compact_join(parts, sep \\ "\n\n") do
    parts
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join(sep)
  end
end

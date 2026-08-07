defmodule Polyphony.Context do
  @moduledoc """
  Assembles a character's per-scene context, ordered **stable → volatile** to
  maximize prefix-cache hits (§9).

  Two phases, matching the refresh cadence in §9:

    * `materialize/1` — run **once at scene open**. Builds the frozen prefix:
      world bible + rules, effective sheet, core facts, retrieved long-tail
      facts, retrieved distant summaries, and verbatim recent scenes. Retrieval
      happens here and only here.
    * `to_messages/2` — run **per packet**. Prepends the frozen prefix unchanged,
      then appends the volatile suffix: scene premise + membership + exits, the
      character's filtered live history, and current state. Growing the history
      is an *append* to the cached prefix, so caching is unaffected (§10).

  Two guarantees are structural here:

    * **Filtered view only (§8, §9).** Live history and verbatim recent scenes
      are passed as *raw* events and filtered through `PolyphonyCore.Visibility`
      inside this module — a caller cannot accidentally feed the omniscient
      transcript and leak whispers or offscreen moves.
    * **The prefix is independent of live history.** `materialize/1` never sees
      the live events, so the cached portion cannot drift turn to turn.
  """

  alias Polyphony.Authoring.{WorldBible, CharacterSheet, BoundaryGate}
  alias Polyphony.Authoring.Knowledge
  alias Polyphony.Authoring.CharacterSheet.Boundary
  alias PolyphonyCore.Content
  alias PolyphonyCore.Content.CampaignConfig
  alias Polyphony.Context.{Rebuild, SceneContext, StaticRetriever}
  alias PolyphonyCore.Scene.Cast
  alias PolyphonyCore.Visibility

  alias PolyphonyCore.Events.{
    ThoughtOccurred,
    PrivateStateReported,
    SpeechUttered,
    ActionTaken,
    DemeanorReported,
    WorldEventOccurred,
    CharacterEntered,
    CharacterExited
  }

  @default_scene_token_budget 6_000

  @doc """
  Materialize the frozen prefix for `character_id` in a scene.

  Required keys: `:scene_id`, `:character_id`, `:sheet` (the **effective** sheet),
  `:premise`. Optional: `:world_bible`, `:cast` (the rest of the campaign's cast as
  `[{character_id, sheet}]` — the source of other people's secrets this character is
  in on, §3.3), `:distant_summaries` (the character's own summaries,
  `[%{scene_id:, text:}]`), `:recent_scenes` (`[%{scene_id:, events:}]` as raw events
  — filtered here), `:retriever`, `:repo`, `:fact_limit`, `:summary_limit`,
  `:scene_token_budget`.
  """
  @spec materialize(keyword() | map()) :: SceneContext.t()
  def materialize(opts) do
    opts = Map.new(opts)
    scene_id = fetch!(opts, :scene_id)
    character_id = fetch!(opts, :character_id)
    sheet = fetch!(opts, :sheet)
    premise = Map.get(opts, :premise)
    location = blank_to_nil(Map.get(opts, :location))

    retriever = Map.get(opts, :retriever, StaticRetriever)
    bible = Map.get(opts, :world_bible)

    # Audience resolution reads live group membership, so it needs the repo the caller
    # is using — and it is asked *here*, at scene open, which is what makes a walk-on
    # written into a group mid-campaign arrive already knowing (§3.3).
    audience_opts = opts |> Map.take([:repo]) |> Map.to_list()

    # What this character starts out knowing that belongs to somebody else: another
    # character's concealed fact whose audience names them. Absent `:cast` there is
    # nothing, which is the default-deny reading — a caller that doesn't supply the
    # cast makes a character know too little, never too much.
    shared_secrets =
      opts
      |> Map.get(:cast, [])
      |> shared_secrets_for(character_id, audience_opts)

    # Content register (§A5): the effective governance register, floor ∩ campaign,
    # computed here so it both frames the prefix and caps the boundary layer below.
    content_config = Map.get(opts, :content_config, %CampaignConfig{})
    register = Content.register(content_config, attested: Map.get(opts, :content_attested, true))

    # Boundaries (§A3 × §A5): first cap each boundary by the register (a category the
    # campaign disabled is forced closed — the ceiling overrides an :open stance),
    # then resolve conditional gates against canon arc **here**, at scene open — arc
    # only changes at scene close, so the resolved state is stable for the scene and
    # frozen into the prefix, re-derived when the next scene opens.
    resolved_boundaries =
      sheet.boundaries
      |> Enum.map(&BoundaryGate.gate_boundary(&1, register))
      |> BoundaryGate.resolve(Map.get(opts, :arc_entries, []),
        evaluator: Map.get(opts, :boundary_evaluator),
        provider: Map.get(opts, :provider),
        model: Map.get(opts, :boundary_model)
      )

    core_facts = CharacterSheet.core_facts(sheet)

    retrieved_facts =
      retriever.rank_facts(
        CharacterSheet.long_tail_facts(sheet),
        premise || "",
        limit: Map.get(opts, :fact_limit)
      )

    # Verbatim recent scenes: filter each to THIS character's view, render, then
    # budget by tokens dropping oldest-first (§9). Keep the set of included
    # scene ids so summaries can be deduped against them.
    {verbatim, verbatim_scene_ids} =
      opts
      |> Map.get(:recent_scenes, [])
      |> render_recent_scenes(character_id)
      |> budget_scenes(Map.get(opts, :scene_token_budget, @default_scene_token_budget))

    retrieved_summaries =
      retriever.fetch_summaries(
        %{character_id: character_id, scene_id: scene_id},
        premise || "",
        limit: Map.get(opts, :summary_limit),
        summaries: Map.get(opts, :distant_summaries, []),
        repo: Map.get(opts, :repo),
        embedder: Map.get(opts, :embedder)
      )
      # Dedup (§9): a scene included verbatim must not also appear as a summary.
      |> Enum.reject(&(&1.scene_id in verbatim_scene_ids))

    prefix =
      [
        render_bible(bible, character_id, audience_opts),
        render_sheet(sheet),
        render_shared_secrets(shared_secrets),
        Content.render_register(register),
        render_boundaries(resolved_boundaries),
        render_facts("Always-resident facts", core_facts),
        render_facts("Facts relevant to this scene", retrieved_facts),
        render_summaries(retrieved_summaries),
        render_verbatim(verbatim)
      ]
      |> compact_join()

    %SceneContext{
      scene_id: scene_id,
      character_id: character_id,
      premise: premise,
      location: location,
      prefix: prefix,
      meta: %{
        verbatim_scene_ids: verbatim_scene_ids,
        retrieved_fact_count: length(retrieved_facts),
        retrieved_summary_count: length(retrieved_summaries)
      }
    }
  end

  @doc """
  Build the full message list for one packet: the frozen prefix, then the
  volatile suffix.

  Options: `:members` (ids present now), `:exits` (available exit labels),
  `:live_events` (raw scene events — filtered here), `:current_state` (rendered
  string), `:turn_instruction`.
  """
  @spec to_messages(SceneContext.t(), keyword() | map()) :: [
          %{role: String.t(), content: String.t()}
        ]
  def to_messages(%SceneContext{} = ctx, opts \\ []) do
    opts = Map.new(opts)

    # Translate stored character ids → display names for the LLM (§5.2). Identity
    # fallback makes a name-keyed scene (tests / pre-migration) a no-op.
    cast = Rebuild.cast_for(ctx.scene_id)

    live =
      opts
      |> Map.get(:live_events, [])
      |> Visibility.project({:character, ctx.character_id})
      |> Enum.map(&render_event(&1, cast))
      |> compact_join("\n")

    volatile =
      [
        render_location(ctx.location),
        render_premise(ctx.premise),
        render_membership(Map.get(opts, :members, []), Map.get(opts, :exits, []), cast),
        section("Scene so far", live),
        section("Current state", Map.get(opts, :current_state)),
        Map.get(opts, :turn_instruction, default_turn_instruction())
      ]
      |> compact_join()

    [
      %{role: "system", content: ctx.prefix},
      %{role: "user", content: volatile}
    ]
  end

  @doc """
  The TurnPacket JSON contract, spelled out (and paired with the provider's JSON mode)
  so the model emits the object we parse rather than free-forming prose. Public so a
  degraded/uncached turn (`BeatOps.messages_for` fallback) can still state the schema —
  otherwise the model, told only "respond with a TurnPacket", invents its own shape.
  """
  def default_turn_instruction do
    """
    It is your turn. Respond with ONLY a single JSON object — no prose, no markdown, no \
    code fences, no reasoning — of exactly this shape:
    {"moves": [{"seq": 1, "type": "thought" | "speech" | "action", "content": "<text>", \
    "addressed_to": ["<name>"], "audibility": "normal" | "private"}],
     "self_state": {"mood_felt": "<...>", "demeanor": "<...>", "intention": "<...>", "position": "<...>"}}
    Order moves by `seq`. Write `action` content in the third person, starting with your \
    own name (e.g. "Lydia reaches out…"), never first person. `addressed_to`/`audibility` \
    apply to speech only (use "private" for a whisper). Omit fields you don't need.\
    """
  end

  # ── Token budgeting (§9: budget by tokens, drop oldest-first) ───────────────

  @doc "Rough token estimate (~4 chars/token). Good enough for budgeting."
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  def estimate_tokens(text) when is_binary(text), do: div(String.length(text), 4) + 1

  # rendered: [{scene_id, text}] oldest-first. Drop from the front until the
  # total fits, so the most recent scenes survive.
  defp budget_scenes(rendered, budget) do
    kept = drop_until_under(rendered, budget)
    {Enum.map(kept, &elem(&1, 1)), Enum.map(kept, &elem(&1, 0))}
  end

  defp drop_until_under(scenes, budget) do
    total = scenes |> Enum.map(fn {_id, text} -> estimate_tokens(text) end) |> Enum.sum()

    if total <= budget or scenes == [] do
      scenes
    else
      scenes |> tl() |> drop_until_under(budget)
    end
  end

  # ── Rendering ───────────────────────────────────────────────────────────────

  defp render_recent_scenes(scenes, character_id) do
    Enum.map(scenes, fn %{scene_id: sid, events: events} ->
      # Each recent scene resolves names against its own cast (§5.2).
      cast = Rebuild.cast_for(sid)

      body =
        events
        |> Visibility.project({:character, character_id})
        |> Enum.map(&render_event(&1, cast))
        |> compact_join("\n")

      {sid, "Scene #{inspect(sid)}:\n" <> body}
    end)
  end

  defp render_bible(nil, _character_id, _opts), do: nil

  # **The character-facing read, and the only one that may be.** `known_to/3` gives
  # the public statements plus the concealed ones this character's audience puts them
  # in on; `statements/1` would hand them the world's secrets wholesale, which is the
  # world-level version of the leak `PolyphonyCore.Visibility` exists to prevent — and it
  # would leak into a *prompt*, where nobody can see it happen. The Director reads the
  # unfiltered list, in `Director.SceneBrief`, because the Director is omniscient.
  defp render_bible(%WorldBible{} = b, character_id, opts) do
    rules = Knowledge.known_to(b.rules, character_id, opts)
    canon = Knowledge.known_to(b.starting_canon, character_id, opts)

    [
      b.name && "World: #{b.name}",
      b.setting && "Setting: #{b.setting}",
      b.tone && "Tone: #{b.tone}",
      rules != [] && "Rules:\n" <> bullets(rules),
      canon != [] && "Canon:\n" <> bullets(canon)
    ]
    |> compact_join()
  end

  defp render_sheet(%CharacterSheet{} = s) do
    [
      s.name && "You are #{s.name}.",
      # Immediately after the name, because it governs every sentence written about
      # them — including the third-person prose the model writes for their actions.
      s.pronouns && "Referred to as #{s.pronouns}.",
      s.premise && s.premise,
      s.appearance && "Appearance: #{s.appearance}",
      s.voice && "Voice: #{s.voice}",
      s.temperament && "Temperament: #{s.temperament}",
      s.backstory && "Backstory: #{s.backstory}",
      s.initial_knowledge != [] && "You know:\n" <> bullets(s.initial_knowledge),
      render_relationships(s.relationships)
    ]
    |> compact_join()
  end

  # Secrets that belong to somebody else and that this character is in on (§3.3).
  #
  # Rendered into the same "You know:" shape `initial_knowledge` uses, because that is
  # exactly what §6.1 says that block is for — *characters must start knowing different
  # things, and that has to be authored.* The audience picker is the authoring; this is
  # the same idea reaching the prompt, so the prompt shape doesn't change.
  #
  # Each line names whose secret it is. A character who starts out knowing that Wren
  # signs for the Kestrel knows it *about Wren*, and a bare statement would read as
  # something true of themselves.
  defp render_shared_secrets([]), do: nil

  defp render_shared_secrets(lines),
    do: "You also know, and are not supposed to:\n" <> bullets(lines)

  # Walk the rest of the cast for concealed facts whose audience names this character.
  # Their *own* facts are not here — those reach them through their sheet, which is
  # where a character's own secrets have always come from.
  defp shared_secrets_for(cast, character_id, opts) do
    me = to_string(character_id)

    for {owner_id, %CharacterSheet{} = sheet} <- cast,
        to_string(owner_id) != me,
        %CharacterSheet.Fact{concealed: true} = fact <- sheet.facts || [],
        Knowledge.knows?(fact.audience, me, Keyword.put(opts, :owner, owner_id)) do
      case sheet.name do
        n when is_binary(n) and n != "" -> "#{n}: #{fact.statement}"
        _ -> fact.statement
      end
    end
  end

  defp render_relationships([]), do: nil

  defp render_relationships(rels) do
    "Relationships:\n" <> bullets(Enum.map(rels, fn r -> "#{r.target}: #{r.descriptor}" end))
  end

  # Boundaries (§A3) — the resolved gate state, framed **in character** so a refusal
  # is generated as a scene beat, not enforced as a filter (§V4.6).
  #
  # Both directions render here. A compulsion is the same gate with the sign flipped
  # — held means she can't stop rather than she won't — and it is written that way
  # rather than as a negated refusal, because a model handed "you will not not do
  # this" writes a worse beat than one handed "you can't help it".
  defp render_boundaries([]), do: nil

  defp render_boundaries(resolved) do
    "Where you can be pushed (what happens here is you being yourself — a scene beat, " <>
      "not a rule):\n" <> bullets(Enum.map(resolved, &boundary_line/1))
  end

  defp boundary_line(%{boundary: %Boundary{stance: :open, topic: t, direction: :compulsion}}),
    do: "#{t}: you do this freely."

  defp boundary_line(%{boundary: %Boundary{stance: :open, topic: t}}),
    do: "#{t}: you are open to this."

  defp boundary_line(%{
         boundary: %Boundary{stance: :closed, topic: t, direction: :compulsion, on_pressure: p}
       }),
       do: "#{t}: you always do this — you can't help it.#{resisted(p)}"

  defp boundary_line(%{boundary: %Boundary{stance: :closed, topic: t, on_pressure: p}}),
    do: "#{t}: a hard line — you will not.#{on_pressure(p)}"

  defp boundary_line(%{
         boundary: %Boundary{stance: :conditional, topic: t, condition: c} = b,
         released: true
       }) do
    case b.direction do
      :compulsion ->
        "#{t}: you couldn't stop until #{c}; that has happened, and it no longer holds you." <>
          after_release(b.after_release)

      _ ->
        "#{t}: you held back until #{c}; that has happened, so you are open to it now." <>
          after_release(b.after_release)
    end
  end

  defp boundary_line(%{
         boundary: %Boundary{stance: :conditional, topic: t, condition: c} = b,
         released: false
       }) do
    case b.direction do
      # The after-state is deliberately absent while it holds: she isn't told what
      # she'll be like afterwards until it's true of her, or she plays it early.
      :compulsion ->
        "#{t}: you can't stop — not until #{c}, and that has not happened.#{resisted(b.on_pressure)}"

      _ ->
        "#{t}: you will not — not until #{c}, and that has not happened.#{on_pressure(b.on_pressure)}"
    end
  end

  defp boundary_line(%{boundary: %Boundary{topic: t, direction: :compulsion}}),
    do: "#{t}: you keep doing this."

  defp boundary_line(%{boundary: %Boundary{topic: t}}), do: "#{t}: you hold back here."

  defp on_pressure(p) when p in [nil, ""], do: ""
  defp on_pressure(p), do: " When pushed: #{p}"

  defp resisted(p) when p in [nil, ""], do: ""
  defp resisted(p), do: " When someone tries to stop you: #{p}"

  defp after_release(a) when a in [nil, ""], do: ""
  defp after_release(a), do: " Since then: #{a}"

  defp render_facts(_label, []), do: nil
  defp render_facts(label, facts), do: "#{label}:\n" <> bullets(Enum.map(facts, & &1.statement))

  defp render_summaries([]), do: nil

  defp render_summaries(summaries),
    do: "Earlier (summarized):\n" <> compact_join(Enum.map(summaries, & &1.text), "\n")

  defp render_verbatim([]), do: nil
  defp render_verbatim(scenes), do: "Recent scenes:\n" <> compact_join(scenes, "\n\n")

  defp render_premise(nil), do: nil
  defp render_premise(premise), do: "Scene: #{premise}"

  # Authored scene location (§2.3), volatile like the premise. The Director should be
  # told where a scene takes place, not left to infer it. Labelled "Location" to stay
  # distinct from the world bible's overall "Setting".
  defp render_location(nil), do: nil
  defp render_location(location), do: "Location: #{location}"

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_to_nil(v), do: v

  defp render_membership(members, exits, cast) do
    names = Enum.map(members, &Cast.render_name(cast, &1))

    [
      names != [] && "Present: #{Enum.join(names, ", ")}",
      exits != [] && "Exits: #{Enum.join(exits, ", ")}"
    ]
    |> compact_join()
  end

  # Event rendering. Interior events only ever appear here for the viewer whose
  # they are (Visibility already filtered), so it's safe to render them. `cast`
  # translates stored character ids → display names for the LLM (§5.2).
  defp render_event(%ThoughtOccurred{} = e, _cast), do: "(you think: #{e.content})"

  defp render_event(%PrivateStateReported{} = e, _cast),
    do: "(you feel #{e.mood_felt || "—"}; you intend #{e.intention || "—"})"

  defp render_event(%SpeechUttered{} = e, cast) do
    to =
      if e.addressed_to in [nil, []] do
        ""
      else
        " (to #{e.addressed_to |> Enum.map(&Cast.render_name(cast, &1)) |> Enum.join(", ")})"
      end

    whisper = if e.audibility == :private, do: " (whispered)", else: ""
    "#{Cast.render_name(cast, e.speaker_id)}#{to}#{whisper}: \"#{e.content}\""
  end

  defp render_event(%ActionTaken{} = e, cast),
    do: "#{Cast.render_name(cast, e.character_id)} #{e.content}"

  defp render_event(%DemeanorReported{} = e, cast) do
    bits = [e.demeanor, e.posture, e.position] |> Enum.reject(&is_nil/1) |> Enum.join(", ")
    "[#{Cast.render_name(cast, e.character_id)}: #{bits}]"
  end

  defp render_event(%WorldEventOccurred{} = e, _cast), do: "[#{e.content}]"

  defp render_event(%CharacterEntered{} = e, cast),
    do: "[#{Cast.render_name(cast, e.character_id)} enters]"

  defp render_event(%CharacterExited{} = e, cast),
    do: "[#{Cast.render_name(cast, e.character_id)} leaves]"

  defp render_event(_other, _cast), do: nil

  # ── Small helpers ────────────────────────────────────────────────────────────

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> raise ArgumentError, "Context.materialize missing required key: #{inspect(key)}"
    end
  end

  defp section(_label, content) when content in [nil, ""], do: nil
  defp section(label, content), do: "#{label}:\n#{content}"

  defp bullets(items), do: Enum.map_join(items, "\n", &"- #{&1}")

  defp compact_join(parts, sep \\ "\n\n") do
    parts
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join(sep)
  end
end

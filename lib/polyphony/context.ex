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
      are passed as *raw* events and filtered through `Polyphony.Visibility`
      inside this module — a caller cannot accidentally feed the omniscient
      transcript and leak whispers or offscreen moves.
    * **The prefix is independent of live history.** `materialize/1` never sees
      the live events, so the cached portion cannot drift turn to turn.
  """

  alias Polyphony.Authoring.{WorldBible, CharacterSheet, BoundaryGate}
  alias Polyphony.Authoring.CharacterSheet.Boundary
  alias Polyphony.Content
  alias Polyphony.Content.CampaignConfig
  alias Polyphony.Context.{SceneContext, StaticRetriever}
  alias Polyphony.Visibility

  alias Polyphony.Events.{
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
  `:premise`. Optional: `:world_bible`, `:distant_summaries` (the character's own
  summaries, `[%{scene_id:, text:}]`), `:recent_scenes` (`[%{scene_id:, events:}]`
  as raw events — filtered here), `:retriever`, `:fact_limit`, `:summary_limit`,
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
      |> Enum.map(&Content.gate_boundary(&1, register))
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
        render_bible(bible),
        render_sheet(sheet),
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

    live =
      opts
      |> Map.get(:live_events, [])
      |> Visibility.project({:character, ctx.character_id})
      |> Enum.map(&render_event(&1, ctx.character_id))
      |> compact_join("\n")

    volatile =
      [
        render_location(ctx.location),
        render_premise(ctx.premise),
        render_membership(Map.get(opts, :members, []), Map.get(opts, :exits, [])),
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
      body =
        events
        |> Visibility.project({:character, character_id})
        |> Enum.map(&render_event(&1, character_id))
        |> compact_join("\n")

      {sid, "Scene #{inspect(sid)}:\n" <> body}
    end)
  end

  defp render_bible(nil), do: nil

  defp render_bible(%WorldBible{} = b) do
    rules = if b.rules == [], do: nil, else: "Rules:\n" <> bullets(b.rules)

    [
      b.name && "World: #{b.name}",
      b.setting && "Setting: #{b.setting}",
      b.tone && "Tone: #{b.tone}",
      rules,
      b.starting_canon != [] && "Canon:\n" <> bullets(b.starting_canon)
    ]
    |> compact_join()
  end

  defp render_sheet(%CharacterSheet{} = s) do
    [
      s.name && "You are #{s.name}.",
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

  defp render_relationships([]), do: nil

  defp render_relationships(rels) do
    "Relationships:\n" <> bullets(Enum.map(rels, fn r -> "#{r.target}: #{r.descriptor}" end))
  end

  # Boundaries (§A3) — the resolved gate state, framed **in character** so a refusal
  # is generated as a scene beat, not enforced as a filter (§V4.6).
  defp render_boundaries([]), do: nil

  defp render_boundaries(resolved) do
    "Your boundaries (a refusal here is you being yourself — a scene beat, not a rule):\n" <>
      bullets(Enum.map(resolved, &boundary_line/1))
  end

  defp boundary_line(%{boundary: %Boundary{stance: :open, topic: t}}),
    do: "#{t}: you are open to this."

  defp boundary_line(%{boundary: %Boundary{stance: :closed, topic: t, on_pressure: p}}),
    do: "#{t}: a hard line — you will not.#{on_pressure(p)}"

  defp boundary_line(%{
         boundary: %Boundary{stance: :conditional, topic: t, condition: c},
         released: true
       }),
       do: "#{t}: you held back until #{c}; that has happened, so you are open to it now."

  defp boundary_line(%{
         boundary: %Boundary{stance: :conditional, topic: t, condition: c, on_pressure: p},
         released: false
       }),
       do: "#{t}: you will not — not until #{c}, and that has not happened.#{on_pressure(p)}"

  defp boundary_line(%{boundary: %Boundary{topic: t}}), do: "#{t}: you hold back here."

  defp on_pressure(p) when p in [nil, ""], do: ""
  defp on_pressure(p), do: " When pushed: #{p}"

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

  defp render_membership(members, exits) do
    [
      members != [] && "Present: #{Enum.join(members, ", ")}",
      exits != [] && "Exits: #{Enum.join(exits, ", ")}"
    ]
    |> compact_join()
  end

  # Event rendering. Interior events only ever appear here for the viewer whose
  # they are (Visibility already filtered), so it's safe to render them.
  defp render_event(%ThoughtOccurred{} = e, _me), do: "(you think: #{e.content})"

  defp render_event(%PrivateStateReported{} = e, _me),
    do: "(you feel #{e.mood_felt || "—"}; you intend #{e.intention || "—"})"

  defp render_event(%SpeechUttered{} = e, _me) do
    to = if e.addressed_to in [nil, []], do: "", else: " (to #{Enum.join(e.addressed_to, ", ")})"
    whisper = if e.audibility == :private, do: " (whispered)", else: ""
    "#{e.speaker_id}#{to}#{whisper}: \"#{e.content}\""
  end

  defp render_event(%ActionTaken{} = e, _me), do: "#{e.character_id} #{e.content}"

  defp render_event(%DemeanorReported{} = e, _me) do
    bits = [e.demeanor, e.posture, e.position] |> Enum.reject(&is_nil/1) |> Enum.join(", ")
    "[#{e.character_id}: #{bits}]"
  end

  defp render_event(%WorldEventOccurred{} = e, _me), do: "[#{e.content}]"
  defp render_event(%CharacterEntered{} = e, _me), do: "[#{e.character_id} enters]"
  defp render_event(%CharacterExited{} = e, _me), do: "[#{e.character_id} leaves]"
  defp render_event(_other, _me), do: nil

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

defmodule Polyphony.Authoring.QuickBuild do
  @moduledoc """
  One-shot scaffolding for a whole campaign (§15, authoring aid) — the "Quick Build"
  button on the campaign editor. From a world seed and one seed per character it:

    1. generates a **world bible** (like ✨ Generate-all on the bible editor),
    2. generates each **character** grounded in that world (✨ Generate-all, status
       `:full`, linked to the bible),
    3. cross-links the cast — every character gets a directional relationship toward
       each other one (`Autofill.regard_map`, so the regards are asymmetrical),
    4. optionally **stubs off-screen people** — with `:suggest_offscreen`, each
       character also gets AI-suggested relationships (mentors, rivals, family), the
       new names created as pending stubs (§B8) exactly as the sheet editor does on
       save, and
    5. drafts a **campaign premise** grounded in the world and cast.

  Everything is persisted to the author's `Library` as ordinary owned entries — the
  same kinds the editors produce — so each can be opened and fleshed out afterwards.
  It's a stateless orchestrator over `Autofill` + `Library`; the LiveView owns the
  async/UI and attaches the results (bible id, character ids, premise) to the campaign.

  Returns `{:ok, %{bible: entry, characters: [entry], premise: string, failed: [...]}}` —
  `characters` is the **main cast** (stubs land in the library but aren't in the campaign
  roster); `failed` is a list of `{seed, reason}` for any character seed the provider
  couldn't generate. A single character failing does **not** abort the build — the world,
  the characters that succeeded, and the premise are kept, and the failures are surfaced
  so the author can retry just those. The build only errors outright if *every* character
  seed fails (or the world / premise call does). Provider and usage-attribution opts
  (`:provider`, `:user_id`, `:campaign_id`) pass straight through to the metered LLM calls.
  """

  alias Polyphony.Library
  alias Polyphony.Authoring.{Autofill, CharacterSheet, Stub, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.{Boundary, Relationship}

  @doc """
  Build a world, a cast, and a premise from seeds. `opts`:

    * `:owner` — the `%Owner{}` (required); every entry is stored under it.
    * `:world_seed` — free-text brief for the world (may be blank).
    * `:character_seeds` — a list of free-text briefs, one per character.
    * `:suggest_offscreen` — also stub AI-suggested off-screen people per character
      (default `false`).
    * `:progress` — an optional 1-arg fn called with `%{done, total, label}` before each
      phase (world → each character → linking → premise), for a UI progress bar.
    * `:provider` / `:user_id` / `:campaign_id` — metering passthrough.
  """
  @spec build(keyword()) :: {:ok, map()} | {:error, term()}
  def build(opts) do
    owner = Keyword.fetch!(opts, :owner)
    world_seed = to_string(opts[:world_seed] || "")
    # One character per provided seed — a blank seed is kept, generating a character
    # freely from the world rather than dropping the row.
    seeds = opts[:character_seeds] |> List.wrap() |> Enum.map(&to_string/1)
    suggest? = Keyword.get(opts, :suggest_offscreen, false)
    meter = Keyword.take(opts, [:provider, :user_id, :campaign_id])

    # Phases: the world, one per character, linking the cast, the premise.
    report = progress_fn(Keyword.get(opts, :progress), length(seeds) + 3)
    report.(0, "Dreaming up the world")

    # The **world** is the only hard requirement — with nothing to attach, there's no
    # build. Once it exists, every later step degrades rather than aborts (a failed
    # character is reported, a failed premise falls back to blank), so the caller always
    # gets the world + whatever cast succeeded to associate with the campaign. Previously
    # a late failure (e.g. the premise call) discarded the whole result even though the
    # world and characters were already persisted.
    case Autofill.generate_all(:world_bible, world_seed, %{}, meter) do
      {:error, reason} ->
        {:error, {:world_failed, reason}}

      {:ok, world_fields} ->
        bible_entry = put(owner, "world_bible", to_world_bible(world_fields))
        world_ctx = world_context(world_fields)

        {char_entries, failed} =
          build_characters(owner, seeds, bible_entry.id, world_ctx, meter, report)

        report.(length(seeds) + 1, "Connecting the cast")
        char_entries = wire_cast(char_entries, suggest?, bible_entry.id, owner, meter)

        report.(length(seeds) + 2, "Framing the premise")
        premise = build_premise(world_ctx, char_entries, meter)

        report.(length(seeds) + 3, "Done")
        {:ok, %{bible: bible_entry, characters: char_entries, premise: premise, failed: failed}}
    end
  end

  # Best-effort premise: a provider failure falls back to blank rather than sinking the
  # whole build (the author can ✨ Expand it on the campaign screen afterward).
  defp build_premise(world_ctx, char_entries, meter) do
    case Autofill.generate_campaign_premise(
           [world: world_ctx, cast: cast_summaries(char_entries)] ++ meter
         ) do
      {:ok, premise} -> premise
      {:error, _} -> ""
    end
  end

  # Wrap an optional `%{done, total, label}` callback into a `(done, label)` reporter
  # (no-op when absent), so the build body just calls `report.(done, "…")` per phase.
  defp progress_fn(nil, _total), do: fn _done, _label -> :ok end

  defp progress_fn(fun, total) when is_function(fun, 1) do
    fn done, label ->
      fun.(%{done: done, total: total, label: label})
      :ok
    end
  end

  # Generate each character, keeping the ones that succeed and collecting `{seed, reason}`
  # for the ones that don't — a blank result (valid response, no usable fields) counts as
  # a failure too. Always returns `{entries, failed}`: even if every character fails, the
  # world it belongs to is still built and associated, and the failures are reported.
  defp build_characters(owner, seeds, bible_id, world_ctx, meter, report) do
    n = length(seeds)

    seeds
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {seed, i}, {ok, bad} ->
      report.(1 + i, "Writing character #{i + 1} of #{n}")
      brief = brief_with_roster(seed, seeds, i)

      case Autofill.generate_all(:character, brief, %{}, [world: world_ctx] ++ meter) do
        {:ok, fields} when map_size(fields) > 0 ->
          sheet = %CharacterSheet{
            to_character_sheet(fields, bible_id)
            | boundaries: gen_boundaries(fields, world_ctx, meter)
          }

          {ok ++ [put(owner, "character", sheet)], bad}

        {:ok, _empty} ->
          {ok, bad ++ [{seed, :blank_generation}]}

        {:error, reason} ->
          {ok, bad ++ [{seed, reason}]}
      end
    end)
  end

  # Ground each character in the rest of the ensemble so a relationship the seed states
  # ("secretly in love with Jack") is honored rather than rationalized away by a model
  # that has no idea Jack is a castmate. The character's own seed stays primary; the
  # others are context.
  defp brief_with_roster(seed, seeds, i) do
    case seeds |> List.delete_at(i) |> Enum.reject(&(String.trim(&1) == "")) do
      [] ->
        seed

      others ->
        seed <>
          "\n\nEnsemble context — this character shares the story with: " <>
          Enum.map_join(others, "; ", & &1) <>
          ". If this character's own description above names or implies a relationship, " <>
          "attraction, or history with any of them, honor it exactly — do not soften, " <>
          "professionalize, or rewrite it."
    end
  end

  # Boundaries, the same way the sheet editor's "Generate all fields" does — via
  # `Autofill.suggest_boundaries`, grounded in the just-generated fields and the world.
  # Best-effort: a failed suggestion leaves the character with no boundaries rather than
  # failing the build (the author can add them by hand or ✨ Suggest in the editor).
  defp gen_boundaries(fields, world_ctx, meter) do
    case Autofill.suggest_boundaries(fields, [world: world_ctx] ++ meter) do
      {:ok, list} -> Enum.map(list, &Boundary.from_map/1)
      {:error, _} -> []
    end
  end

  # Wire each character's relationships: a directional link toward every other built
  # character (with an asymmetrical regard and the target's stable id set), plus —
  # when `suggest?` — AI-suggested off-screen people stubbed like the sheet editor does
  # on save. A `stubs` registry (normalized name → id) is threaded across the cast so
  # an off-screen person two characters both name collapses into ONE shared stub that
  # links back to each of them. Best-effort per character: a failed call leaves that
  # character less-linked rather than aborting the whole build.
  defp wire_cast(entries, suggest?, bible_id, owner, meter) do
    named = Enum.map(entries, fn e -> {e, Library.payload(e)} end)
    cast_names = MapSet.new(for {_e, s} <- named, present?(s.name), do: norm(s.name))

    {updated, _stubs} =
      Enum.reduce(named, {[], %{}}, fn {entry, sheet}, {acc, stubs} ->
        others = for {o, os} <- named, o.id != entry.id, do: {o.id, os.name}
        cast_rels = if others == [], do: [], else: cast_regards(sheet, others, meter)

        {offscreen, stubs} =
          if suggest?,
            do:
              suggest_and_stub(
                entry.id,
                sheet,
                cast_rels,
                cast_names,
                bible_id,
                owner,
                meter,
                stubs
              ),
            else: {[], stubs}

        entry =
          case cast_rels ++ offscreen do
            [] ->
              entry

            rels ->
              {:ok, u} =
                Library.update_payload(entry.id, %CharacterSheet{sheet | relationships: rels})

              u
          end

        {[entry | acc], stubs}
      end)

    Enum.reverse(updated)
  end

  defp cast_regards(sheet, others, meter) do
    names = Enum.map(others, fn {_id, name} -> name end)
    source = %{"name" => sheet.name, "premise" => sheet.premise}

    regard =
      case Autofill.regard_map(source, names, meter) do
        {:ok, map} -> map
        {:error, _} -> %{}
      end

    for {id, name} <- others do
      %Relationship{target: name, target_id: id, descriptor: Map.get(regard, name, "")}
    end
  end

  # Ask for off-screen relationships and stub the new people (§B8). Cast members are
  # excluded (passed as `existing`, and belt-and-suspenders filtered by name), so this
  # only ever creates genuinely new stubs. Returns `{outbound_rels, stubs}` — the
  # updated registry so later characters reuse a stub already created for the same name.
  defp suggest_and_stub(self_id, sheet, cast_rels, cast_names, bible_id, owner, meter, stubs) do
    current = %{
      "name" => sheet.name,
      "premise" => sheet.premise,
      "temperament" => sheet.temperament,
      "backstory" => sheet.backstory
    }

    case Autofill.suggest_relationships(current, [existing: cast_rels] ++ meter) do
      {:ok, suggestions} ->
        suggestions
        |> Enum.reject(
          &(norm(&1["target"]) == "" or MapSet.member?(cast_names, norm(&1["target"])))
        )
        |> Enum.reduce({[], stubs}, fn s, {rels, stubs} ->
          {stub_id, stubs} = resolve_stub(s, self_id, sheet.name, bible_id, owner, stubs)

          rel = %Relationship{
            target: s["target"],
            target_id: stub_id,
            descriptor: s["descriptor"]
          }

          {rels ++ [rel], stubs}
        end)

      {:error, _} ->
        {[], stubs}
    end
  end

  # Reuse an existing stub for this name (appending the new inbound regard), or create
  # one. Each stub carries the inbound relationship back toward the introducing
  # character, seeded with the source's regard as a placeholder — the same pre-reciprocal
  # state the editor produces before its async reciprocal pass.
  defp resolve_stub(s, self_id, self_name, bible_id, owner, stubs) do
    inbound = %Relationship{
      target: self_name,
      target_id: self_id,
      descriptor: s["descriptor"],
      reciprocal: s["descriptor"]
    }

    case Map.get(stubs, norm(s["target"])) do
      nil ->
        stub =
          put(
            owner,
            "character",
            Stub.new(s["target"], s["descriptor"],
              relationships: [inbound],
              world_bible_id: bible_id
            )
          )

        {stub.id, Map.put(stubs, norm(s["target"]), stub.id)}

      id ->
        append_inbound(id, inbound)
        {id, stubs}
    end
  end

  # Append an inbound relationship to an already-created stub, unless one from that same
  # character is already present (idempotent).
  defp append_inbound(id, inbound) do
    with entry when not is_nil(entry) <- Library.get(id),
         %CharacterSheet{} = sheet <- Library.payload(entry),
         rels <- sheet.relationships || [],
         false <- Enum.any?(rels, &(&1.target_id == inbound.target_id)) do
      Library.update_payload(id, %CharacterSheet{sheet | relationships: rels ++ [inbound]})
    end
  end

  defp norm(name), do: name |> to_string() |> String.trim() |> String.downcase()

  defp present?(v), do: is_binary(v) and String.trim(v) != ""

  defp cast_summaries(entries) do
    for e <- entries do
      s = Library.payload(e)
      %{"name" => s.name, "premise" => s.premise}
    end
  end

  # ── Field → domain struct ─────────────────────────────────────────────────────

  defp to_world_bible(fields) do
    %WorldBible{
      name: fields["name"],
      setting: fields["setting"],
      tone: fields["tone"],
      rules: lines(fields["rules"]),
      starting_canon: lines(fields["starting_canon"])
    }
  end

  defp to_character_sheet(fields, bible_id) do
    %CharacterSheet{
      name: fields["name"],
      premise: fields["premise"],
      appearance: fields["appearance"],
      voice: fields["voice"],
      temperament: fields["temperament"],
      backstory: fields["backstory"],
      status: :full,
      world_bible_id: bible_id
    }
  end

  # The world display map Autofill grounds character/premise generation in — the same
  # shape the editors pass (list fields joined by newlines).
  defp world_context(fields) do
    %{
      "name" => fields["name"] || "",
      "setting" => fields["setting"] || "",
      "tone" => fields["tone"] || "",
      "rules" => fields["rules"] || "",
      "starting_canon" => fields["starting_canon"] || ""
    }
  end

  defp lines(nil), do: []

  defp lines(str) when is_binary(str),
    do: str |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp lines(list) when is_list(list), do: list

  defp put(owner, kind, payload),
    do: Library.put(%{owner: owner, kind: kind, payload: payload})
end

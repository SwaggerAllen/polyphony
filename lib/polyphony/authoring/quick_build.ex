defmodule Polyphony.Authoring.QuickBuild do
  @moduledoc """
  One-shot scaffolding for a whole campaign (§15, authoring aid) — the "Quick Build"
  button on the campaign editor. From a world seed and one seed per character it:

    1. generates a **world bible** (like ✨ Generate-all on the bible editor), told who
       is about to be cast so it doesn't name them first,
    2. generates each **character** in turn, grounded in that world **and the cast built
       so far** — the earlier characters' sheets and the off-screen people they
       introduced — so shared world detail stays consistent instead of each character
       independently inventing its own (status `:full`, linked to the bible),
    3. optionally **stubs off-screen people** as it goes — with `:suggest_offscreen`,
       each character gets AI-suggested relationships (mentors, rivals, family) created
       as pending stubs (§B8); because they're made during generation, a later character
       can reuse one instead of inventing a duplicate,
    4. cross-links the cast — every character gets a directional regard toward each other
       one (`Autofill.regard_map`, asymmetrical), and
    5. drafts a **campaign premise** grounded in the world and cast, and
    6. writes a **cover** for the world and for each character — last, because a cover
       is written *from* everything else and is the only part a stranger reads before
       taking either (§2.12).

  Everything is persisted to the author's `Library` as ordinary owned entries — the
  same kinds the editors produce — so each can be opened and fleshed out afterwards.
  It's a stateless orchestrator over `Autofill` + `Library`; `Polyphony.Jobs.QuickBuild`
  runs it and owns the association, reporting phases through `:progress` and each
  persisted entry through `:on_entry` as it goes. That second callback matters more than
  it looks: this function writes to the library long before it returns, so a caller that
  associates only from the return value strands everything built by a run that doesn't
  finish.

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
  alias Polyphony.Authoring.{Autofill, CharacterSheet, Cover, Stub, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.{Boundary, Fact, Relationship}

  @doc """
  Build a world, a cast, and a premise from seeds. `opts`:

    * `:owner` — the `%Owner{}` (required); every entry is stored under it.
    * `:world_seed` — free-text brief for the world (may be blank).
    * `:character_seeds` — a list of free-text briefs, one per character.
    * `:suggest_offscreen` — also stub AI-suggested off-screen people per character
      (default `false`).
    * `:progress` — an optional 1-arg fn called with `%{done, total, label}` before each
      phase (world → each character → linking → premise → covers), for a UI progress bar.
    * `:on_entry` — an optional 1-arg fn called with `{:world, entry}` / `{:character,
      entry}` the moment each is persisted, *before* the phases that follow it. The
      caller uses it to associate as the build goes. This is not an optimisation: the
      build writes to the library long before it returns, so a caller that associates
      only from the return value leaves a world and a cast attached to nothing whenever
      the build doesn't finish — and it doesn't have to crash to not finish, it only has
      to be interrupted. Reporting is best-effort; a raising callback doesn't sink the
      build.
    * `:resume` — `%{bible: entry | nil, done: [seed_index], characters: [entry]}`, for a
      retry. A build that is picked up again uses the world it already wrote, skips the
      seeds whose characters exist, and carries those characters into the linking,
      premise and cover phases as if it had just written them. Without it a retry would
      re-run every provider call, charge for them again, and leave the campaign with two
      worlds and two casts — which is why the job used to refuse to retry at all.
    * `:on_seed_done` — a 1-arg fn called with the seed index the moment that character
      is **persisted**, so a resume knows exactly which seeds not to repeat. Recorded at
      the write rather than at the end of the seed, because that is the boundary a crash
      can fall either side of.
    * `:provider` / `:user_id` / `:campaign_id` — metering passthrough.
  """
  @spec build(keyword()) :: {:ok, map()} | {:error, term()}
  def build(opts) do
    owner = Keyword.fetch!(opts, :owner)
    announce = announcer(opts[:on_entry])
    seed_done = announcer(opts[:on_seed_done])
    resume = opts[:resume] || %{}
    world_seed = to_string(opts[:world_seed] || "")
    # One character per provided seed — a blank seed is kept, generating a character
    # freely from the world rather than dropping the row.
    seeds = opts[:character_seeds] |> List.wrap() |> Enum.map(&to_string/1)
    suggest? = Keyword.get(opts, :suggest_offscreen, false)
    meter = Keyword.take(opts, [:provider, :user_id, :campaign_id])

    # Phases: the world, one per character, linking the cast, the premise, the covers.
    report = progress_fn(Keyword.get(opts, :progress), length(seeds) + 4)
    report.(0, "Dreaming up the world")

    # The **world** is the only hard requirement — with nothing to attach, there's no
    # build. Once it exists, every later step degrades rather than aborts (a failed
    # character is reported, a failed premise falls back to blank), so the caller always
    # gets the world + whatever cast succeeded to associate with the campaign. Previously
    # a late failure (e.g. the premise call) discarded the whole result even though the
    # world and characters were already persisted.
    #
    # It is written **knowing who is about to be cast** (`cast_seeds`). Written from the
    # world seed alone it has no idea, so a world that needs a harbour-master invents
    # one and names her into `starting_canon` — and the very next phase generates that
    # same seed as a character with a different name. The campaign opens with two of
    # her, and the author's first job is a rename nobody asked for.
    case world(owner, world_seed, seeds, meter, resume[:bible], announce) do
      {:error, reason} ->
        {:error, {:world_failed, reason}}

      {:ok, bible_entry, world_ctx} ->
        {char_entries, failed} =
          generate_cast(
            owner,
            seeds,
            bible_entry.id,
            world_ctx,
            suggest?,
            meter,
            report,
            announce,
            seed_done,
            resume
          )

        report.(length(seeds) + 1, "Connecting the cast")
        char_entries = interlink_cast(char_entries, meter)

        report.(length(seeds) + 2, "Framing the premise")
        premise = build_premise(world_ctx, char_entries, meter)

        # Last, because a cover is written *from* everything else — a world's rules and
        # canon, a character's facts — and is the only part a stranger reads before
        # taking either. Written here rather than left for the author because the
        # alternative is a library full of things with no blurb, which is what
        # "published" looks like when nobody went back and wrote one.
        report.(length(seeds) + 3, "Writing the covers")
        bible_entry = write_cover(bible_entry, meter)
        char_entries = Enum.map(char_entries, &write_cover(&1, meter))

        report.(length(seeds) + 4, "Done")
        {:ok, %{bible: bible_entry, characters: char_entries, premise: premise, failed: failed}}
    end
  end

  # The world, written or already written. A resumed build has one — it was associated
  # the moment it existed — so the context it grounds everything else in is rebuilt from
  # the stored bible rather than paid for a second time.
  defp world(_owner, _seed, _seeds, _meter, %{} = existing, _announce) when is_map(existing) do
    bible = Library.payload(existing)
    {:ok, existing, world_context(from_bible(bible))}
  end

  defp world(owner, world_seed, seeds, meter, _none, announce) do
    case Autofill.generate_all(:world_bible, world_seed, %{}, [cast_seeds: seeds] ++ meter) do
      {:error, reason} ->
        {:error, reason}

      {:ok, world_fields} ->
        entry = put(owner, "world_bible", to_world_bible(world_fields))
        announce.({:world, entry})
        {:ok, entry, world_context(world_fields)}
    end
  end

  # A stored bible back into the flat `%{"field" => text}` shape generation grounds on.
  defp from_bible(%WorldBible{} = bible) do
    %{
      "name" => bible.name,
      "setting" => bible.setting,
      "tone" => bible.tone,
      "rules" => Enum.map_join(WorldBible.entries(bible.rules), "\n", & &1.statement),
      "starting_canon" =>
        Enum.map_join(WorldBible.entries(bible.starting_canon), "\n", & &1.statement)
    }
  end

  defp from_bible(other), do: %{"name" => Map.get(other || %{}, :name) || ""}

  # Best-effort, one entry at a time: a cover is the last thing written and the least
  # load-bearing, so a provider failure — or `{:error, :leaked}`, which is `Cover`
  # refusing to ship a blurb that quoted a secret — leaves the entry exactly as it was.
  # An empty cover is a prompt on the editor; a wrong one is a spoiler.
  defp write_cover(entry, meter) do
    subject = Library.payload(entry)

    # A resumed build reaches this phase with some covers already written; they're the
    # most expensive thing here per unit of value, so an existing one stands.
    if present?(Map.get(subject, :cover)) do
      entry
    else
      regenerate_cover(entry, subject, meter)
    end
  end

  defp regenerate_cover(entry, subject, meter) do
    case Cover.generate(subject, meter) do
      {:ok, prose} ->
        case Library.update_payload(entry.id, %{subject | cover: prose}) do
          {:ok, updated} -> updated
          _ -> entry
        end

      {:error, _reason} ->
        entry
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

  # A no-op when no `:on_entry` was given, and swallowing its exceptions when there is
  # one: the callback exists so a caller can associate what has been built, and the
  # build is worth less, not more, if a failure to *report* a world also destroys it.
  defp announcer(nil), do: fn _ -> :ok end

  defp announcer(fun) when is_function(fun, 1) do
    fn event ->
      try do
        fun.(event)
        :ok
      rescue
        _ -> :ok
      end
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

  # Generate each character in order, GROUNDED in the cast built so far — the earlier
  # characters' sheets and the off-screen stubs they introduced. That shared context is
  # what stops every character from independently inventing (say) a different landlord for
  # the same building: a person one character established is visible to the next, so names
  # line up and the stub registry collapses them into one. Off-screen stubs are created
  # here (not in a later pass) precisely so they're available to subsequent characters.
  #
  # Keeps the ones that succeed and collects `{seed, reason}` for the ones that don't (a
  # blank result counts as a failure). Always returns `{entries, failed}` — even a fully
  # failed cast still leaves the world built and associated.
  defp generate_cast(
         owner,
         seeds,
         bible_id,
         world_ctx,
         suggest?,
         meter,
         report,
         announce,
         seed_done,
         resume
       ) do
    n = length(seeds)
    done = MapSet.new(resume[:done] || [])

    # A resumed build carries the characters it already wrote into the walk, so the next
    # one is still grounded in the ensemble — the whole reason the cast is generated in
    # order rather than in parallel.
    start = for e <- resume[:characters] || [], do: {e, Library.payload(e)}

    {built, _stubs, failed} =
      seeds
      |> Enum.with_index()
      |> Enum.reduce({start, %{}, []}, fn {seed, i}, {built, stubs, failed} ->
        if MapSet.member?(done, i) do
          {built, stubs, failed}
        else
          report.(1 + i, "Writing character #{i + 1} of #{n}")
          brief = brief_with_roster(seed, seeds, i)
          opts = [world: world_ctx, relations: cast_relations(built, stubs)] ++ meter

          case Autofill.generate_all(:character, brief, %{}, opts) do
            {:ok, fields} when map_size(fields) > 0 ->
              sheet = %CharacterSheet{
                to_character_sheet(fields, bible_id)
                | boundaries: gen_boundaries(fields, world_ctx, meter)
              }

              entry = put(owner, "character", sheet)

              # Both callbacks fire here, at the write, and that placement is the thing
              # that makes a retry safe: a crash on either side of this line resolves
              # correctly — after it the seed is skipped, before it the seed is redone,
              # and neither produces two of the same character.
              announce.({:character, entry})
              seed_done.(i)

              {entry, stubs} =
                maybe_stub_offscreen(entry, sheet, built, suggest?, bible_id, owner, meter, stubs)

              {built ++ [{entry, sheet}], stubs, failed}

            {:ok, _empty} ->
              {built, stubs, failed ++ [{seed, :blank_generation}]}

            {:error, reason} ->
              {built, stubs, failed ++ [{seed, reason}]}
          end
        end
      end)

    {Enum.map(built, &elem(&1, 0)), failed}
  end

  # Off-screen relationships for a just-generated character, stubbed and persisted now so
  # later characters see them. Prior main cast are excluded from suggestions (they're real
  # characters, not off-screen stubs). Returns the (possibly-updated) entry + the grown
  # stub registry.
  defp maybe_stub_offscreen(entry, _sheet, _built, false, _bible_id, _owner, _meter, stubs),
    do: {entry, stubs}

  defp maybe_stub_offscreen(entry, sheet, built, true, bible_id, owner, meter, stubs) do
    prior_names = MapSet.new(for {_e, s} <- built, present?(s.name), do: norm(s.name))

    {offscreen, stubs} =
      suggest_and_stub(entry.id, sheet, [], prior_names, bible_id, owner, meter, stubs)

    entry =
      case offscreen do
        [] ->
          entry

        rels ->
          elem(Library.update_payload(entry.id, %CharacterSheet{sheet | relationships: rels}), 1)
      end

    {entry, stubs}
  end

  # The cast context handed to each new character's generation: the earlier characters'
  # sheets (so shared world detail stays consistent) and the off-screen stubs introduced
  # so far (name + role), as the `relations` maps `Autofill` grounds generation in.
  defp cast_relations(built, stubs) do
    mains =
      for {_e, s} <- built, present?(s.name) do
        %{
          "name" => s.name,
          "premise" => s.premise,
          "voice" => s.voice,
          "temperament" => s.temperament,
          "backstory" => s.backstory
        }
      end

    stub_maps =
      for {_norm, %{name: name, role: role}} <- stubs, present?(name) do
        %{"name" => name, "descriptor" => role}
      end

    mains ++ stub_maps
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

  # Cross-link the main cast: each character gets a directional regard toward every other
  # built character (asymmetrical, target id set), merged on top of the off-screen
  # relationships already set during generation. Best-effort per character: a failed
  # regard call leaves that character less-linked rather than aborting the build.
  defp interlink_cast(entries, meter) do
    named = Enum.map(entries, fn e -> {e, Library.payload(e)} end)

    Enum.map(named, fn {entry, sheet} ->
      others = for {o, os} <- named, o.id != entry.id, do: {o.id, os.name}

      case others do
        [] ->
          entry

        _ ->
          cast_rels = cast_regards(sheet, others, meter)
          merged = merge_rels(sheet.relationships || [], cast_rels)

          elem(
            Library.update_payload(entry.id, %CharacterSheet{sheet | relationships: merged}),
            1
          )
      end
    end)
  end

  # Append the cast-link relationships that don't already target a character the sheet
  # links to (so an off-screen suggestion that happened to name a castmate isn't doubled).
  defp merge_rels(existing, additions) do
    have = MapSet.new(existing, & &1.target_id)
    existing ++ Enum.reject(additions, &MapSet.member?(have, &1.target_id))
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

        entry = %{id: stub.id, name: s["target"], role: s["descriptor"]}
        {stub.id, Map.put(stubs, norm(s["target"]), entry)}

      %{id: id} ->
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
      rules: WorldBible.entries(lines(fields["rules"])),
      starting_canon: WorldBible.entries(lines(fields["starting_canon"]))
    }
  end

  defp to_character_sheet(fields, bible_id) do
    %CharacterSheet{
      name: fields["name"],
      # Generated all along and dropped on the floor here, which left every quick-built
      # character with the model inferring pronouns from a name each time it wrote them.
      pronouns: fields["pronouns"],
      premise: fields["premise"],
      appearance: fields["appearance"],
      voice: fields["voice"],
      temperament: fields["temperament"],
      backstory: fields["backstory"],
      # Everything starts public, exactly as the editor's own add does — concealment
      # is an authoring decision, and a build that guessed at it would be deciding
      # what a character may know on the author's behalf.
      facts: for(s <- lines(fields["facts"]), do: %Fact{statement: s}),
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

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

  Returns `{:ok, %{bible: entry, characters: [entry], premise: string}}` — `characters`
  is the **main cast** (stubs land in the library but aren't in the campaign roster).
  Provider and usage-attribution opts (`:provider`, `:user_id`, `:campaign_id`) pass
  straight through to the metered LLM calls.
  """

  alias Polyphony.Library
  alias Polyphony.Authoring.{Autofill, CharacterSheet, Stub, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.Relationship

  @doc """
  Build a world, a cast, and a premise from seeds. `opts`:

    * `:owner` — the `%Owner{}` (required); every entry is stored under it.
    * `:world_seed` — free-text brief for the world (may be blank).
    * `:character_seeds` — a list of free-text briefs, one per character.
    * `:suggest_offscreen` — also stub AI-suggested off-screen people per character
      (default `false`).
    * `:provider` / `:user_id` / `:campaign_id` — metering passthrough.
  """
  @spec build(keyword()) :: {:ok, map()} | {:error, term()}
  def build(opts) do
    owner = Keyword.fetch!(opts, :owner)
    world_seed = to_string(opts[:world_seed] || "")
    seeds = opts[:character_seeds] |> List.wrap() |> Enum.reject(&(String.trim(&1) == ""))
    suggest? = Keyword.get(opts, :suggest_offscreen, false)
    meter = Keyword.take(opts, [:provider, :user_id, :campaign_id])

    with {:ok, world_fields} <- Autofill.generate_all(:world_bible, world_seed, %{}, meter),
         bible_entry <- put(owner, "world_bible", to_world_bible(world_fields)),
         world_ctx = world_context(world_fields),
         {:ok, char_entries} <- build_characters(owner, seeds, bible_entry.id, world_ctx, meter),
         char_entries <- wire_cast(char_entries, suggest?, bible_entry.id, owner, meter),
         {:ok, premise} <-
           Autofill.generate_campaign_premise(
             [world: world_ctx, cast: cast_summaries(char_entries)] ++ meter
           ) do
      {:ok, %{bible: bible_entry, characters: char_entries, premise: premise}}
    end
  end

  # Generate each character in turn, short-circuiting on the first failure.
  defp build_characters(owner, seeds, bible_id, world_ctx, meter) do
    Enum.reduce_while(seeds, {:ok, []}, fn seed, {:ok, acc} ->
      case Autofill.generate_all(:character, seed, %{}, [world: world_ctx] ++ meter) do
        {:ok, fields} ->
          entry = put(owner, "character", to_character_sheet(fields, bible_id))
          {:cont, {:ok, acc ++ [entry]}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  # Wire each character's relationships: a directional link toward every other built
  # character (with an asymmetrical regard and the target's stable id set), plus —
  # when `suggest?` — AI-suggested off-screen people stubbed like the sheet editor does
  # on save. Best-effort per character: a failed call leaves that character less-linked
  # rather than aborting the whole build.
  defp wire_cast(entries, suggest?, bible_id, owner, meter) do
    named = Enum.map(entries, fn e -> {e, Library.payload(e)} end)
    cast_names = MapSet.new(for {_e, s} <- named, present?(s.name), do: norm(s.name))

    Enum.map(named, fn {entry, sheet} ->
      others = for {o, os} <- named, o.id != entry.id, do: {o.id, os.name}
      cast_rels = if others == [], do: [], else: cast_regards(sheet, others, meter)

      offscreen =
        if suggest?,
          do: suggest_and_stub(entry.id, sheet, cast_rels, cast_names, bible_id, owner, meter),
          else: []

      case cast_rels ++ offscreen do
        [] ->
          entry

        rels ->
          {:ok, updated} =
            Library.update_payload(entry.id, %CharacterSheet{sheet | relationships: rels})

          updated
      end
    end)
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
  # only ever creates genuinely new stubs. Each stub carries the inbound relationship
  # back toward this character, seeded with the source's regard as a placeholder — the
  # same pre-reciprocal state the editor produces before its async reciprocal pass.
  defp suggest_and_stub(self_id, sheet, cast_rels, cast_names, bible_id, owner, meter) do
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
        |> Enum.map(fn s ->
          inbound = %Relationship{
            target: sheet.name,
            target_id: self_id,
            descriptor: s["descriptor"],
            reciprocal: s["descriptor"]
          }

          stub =
            put(
              owner,
              "character",
              Stub.new(s["target"], s["descriptor"],
                relationships: [inbound],
                world_bible_id: bible_id
              )
            )

          %Relationship{target: s["target"], target_id: stub.id, descriptor: s["descriptor"]}
        end)

      {:error, _} ->
        []
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

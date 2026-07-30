defmodule Polyphony.Authoring.QuickBuild do
  @moduledoc """
  One-shot scaffolding for a whole campaign (§15, authoring aid) — the "Quick Build"
  button on the campaign editor. From a world seed and one seed per character it:

    1. generates a **world bible** (like ✨ Generate-all on the bible editor),
    2. generates each **character** grounded in that world (✨ Generate-all, status
       `:full`, linked to the bible),
    3. cross-links the cast — every character gets a directional relationship toward
       each other one (`Autofill.regard_map`, so the regards are asymmetrical), and
    4. drafts a **campaign premise** grounded in the world and cast.

  Everything is persisted to the author's `Library` as ordinary owned entries — the
  same kinds the editors produce — so each can be opened and fleshed out afterwards.
  It's a stateless orchestrator over `Autofill` + `Library`; the LiveView owns the
  async/UI and attaches the results (bible id, character ids, premise) to the campaign.

  Returns `{:ok, %{bible: entry, characters: [entry], premise: string}}`. Provider and
  usage-attribution opts (`:provider`, `:user_id`, `:campaign_id`) pass straight
  through to the metered LLM calls.
  """

  alias Polyphony.Library
  alias Polyphony.Authoring.{Autofill, CharacterSheet, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.Relationship

  @doc """
  Build a world, a cast, and a premise from seeds. `opts`:

    * `:owner` — the `%Owner{}` (required); every entry is stored under it.
    * `:world_seed` — free-text brief for the world (may be blank).
    * `:character_seeds` — a list of free-text briefs, one per character.
    * `:provider` / `:user_id` / `:campaign_id` — metering passthrough.
  """
  @spec build(keyword()) :: {:ok, map()} | {:error, term()}
  def build(opts) do
    owner = Keyword.fetch!(opts, :owner)
    world_seed = to_string(opts[:world_seed] || "")
    seeds = opts[:character_seeds] |> List.wrap() |> Enum.reject(&(String.trim(&1) == ""))
    meter = Keyword.take(opts, [:provider, :user_id, :campaign_id])

    with {:ok, world_fields} <- Autofill.generate_all(:world_bible, world_seed, %{}, meter),
         bible_entry <- put(owner, "world_bible", to_world_bible(world_fields)),
         world_ctx = world_context(world_fields),
         {:ok, char_entries} <- build_characters(owner, seeds, bible_entry.id, world_ctx, meter),
         char_entries <- link_cast(char_entries, meter),
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

  # Give each character a directional relationship toward every other built character,
  # with a generated (asymmetrical) regard and the target's stable id already set.
  # Best-effort per character: a failed regard call leaves that character un-linked
  # rather than aborting the whole build.
  defp link_cast(entries, meter) do
    named = Enum.map(entries, fn e -> {e, Library.payload(e)} end)

    Enum.map(named, fn {entry, sheet} ->
      others = for {o, os} <- named, o.id != entry.id, do: {o.id, os.name}

      case others do
        [] ->
          entry

        _ ->
          rels = regards(sheet, others, meter)

          {:ok, updated} =
            Library.update_payload(entry.id, %CharacterSheet{sheet | relationships: rels})

          updated
      end
    end)
  end

  defp regards(sheet, others, meter) do
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

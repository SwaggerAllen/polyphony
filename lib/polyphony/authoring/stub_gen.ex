defmodule Polyphony.Authoring.StubGen do
  @moduledoc """
  Generate a pending stub's full sheet and finalize it to `:full` — shared by the
  library's bulk "generate all pending" action and the play view's "generate & admit"
  when the Director introduces a character. Grounds generation in the stub's world and
  inherited role, and preserves an author-set name.
  """
  alias Polyphony.Library
  alias Polyphony.Authoring.{Autofill, CharacterSheet, WorldBible}

  @doc """
  Generate and finalize the character behind `entry`. Returns `:ok` or `:error`.

  **`:full` is a claim `SceneControl` trusts**, so it is only made when there is
  something on the sheet. A provider that answers with an empty object is an `{:ok, _}`
  carrying nothing, and promoting on it produced a castable character with no premise,
  no voice and no temperament — one the Director would then be asked to write turns
  for. Whatever was generated is still kept; the sheet simply stays pending, which is
  the failure direction that leaves the author something to open and finish.
  """
  @spec finalize(map(), integer() | nil, keyword()) :: :ok | :error
  def finalize(entry, user_id, extra \\ []) do
    sheet = struct(CharacterSheet, Map.from_struct(Library.payload(entry)))
    brief = [sheet.name, sheet.role] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" — ")

    # `extra` carries the campaign this generation belongs to when the caller knows it
    # — writing a walk-on into a running scene is that scene's campaign's spend (§B5),
    # not unattributed authoring. The library's bulk action passes nothing and keeps
    # the old behaviour.
    opts =
      [world: world_context(sheet.world_bible_id), role: sheet.role, usage_kind: "authoring"] ++
        if(user_id, do: [user_id: user_id], else: []) ++
        Keyword.take(extra, [:campaign_id])

    case Autofill.generate_all(:character, brief, %{"name" => sheet.name || ""}, opts) do
      {:ok, values} ->
        written = %CharacterSheet{
          sheet
          | name: keep_or(sheet.name, values["name"]),
            premise: values["premise"] || sheet.premise,
            appearance: values["appearance"] || sheet.appearance,
            voice: values["voice"] || sheet.voice,
            temperament: values["temperament"] || sheet.temperament,
            backstory: values["backstory"] || sheet.backstory
        }

        if written?(written) do
          Library.update_payload(entry.id, %CharacterSheet{written | status: :full})
          :ok
        else
          Library.update_payload(entry.id, written)
          :error
        end

      {:error, _} ->
        :error
    end
  end

  # A name is not a character — it is what a stub already had. What makes somebody
  # castable is prose the Director can write turns from.
  defp written?(%CharacterSheet{} = sheet) do
    [sheet.premise, sheet.appearance, sheet.voice, sheet.temperament, sheet.backstory]
    |> Enum.any?(&(is_binary(&1) and String.trim(&1) != ""))
  end

  @doc "A world-bible context map for generation, or nil for a world-less character."
  def world_context(nil), do: nil

  def world_context(id) do
    case Library.get(id) do
      nil ->
        nil

      entry ->
        case Library.payload(entry) do
          %WorldBible{} = wb ->
            %{
              "name" => wb.name || "",
              "setting" => wb.setting || "",
              "tone" => wb.tone || "",
              # `public/1`, not `statements/1`: a character must not be *written from*
              # a world secret they don't know any more than they may be told it.
              "rules" => Enum.join(WorldBible.public(wb.rules), "\n"),
              "starting_canon" => Enum.join(WorldBible.public(wb.starting_canon), "\n")
            }

          _ ->
            nil
        end
    end
  end

  # Keep an author-set name; only fall back to a generated one when it was blank.
  defp keep_or(name, generated) when name in [nil, ""], do: generated || name
  defp keep_or(name, _generated), do: name
end

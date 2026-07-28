defmodule Polyphony.Authoring.StubGen do
  @moduledoc """
  Generate a pending stub's full sheet and finalize it to `:full` — shared by the
  library's bulk "generate all pending" action and the play view's "generate & admit"
  when the Director introduces a character. Grounds generation in the stub's world and
  inherited role, and preserves an author-set name.
  """
  alias Polyphony.Library
  alias Polyphony.Authoring.{Autofill, CharacterSheet, WorldBible}

  @doc "Generate and finalize the character behind `entry`. Returns `:ok` or `:error`."
  @spec finalize(map(), integer() | nil) :: :ok | :error
  def finalize(entry, user_id) do
    sheet = struct(CharacterSheet, Map.from_struct(Library.payload(entry)))
    brief = [sheet.name, sheet.role] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" — ")

    opts =
      [world: world_context(sheet.world_bible_id), role: sheet.role, usage_kind: "authoring"] ++
        if(user_id, do: [user_id: user_id], else: [])

    case Autofill.generate_all(:character, brief, %{"name" => sheet.name || ""}, opts) do
      {:ok, values} ->
        Library.update_payload(entry.id, %CharacterSheet{
          sheet
          | name: keep_or(sheet.name, values["name"]),
            premise: values["premise"] || sheet.premise,
            appearance: values["appearance"] || sheet.appearance,
            voice: values["voice"] || sheet.voice,
            temperament: values["temperament"] || sheet.temperament,
            backstory: values["backstory"] || sheet.backstory,
            status: :full
        })

        :ok

      {:error, _} ->
        :error
    end
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
              "rules" => Enum.join(wb.rules || [], "\n"),
              "starting_canon" => Enum.join(wb.starting_canon || [], "\n")
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

defmodule Polyphony.Authoring.Stub do
  @moduledoc """
  Character stubs (§B8) — the pattern locations already have via `origin:
  :discovered`, now for characters.

  A **stub** is a placeholder: a name, a one-line `role`, and the inbound
  `relationships` that gave rise to it — no generated sheet, facts, or voice. Stubs
  are created inline from a relationship editor, a campaign roster, or by the Director
  accepting a `:novel` proposal that references an unknown person.

  **Promotion** generates a full sheet from the stub + its inbound relationships +
  campaign/bible context, and lands it behind a **review gate** (`status:
  :proposed`) — it is not usable until accepted (`status: :full`). Casting a stub
  prompts promotion first (`Polyphony.SceneControl` refuses a non-`:full` character).

  Generation is pluggable via `:generator` (default: the configured LLM), so the
  whole flow is tested offline.
  """

  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.LLM.Provider

  @doc "Create a stub: a name + one-line role (+ optional inbound `:relationships`)."
  @spec new(String.t(), String.t(), keyword()) :: CharacterSheet.t()
  def new(name, role, opts \\ []) do
    %CharacterSheet{
      name: name,
      role: role,
      status: :stub,
      relationships: Keyword.get(opts, :relationships, [])
    }
  end

  @doc "Is `sheet` an unpromoted stub?"
  def stub?(%CharacterSheet{status: :stub}), do: true
  def stub?(%CharacterSheet{}), do: false

  @doc "Is `sheet` promoted and usable (accepted `:full`)?"
  def full?(%CharacterSheet{status: :full}), do: true
  def full?(%CharacterSheet{}), do: false

  @doc """
  Promote a stub to a full sheet behind the review gate. Generates sheet fields from
  the stub + inbound relationships + campaign/bible context, returning `{:ok, sheet}`
  with `status: :proposed` (not yet usable), or `{:error, reason}`. Opts: `:campaign`,
  `:bible`, `:generator`, `:provider`, `:model`.
  """
  @spec promote(CharacterSheet.t(), keyword()) :: {:ok, CharacterSheet.t()} | {:error, term()}
  def promote(%CharacterSheet{status: :stub} = stub, opts \\ []) do
    generator = Keyword.get(opts, :generator, &default_generate/2)

    case generator.(stub, opts) do
      {:ok, fields} when is_map(fields) ->
        {:ok,
         %CharacterSheet{
           stub
           | premise: fields[:premise] || fields["premise"],
             appearance: fields[:appearance] || fields["appearance"],
             voice: fields[:voice] || fields["voice"],
             temperament: fields[:temperament] || fields["temperament"],
             backstory: fields[:backstory] || fields["backstory"],
             status: :proposed
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Accept a promoted (`:proposed`) sheet — the review gate's accept. Now `:full`."
  @spec accept(CharacterSheet.t()) :: CharacterSheet.t()
  def accept(%CharacterSheet{status: :proposed} = sheet),
    do: %CharacterSheet{sheet | status: :full}

  # ── Default LLM generator ─────────────────────────────────────────────────────

  defp default_generate(%CharacterSheet{} = stub, opts) do
    provider = Keyword.get(opts, :provider) || Provider.default()

    messages = [
      %{
        role: "system",
        content:
          "Flesh out a character stub into a full sheet. Return JSON with keys " <>
            "premise, appearance, voice, temperament, backstory."
      },
      %{role: "user", content: prompt(stub, opts)}
    ]

    with {:ok, text} <-
           Polyphony.LLM.call(
             messages,
             [provider: provider, response: :sheet, model: Keyword.get(opts, :model)] ++
               Keyword.take(opts, [:user_id, :campaign_id, :usage_kind])
           ),
         {:ok, data} <- Jason.decode(text) do
      {:ok, data}
    end
  end

  defp prompt(%CharacterSheet{name: name, role: role, relationships: rels}, opts) do
    rel_lines =
      case rels do
        [] -> "(none)"
        rs -> Enum.map_join(rs, "\n", fn r -> "- #{r.target}: #{r.descriptor}" end)
      end

    """
    Name: #{name}
    Role: #{role}
    Inbound relationships:
    #{rel_lines}
    Campaign: #{Keyword.get(opts, :campaign, "(unspecified)")}
    World bible: #{Keyword.get(opts, :bible, "(unspecified)")}
    """
  end
end

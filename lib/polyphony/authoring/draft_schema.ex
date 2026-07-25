defmodule Polyphony.Authoring.DraftSchema do
  @moduledoc """
  The generation schema for a character draft (§5–6, §15).

  Deliberately **content-only** — the authored prose fields, and nothing else. No
  status, no feedback, no lock flags: the model is asked to generate character,
  not workflow. Those live in `Polyphony.Authoring.FieldStore`, out of the schema
  the model ever sees.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @fields ~w(premise appearance voice temperament backstory)a

  @primary_key false
  embedded_schema do
    field(:premise, :string)
    field(:appearance, :string)
    field(:voice, :string)
    field(:temperament, :string)
    field(:backstory, :string)
  end

  @doc "The authored (generatable) field names."
  def fields, do: @fields

  @doc "Parse a full draft into `{:ok, %{field => value}}` (present fields only)."
  @spec parse(map()) :: {:ok, %{atom() => String.t()}} | {:error, Ecto.Changeset.t()}
  def parse(data) when is_map(data) do
    cs = cast(%__MODULE__{}, data, @fields)

    if cs.valid? do
      values =
        cs
        |> apply_changes()
        |> Map.take(@fields)
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      {:ok, values}
    else
      {:error, cs}
    end
  end
end

defmodule Polyphony.Accounts.Consent do
  @moduledoc """
  A versioned consent record (§B2). Acceptance of each policy document — the
  content-policy explainer, the terms of service, and the privacy policy — is logged
  **append-only** with its version and a timestamp. A material change bumps the
  document's current version, and `Polyphony.Accounts.needs_reconsent?/2` compares the
  latest accepted version against the current one to re-prompt on next sign-in.

  The current versions live here as the single source of truth; bump one when its
  document materially changes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @documents %{content_policy: 1, tos: 1, privacy: 1}

  schema "consents" do
    field(:user_id, :id)
    field(:document, :string)
    field(:version, :integer)
    field(:accepted_at, :naive_datetime_usec)
    timestamps(type: :naive_datetime_usec)
  end

  @doc "The documents a user must accept, mapped to their current version."
  @spec documents() :: %{atom() => pos_integer()}
  def documents, do: @documents

  @doc "The document keys sign-up must collect acceptance for."
  @spec required_documents() :: [atom()]
  def required_documents, do: Map.keys(@documents)

  @doc "The current version of `document`, or nil if unknown."
  @spec current_version(atom() | String.t()) :: pos_integer() | nil
  def current_version(document) do
    Enum.find_value(@documents, fn {doc, v} -> to_string(doc) == to_string(document) && v end)
  end

  def changeset(user_id, document, version, accepted_at) do
    %__MODULE__{}
    |> change(
      user_id: user_id,
      document: to_string(document),
      version: version,
      accepted_at: accepted_at
    )
    |> validate_required([:user_id, :document, :version, :accepted_at])
  end
end

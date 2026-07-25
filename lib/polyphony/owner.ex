defmodule Polyphony.Owner do
  @moduledoc """
  The owner of an owned entity, as an **indirection** rather than a hardcoded
  `user_id` (roadmap §P2/§P8). Today an owner is always a user, but ownership is
  expressed as a `{type, id}` value so it can later become polymorphic (user *or*
  org) by adding an owner type + a permission layer — a bolt-on, not a schema-wide
  migration.

  Only **content ownership** flows through here (campaigns, sheets, bibles, template
  overrides, published snapshots — `Polyphony.Library`). Actor/reporter/recipient
  references elsewhere stay plain user references: an org doesn't file a report or
  receive an email, a user does.

  Callers may pass a `%Polyphony.Owner{}`, a `%Accounts.User{}`, or a bare id (coerced
  to a user, the v1 default) anywhere an owner is expected — `coerce/1` normalizes.
  """

  alias Polyphony.Accounts.User

  @enforce_keys [:type, :id]
  defstruct [:type, :id]

  @type owner_type :: :user | :org
  @type t :: %__MODULE__{type: owner_type(), id: String.t()}

  @doc "A user owner."
  @spec user(term()) :: t()
  def user(id), do: %__MODULE__{type: :user, id: to_string(id)}

  @doc "The owner of a `%User{}` account."
  @spec of(User.t()) :: t()
  def of(%User{id: id}), do: user(id)

  @doc """
  Normalize anything owner-shaped to an `%Owner{}`: an `%Owner{}` passes through, a
  `%User{}` becomes its owner, and a bare id/string is coerced to a **user** owner
  (the v1 default — every owner is a user until orgs exist).
  """
  @spec coerce(t() | User.t() | term()) :: t()
  def coerce(%__MODULE__{} = owner), do: owner
  def coerce(%User{} = user), do: of(user)
  def coerce(id) when is_binary(id) or is_integer(id), do: user(id)

  @doc "The owner type as a string, for storage."
  @spec type_string(t()) :: String.t()
  def type_string(%__MODULE__{type: type}), do: to_string(type)

  @doc "The owner id (the raw id within its type)."
  @spec id(t()) :: String.t()
  def id(%__MODULE__{id: id}), do: id

  @doc "A stable string key `\"<type>:<id>\"` — for URLs, display, and attribution."
  @spec key(t()) :: String.t()
  def key(%__MODULE__{type: type, id: id}), do: "#{type}:#{id}"

  @doc "Parse a `\"<type>:<id>\"` key back into an owner."
  @spec parse(String.t()) :: t()
  def parse(key) when is_binary(key) do
    case String.split(key, ":", parts: 2) do
      [type, id] -> %__MODULE__{type: String.to_existing_atom(type), id: id}
      [id] -> user(id)
    end
  end

  @doc "Are two owners the same principal?"
  @spec same?(t(), t()) :: boolean()
  def same?(%__MODULE__{type: t, id: a}, %__MODULE__{type: t, id: b}), do: a == b
  def same?(_a, _b), do: false

  @doc "Is this a user owner?"
  @spec user?(t()) :: boolean()
  def user?(%__MODULE__{type: :user}), do: true
  def user?(%__MODULE__{}), do: false
end

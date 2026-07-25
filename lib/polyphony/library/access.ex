defmodule Polyphony.Library.Access do
  @moduledoc """
  The **pure** access predicate for owned entities (§B1). Access is a property of
  the data — visibility + ownership + share token — decided here and nowhere else,
  the same discipline `Polyphony.Visibility` applies to fiction.

  A **viewer** is `%{actor_id: id | nil, token: token | nil}`; `anonymous/0` is the
  signed-out viewer. The rules (§B1 "Anonymous access"):

    * `:public`   — readable by anyone, signed out included.
    * `:unlisted` — readable only by a viewer presenting the matching share token.
    * `:private`  — readable only by the owner.

  **Any write requires auth and ownership** — a `nil` actor (anonymous) can never
  write, and only the owner can. Default-deny throughout: an unrecognized visibility
  denies reads, matching the visibility layer's rule-3 posture.
  """

  @type viewer :: %{optional(:actor_id) => term() | nil, optional(:token) => term() | nil}

  @doc "The signed-out viewer — no identity, no token."
  @spec anonymous() :: viewer()
  def anonymous, do: %{actor_id: nil, token: nil}

  @doc "May `viewer` read `entry`? The owner always may; otherwise the visibility rule decides."
  @spec can_read?(map(), viewer()) :: boolean()
  def can_read?(entry, viewer) do
    owner?(entry, viewer) or visibility_allows_read?(entry, viewer)
  end

  @doc "May `viewer` write `entry`? Only the authenticated owner."
  @spec can_write?(map(), viewer()) :: boolean()
  def can_write?(entry, viewer), do: owner?(entry, viewer)

  # ── Rules ───────────────────────────────────────────────────────────────────

  # Ownership: a nil actor (anonymous) never matches. A **user**-owned entry is owned
  # by the actor whose id equals `owner_id`. An org-owned entry (`owner_type` other
  # than "user") is intentionally NOT ownable by a bare actor here — org membership
  # resolves through a permission layer that is a deliberate later addition (§P8), so
  # this default-denies rather than guessing.
  defp owner?(%{owner_id: owner_id} = entry, %{actor_id: actor_id}) do
    user_owned?(entry) and not is_nil(actor_id) and to_string(actor_id) == to_string(owner_id)
  end

  defp owner?(_entry, _viewer), do: false

  # Absent owner_type (e.g. a hand-built struct in a test) defaults to user-owned.
  defp user_owned?(%{owner_type: type}) when not is_nil(type), do: to_string(type) == "user"
  defp user_owned?(_entry), do: true

  # Non-owner read: gated purely by visibility + token, default-deny.
  defp visibility_allows_read?(%{visibility: visibility} = entry, viewer) do
    case to_string(visibility) do
      "public" -> true
      "unlisted" -> token_matches?(entry, viewer)
      _ -> false
    end
  end

  # Unlisted requires the presented token to equal the entry's share token, both
  # non-nil — an absent or wrong token is denied.
  defp token_matches?(%{share_token: token}, %{token: presented}) do
    not is_nil(token) and not is_nil(presented) and to_string(token) == to_string(presented)
  end

  defp token_matches?(_entry, _viewer), do: false
end

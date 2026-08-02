defmodule Polyphony.Content.Floor do
  @moduledoc """
  Layer 1 of content governance (§A5): the **app-wide 18+ floor** — the widest
  ceiling every narrower layer (campaign, boundary) intersects down from.

  **18+ is eligibility, not a per-user content layer (backlog §4b.1).** Under-18s
  cannot hold a Polyphony account at all — sign-up rejects an unchecked attestation
  before writing anything (`Accounts.sign_up`). So *every* real account has
  attested, which makes the floor trivially satisfied rather than a live per-user
  gate. It permits every category (it is a *floor*, not a filter — narrowing
  happens above it).

  The `attested` parameter and the empty-register branch stay for when under-18
  support is actually built (parental controls + in-house filtering, deferred a
  long way out); until then nothing passes `attested: false`, so the branch is a
  latent seam, not a code path exercised per user.
  """
  alias Polyphony.Content

  @doc """
  The categories the app permits at its widest. `:attested` (default `true`) — the
  latent under-18 seam; an unattested account would floor to an empty register, but
  today no account is unattested (sign-up requires it), so this is always the full
  register in practice.
  """
  @spec register(keyword()) :: [Content.category()]
  def register(opts \\ []) do
    if Keyword.get(opts, :attested, true), do: Content.categories(), else: []
  end
end

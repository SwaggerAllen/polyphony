defmodule Polyphony.Content.Floor do
  @moduledoc """
  Layer 1 of content governance (§A5): the **app-wide 18+ floor**.

  Non-configurable and the widest ceiling — adult-content categories are available
  at all only to an account that cleared the 18+ attestation (A9). The account and
  attestation surface is B2 (not built yet), so this reads a flag rather than a
  stored record.

  For an attested account the floor permits every category (it is a *floor*, not a
  filter — narrowing happens in the campaign and boundary layers). Without
  attestation the floor is empty, and the nesting intersection collapses every
  narrower layer to no adult content — the invariant that a narrower layer can
  never expand past a broader one.
  """
  alias Polyphony.Content

  @doc """
  The categories the app permits at its widest. `:attested` (default `true` until
  the account layer lands) — an unattested account floors to an empty register.
  """
  @spec register(keyword()) :: [Content.category()]
  def register(opts \\ []) do
    if Keyword.get(opts, :attested, true), do: Content.categories(), else: []
  end
end

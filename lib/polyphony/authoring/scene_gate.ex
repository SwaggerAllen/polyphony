defmodule Polyphony.Authoring.SceneGate do
  @moduledoc """
  The arc-review gate on **opening a new scene** (§3.0).

  Every unreviewed arc proposal is a gap between who a character is on paper and who
  they've become in the story — and generation works from the paper. Let it run and
  the Director writes someone who stopped existing two scenes ago. So opening a new
  scene requires that **every character being cast has no pending arc proposals**, and
  that the **campaign has no pending world arc** (world arc feeds every generation in
  the campaign).

  Scoping is what makes it tolerable (§3.0):

    * **Per-cast, not per-backlog.** Nineteen pending across three scenes doesn't block a
      scene with two clean characters — only the *selected cast* is evaluated. (World arc
      is campaign-wide by nature, so it always counts.)
    * **Accept-all is the intended fast path**, not a loophole — the review screen offers
      it, so one tap produces sheets that match the story.
    * **Never blocks the open scene**, only opening a *new* one; the current scene closes
      normally regardless.

  Keyed by character **id** — the identity scenes and arc extraction both use
  (`CharacterEntered.character_id`, now the library id since §5.2's mint flip). The
  gate used to resolve library ids to names to do this lookup; it doesn't any more,
  because there is only one identity again.

  *Not yet modelled here:* the "extraction failed → block with a retry" and the
  "extraction still running → not ready yet" states (§3.0). Those need the async
  extraction status; the proposal gate below is the correctness core.
  """

  alias Polyphony.Repo
  alias Polyphony.ReadModels.ArcEntry

  @type blocked :: %{characters: [String.t()], world: non_neg_integer()}

  @doc """
  May a new scene open for `campaign_id` with cast `character_ids`? `:ok`, or
  `{:blocked, %{characters: [id], world: count}}` listing the cast members with
  pending arc and the count of pending world-arc proposals. The caller renders those
  ids as names — the gate deals only in identity.
  """
  @spec check(term(), [term()], module()) :: :ok | {:blocked, blocked()}
  def check(campaign_id, character_ids, repo \\ Repo) do
    blocked_chars =
      character_ids
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.filter(fn id -> ArcEntry.list_proposed(repo, id) != [] end)

    world_pending = length(ArcEntry.list_proposed_world(repo, campaign_id))

    if blocked_chars == [] and world_pending == 0 do
      :ok
    else
      {:blocked, %{characters: blocked_chars, world: world_pending}}
    end
  end
end

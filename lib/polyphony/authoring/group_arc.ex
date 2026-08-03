defmodule Polyphony.Authoring.GroupArc do
  @moduledoc """
  When a group changes, one change becomes many proposals (`backend-backlog.md` §3.0b,
  `ux/polyphony-arc.html` §03b).

  A group is a character-shaped template that seeds people **by copy**, so updating the
  template reaches only people written from it *later*. Current members are separate
  people with separate sheets, and reaching them means reaching them one at a time.

  ## Nothing propagates silently

  That is the rule everywhere else in this system and it holds here: six members means
  **six things you can say yes or no to**, not one switch that rewrites six sheets. The
  fan-out produces `1 + n` ordinary `ArcEntry` proposals — one against the group as its
  own arc subject, one per current member — and every one of them goes through the same
  review gate as anything else.

  ## Which is what makes dissent free

  Accept the group's change, reject one member's, and you have written the person who
  didn't go along with it. That is a story beat an author would otherwise have to think
  of and write by hand; here it falls out of the queue by saying no once.

  ## Off-screen members are included

  Same reasoning as a world fact: the group changed and they are in it, so they get the
  proposal whether or not they were in the scene. Membership is what matters, not
  attendance and not where they came from — someone who joined the group by hand and was
  never seeded from it gets one too.

  ## What this doesn't do

  It doesn't *write* the per-member statements. Deciding what a group's change means for
  one particular person is interpretation, which is the extractor's job; this is the
  fan-out and the bookkeeping around it. A caller with only the group's statement gets a
  serviceable default so the queue is never empty where it should be full.
  """

  alias Polyphony.Authoring.ArcEntry
  alias Polyphony.Groups
  alias Polyphony.ReadModels.ArcEntry, as: ArcEntryRepo
  alias Polyphony.Repo

  @doc """
  The subject type a group's own arc is filed under.

  A group is neither a character nor the world, and filing it as either would make the
  gate ask the wrong question — a pending group proposal shouldn't block a scene the
  group isn't in, and it isn't campaign-wide the way world arc is.
  """
  @spec subject_type() :: String.t()
  def subject_type, do: "group"

  @doc """
  Fan one group change out into proposals: one for the group, one per current member.

  `entry` is the change to the group itself. `opts[:for_member]` is
  `(character_id -> %ArcEntry{} | nil)` — what this change means for that person; a
  member it returns `nil` for is skipped, which is how an extractor declines to assert
  something about someone it has nothing to say about. Without it, every member gets the
  group's own statement, which is at least true and reviewable.

  Returns `%{group: row, members: [{character_id, row}]}`.
  """
  @spec fan_out(term(), ArcEntry.t(), keyword()) :: %{
          group: map(),
          members: [{String.t(), map()}]
        }
  def fan_out(group_id, %ArcEntry{} = entry, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    for_member = Keyword.get(opts, :for_member, fn _id -> nil end)

    group_row = put(repo, entry, group_id, subject_type())

    members =
      for member_id <- Groups.member_ids(group_id, Keyword.take(opts, [:repo])),
          proposal = for_member.(member_id) || member_default(entry),
          proposal != nil do
        {member_id, put(repo, proposal, member_id, "character")}
      end

    %{group: group_row, members: members}
  end

  @doc """
  Everything waiting on a group — its own proposals and its members', as one card.

  A group of twelve would otherwise flood the queue, so the design collapses it: one
  card, one fast path, expandable when it matters. Returns
  `%{group: [row], members: [{character_id, [row]}]}`, members with nothing pending
  omitted.
  """
  @spec pending(term(), keyword()) :: %{group: [map()], members: [{String.t(), [map()]}]}
  def pending(group_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    members =
      for member_id <- Groups.member_ids(group_id, Keyword.take(opts, [:repo])),
          rows = ArcEntryRepo.list_proposed(repo, member_id, "character"),
          rows != [],
          do: {member_id, rows}

    %{group: ArcEntryRepo.list_proposed(repo, group_id, subject_type()), members: members}
  end

  @doc """
  How the collapsed card counts itself — *1 change to the group · 6 to its people*.
  """
  @spec counts(term(), keyword()) :: %{group: non_neg_integer(), members: non_neg_integer()}
  def counts(group_id, opts \\ []) do
    %{group: group, members: members} = pending(group_id, opts)

    %{
      group: length(group),
      members: members |> Enum.map(fn {_id, rows} -> length(rows) end) |> Enum.sum()
    }
  end

  @doc """
  Accept the whole fan-out — *True for all seven*.

  The fast path the design puts first on the collapsed card, and the reason the card
  can collapse at all. Returns how many proposals were promoted.
  """
  @spec accept_all(term(), keyword()) :: non_neg_integer()
  def accept_all(group_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    member_count =
      group_id
      |> Groups.member_ids(Keyword.take(opts, [:repo]))
      |> Enum.map(&ArcEntryRepo.accept_all(repo, &1, "character"))
      |> Enum.sum()

    ArcEntryRepo.accept_all(repo, group_id, subject_type()) + member_count
  end

  defp put(repo, %ArcEntry{} = entry, subject_id, subject_type) do
    row = ArcEntryRepo.put(repo, entry, subject_id)
    ArcEntryRepo.set_subject_type(repo, row.id, subject_type)
  end

  # What a group's change means for a member, absent an extractor with an opinion. The
  # group's own statement is at least true of them — they're in it — and it is
  # reviewable, which is the bar. An author who disagrees says no, which is the feature.
  defp member_default(%ArcEntry{} = entry),
    do: %ArcEntry{entry | sheet_field: nil, kind: :discovery}
end

defmodule Polyphony.Authoring.ArcAccept do
  @moduledoc """
  Accepting an arc proposal, including the people it brings with it (STR-62).

  `ReadModels.ArcEntry.accept/2` is a status flip and stays one. This is the layer
  above it: a proposal can **name somebody who doesn't exist yet**, and accepting it
  is what makes them real.

  ## Why here, and why at accept

  An authored relationship names a target the way the sheet editor does — free text,
  because the set of people isn't closed. The sheet editor seeds a stub for an unknown
  name on **save**, so the relationship targets an id rather than a string; arc has
  the same need and had no equivalent, which left an accepted relationship pointing at
  a name nothing could resolve.

  It happens at **accept** rather than at propose because a proposal is explicitly not
  true yet — *nothing a scene decides is applied on its own* — and writing a character
  into the library is applying something. Seeding at propose time would leave a person
  in the campaign behind every refused proposal, which is the one outcome an author who
  said *No* is entitled not to get.

  A name that already belongs to somebody owned resolves to **them** rather than
  minting a second person, which is the same precedence the sheet editor uses: an
  existing character wins over a new stub, matched on a downcased name.
  """

  alias Polyphony.{Campaigns, Library, Repo}
  alias Polyphony.Authoring.{CharacterSheet, Stub}
  alias Polyphony.Authoring.CharacterSheet.Relationship
  alias Polyphony.ReadModels.ArcEntry, as: ArcRM

  @doc """
  Accept one proposal by id, seeding anybody it names first. Returns the promoted row.
  """
  @spec accept(term(), term(), keyword()) :: ArcRM.t()
  def accept(id, owner, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    repo
    |> ArcRM.get(id)
    |> settle(owner, repo)

    ArcRM.accept(repo, id)
  end

  @doc """
  Accept every pending proposal for a subject, seeding as it goes. Returns how many
  were promoted — the same answer `ArcEntry.accept_all/3` gives, since the row's
  *Accept all* is the fast path and must stay one tap.
  """
  @spec accept_all(term(), String.t(), term(), keyword()) :: non_neg_integer()
  def accept_all(subject_id, subject_type, owner, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    repo
    |> ArcRM.list_proposed(subject_id, subject_type)
    |> Enum.each(&settle(&1, owner, repo))

    ArcRM.accept_all(repo, subject_id, subject_type)
  end

  # Only an authored relationship naming a target with no id has anything to settle.
  # Everything else — every extracted proposal, every other authored kind — passes
  # through untouched, which is why this is a filter rather than a hook.
  defp settle(%{sheet_field: "relationships", target: target, target_id: nil} = row, owner, repo)
       when is_binary(target) and target != "" do
    case resolve_or_stub(row, target, owner, repo) do
      nil -> :ok
      id -> ArcRM.set_target_id(repo, row.id, id)
    end
  end

  defp settle(_row, _owner, _repo), do: :ok

  defp resolve_or_stub(row, target, owner, repo) do
    subject = Library.get(row.subject_id, repo: repo)
    sheet = subject && Library.payload(subject)

    case existing_character(owner, target, row.subject_id, repo) do
      %{id: id} -> id
      nil -> mint_stub(row, target, sheet, owner, repo)
    end
  end

  # An existing owned character with that name — never a second copy of somebody who
  # is already written, and never the subject themselves.
  defp existing_character(owner, target, subject_id, repo) do
    down = normalize(target)

    owner
    |> Library.list_for_owner(repo: repo)
    |> Enum.filter(&(&1.kind == "character" and to_string(&1.id) != to_string(subject_id)))
    |> Enum.find(fn entry ->
      case Library.payload(entry) do
        %CharacterSheet{name: name} -> normalize(name) == down
        _ -> false
      end
    end)
  end

  # A walk-on: unwritten until they matter, carrying the regard that named them as
  # their inbound relationship and inheriting the world of the person who named them,
  # so they already belong to the right setting.
  defp mint_stub(row, target, sheet, owner, repo) do
    inbound =
      case sheet do
        %CharacterSheet{name: name} ->
          [
            %Relationship{
              target: name,
              target_id: to_string(row.subject_id),
              descriptor: row.statement,
              reciprocal: row.statement
            }
          ]

        _ ->
          []
      end

    entry =
      Library.put(
        %{
          owner: owner,
          kind: "character",
          payload:
            Stub.new(target, row.statement,
              relationships: inbound,
              world_bible_id: world_of(sheet)
            )
        },
        repo: repo
      )

    # Into the same campaign as the character who named them, for the same reason the
    # sheet editor does it: a stub in no campaign is one the roster, the fill-them-in
    # prompt and the library's grouping all fail to see.
    Campaigns.cast(Campaigns.of_character(owner, row.subject_id, repo: repo), entry.id,
      repo: repo
    )

    entry.id
  end

  defp world_of(%CharacterSheet{world_bible_id: id}), do: id
  defp world_of(_), do: nil

  defp normalize(s), do: s |> to_string() |> String.trim() |> String.downcase()
end

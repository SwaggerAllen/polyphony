defmodule PolyphonyWeb.GroupEditorLiveTest do
  @moduledoc """
  Groups, finally reachable.

  Everything underneath them shipped and was tested: seeding a character from a
  template, resolving an audience through live membership, and fanning a change out to
  every member as reviewable proposals. What none of it had was a way in.
  `Groups.create/3` and `update_fields/3` had no production callers, so the library's
  Groups tab listed rows only a test could produce and the collapsed group card on arc
  review could never populate — the parity audit's one row that needed a screen rather
  than a wire.

  The rule the fan-out exists to keep, and the one this file guards: **nothing
  propagates silently.** Editing the template reaches nobody, because seeding is a copy
  and members are separate people. Telling them is a separate, deliberate act that
  produces `1 + n` proposals through the ordinary review gate — which is what makes
  refusing one of them a story beat rather than a bug.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Groups, Library}
  alias Polyphony.Owner
  alias Polyphony.Authoring.{CharacterSheet, Group}
  alias Polyphony.Authoring.CharacterSheet.Fact
  alias Polyphony.ReadModels.ArcEntry, as: ArcEntryRepo
  alias Polyphony.Repo

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp character(user, name) do
    Library.put(%{
      owner: Owner.of(user),
      kind: "character",
      payload: %CharacterSheet{name: name, status: :full}
    })
  end

  defp group(user, attrs \\ %{}) do
    fields = struct(Group, Map.merge(%{name: "The Tidewatch"}, attrs))
    Groups.create(Owner.of(user), fields)
  end

  defp group_of(entry), do: Library.payload(Library.get(entry.id))

  defp pending_for(subject, type),
    do: ArcEntryRepo.list_proposed(Repo, to_string(subject), type)

  describe "making one" do
    test "the campaign screen can write a group, which nothing could before",
         %{conn: conn, user: user} do
      camp =
        Library.put(%{
          owner: Owner.of(user),
          kind: "campaign",
          payload: %{kind: :campaign, name: "Camp", character_ids: [], scenes: []}
        })

      {:ok, view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")

      # §06b's empty state, in the design's own words.
      assert html =~ "No groups yet."
      assert html =~ "saves writing the same person five times"

      assert {:error, {:live_redirect, %{to: "/authoring/group/" <> id}}} =
               view
               |> element(~s(button[phx-click="new_group"]), "Write a group")
               |> render_click()

      assert %Group{} = Groups.get(id)
    end

    test "and lists them the way the design counts them", %{conn: conn, user: user} do
      group(user, %{
        name: "The Tidewatch",
        member_ids: ["1", "2"],
        facts: [%Fact{statement: "They keep the bell.", concealed: true}]
      })

      camp =
        Library.put(%{
          owner: Owner.of(user),
          kind: "campaign",
          payload: %{kind: :campaign, name: "Camp", character_ids: [], scenes: []}
        })

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")

      assert html =~ "The Tidewatch"
      assert html =~ "2 members · seeds new people · 1 secret"
    end
  end

  describe "writing one" do
    test "name, prose and facts persist", %{conn: conn, user: user} do
      entry = group(user)
      {:ok, view, _html} = live(conn, ~p"/authoring/group/#{entry.id}")

      view |> element(~s(button[phx-click="panel"][phx-value-panel="facts"])) |> render_click()

      view
      |> form("#group-fact-form", %{statement: "They keep the tide bell."})
      |> render_submit()

      view
      |> form("#group-form", %{name: "The Tidewatch", b_premise: ["Half constabulary."]})
      |> render_submit()

      saved = group_of(entry)
      assert saved.name == "The Tidewatch"
      assert saved.premise =~ "Half constabulary."
      assert [%Fact{statement: "They keep the tide bell.", concealed: false}] = saved.facts
    end

    test "a fact can be made a secret, which is what membership then grants",
         %{conn: conn, user: user} do
      entry = group(user, %{facts: [%Fact{statement: "The ledger is under the bell."}]})
      {:ok, view, _html} = live(conn, ~p"/authoring/group/#{entry.id}")

      view
      |> element(~s(button[phx-click="toggle_secret"][phx-value-index="0"]))
      |> render_click()

      view |> form("#group-form", %{name: "The Tidewatch"}) |> render_submit()

      # The same control as a world's rules and a character's facts (§04) — and here
      # it is also the list an audience naming this group resolves to.
      assert [%Fact{concealed: true}] = group_of(entry).facts
    end

    test "editing the template does not touch its members", %{conn: conn, user: user} do
      wren = character(user, "Wren")
      entry = group(user, %{member_ids: [to_string(wren.id)]})

      {:ok, view, _html} = live(conn, ~p"/authoring/group/#{entry.id}")
      view |> element(~s(button[phx-click="panel"][phx-value-panel="facts"])) |> render_click()

      view
      |> form("#group-fact-form", %{statement: "They answer to the office now."})
      |> render_submit()

      view |> form("#group-form", %{name: "The Tidewatch"}) |> render_submit()

      # Seeding is a copy, so a member is a separate person with a separate sheet.
      # Saving must reach nobody — that is the whole reason telling them is its own act.
      assert Library.payload(Library.get(wren.id)).facts in [nil, []]
      assert pending_for(wren.id, "character") == []
    end
  end

  describe "telling the members" do
    test "one change becomes a proposal for the group and one for each member",
         %{conn: conn, user: user} do
      wren = character(user, "Wren")
      bram = character(user, "Bram")

      entry =
        group(user, %{
          member_ids: [to_string(wren.id), to_string(bram.id)],
          facts: [%Fact{statement: "They answer to the harbour office now."}]
        })

      {:ok, view, _html} = live(conn, ~p"/authoring/group/#{entry.id}")

      view |> element(~s(button[phx-click="tell"][phx-value-index="0"])) |> render_click()
      html = view |> element(~s(button[phx-click="tell_members"])) |> render_click()

      # 1 + n: the group's own arc, filed under its own subject type so a pending group
      # change doesn't block a scene the group isn't in, and one per member.
      assert pending_for(entry.id, "group") != []
      assert pending_for(wren.id, "character") != []
      assert pending_for(bram.id, "character") != []

      assert html =~ "Proposed to 2 member(s)"
    end

    test "nothing is written to anyone — they are proposals", %{conn: conn, user: user} do
      wren = character(user, "Wren")

      entry =
        group(user, %{
          member_ids: [to_string(wren.id)],
          facts: [%Fact{statement: "They answer to the harbour office now."}]
        })

      {:ok, view, _html} = live(conn, ~p"/authoring/group/#{entry.id}")
      view |> element(~s(button[phx-click="tell"][phx-value-index="0"])) |> render_click()
      view |> element(~s(button[phx-click="tell_members"])) |> render_click()

      # Six members means six things you can say yes or no to. Refusing one is how you
      # write the person who didn't go along with it — which only works if saying
      # nothing changes nothing.
      assert Library.payload(Library.get(wren.id)).facts in [nil, []]
      assert [%{status: "proposed"} | _] = pending_for(wren.id, "character")
    end

    test "an empty group says so rather than proposing to nobody", %{conn: conn, user: user} do
      entry = group(user, %{facts: [%Fact{statement: "Something changed."}]})
      {:ok, view, _html} = live(conn, ~p"/authoring/group/#{entry.id}")

      view |> element(~s(button[phx-click="tell"][phx-value-index="0"])) |> render_click()
      html = view |> element(~s(button[phx-click="tell_members"])) |> render_click()

      assert html =~ "Nobody is in this group yet."
      assert pending_for(entry.id, "group") == []
    end
  end

  describe "the card it was all for" do
    test "arc review shows the collapsed group card, which could never populate before",
         %{conn: conn, user: user} do
      wren = character(user, "Wren")

      camp =
        Library.put(%{
          owner: Owner.of(user),
          kind: "campaign",
          payload: %{
            kind: :campaign,
            name: "Camp",
            character_ids: [wren.id],
            scenes: []
          }
        })

      entry =
        group(user, %{
          member_ids: [to_string(wren.id)],
          facts: [%Fact{statement: "They answer to the harbour office now."}]
        })

      {:ok, view, _html} = live(conn, ~p"/authoring/group/#{entry.id}")
      view |> element(~s(button[phx-click="tell"][phx-value-index="0"])) |> render_click()
      view |> element(~s(button[phx-click="tell_members"])) |> render_click()

      # `ArcReviewLive` has read `GroupArc.pending/2` and `counts/2` since it shipped,
      # and nothing ever called `fan_out/3` — so the card was built and unreachable.
      {:ok, _review, html} = live(conn, ~p"/arc/#{camp.id}")

      assert html =~ "The Tidewatch"
      assert html =~ "They answer to the harbour office now."
    end
  end

  describe "membership" do
    test "is shown, and someone can be taken out of it", %{conn: conn, user: user} do
      wren = character(user, "Wren")
      entry = group(user, %{member_ids: [to_string(wren.id)]})

      {:ok, view, html} = live(conn, ~p"/authoring/group/#{entry.id}")
      assert html =~ "Wren"

      view
      |> element(~s(button[phx-click="remove_member"][phx-value-id="#{wren.id}"]))
      |> render_click()

      assert Groups.member_ids(entry.id) == []
      # Leaving takes nothing away: what they learned from the group is theirs now.
      assert Library.get(wren.id)
    end

    test "an empty one is a legitimate thing to have", %{conn: conn, user: user} do
      entry = group(user)
      {:ok, _view, html} = live(conn, ~p"/authoring/group/#{entry.id}")

      # The design's point: empty groups are how you set a trap before anyone walks
      # into it, so this is an explanation rather than a warning.
      assert html =~ "Nobody is in it yet."
      assert html =~ "set a trap before anyone walks into it"
    end
  end
end

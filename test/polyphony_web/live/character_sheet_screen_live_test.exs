defmodule PolyphonyWeb.CharacterSheetScreenLiveTest do
  @moduledoc """
  The character sheet as `ux/polyphony-character.html` draws it — the parts of the
  port that are decisions rather than markup.

  Four of them are worth a test, because each one is a rule someone could
  reasonably "tidy" back into the thing it replaced:

    * **facts compose two flags that don't collapse.** Always-in-mind is whether
      *she* carries it; secret is who *else* has it. Only one can own the left
      border, so secret takes the structure and always-in-mind is a chip — and a
      fact can be both.
    * **pressure is two lists.** Direction lives in the grouping, not the wording.
    * **the cover keeps its secrets, or isn't kept.** The one generation whose input
      deliberately exceeds its permitted output.
    * **tier is a second axis**, saved on tap and independent of whether the sheet
      is written.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Groups, Library}
  alias Polyphony.Owner
  alias Polyphony.Authoring.{CharacterSheet, Group}
  alias Polyphony.Authoring.CharacterSheet.{Boundary, Fact}

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp character(user, sheet),
    do: Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})

  defp open_panel(view, panel) do
    view |> element("button[phx-click=panel][phx-value-panel=#{panel}]") |> render_click()
    view
  end

  defp sheet_of(entry), do: Library.payload(Library.get(entry.id))

  describe "the identity line" do
    test "carries the tier, pronouns, world and how many scenes they've been in",
         %{conn: conn, user: user} do
      entry =
        character(user, %CharacterSheet{
          name: "Wren Ashgrove",
          pronouns: "she / her",
          tier: :recurring,
          status: :full
        })

      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      assert html =~ "Wren Ashgrove"
      assert html =~ "Recurring"
      assert html =~ "she / her"
      # Nobody has played, so the honest answer is zero rather than a missing pill.
      assert html =~ "In 0 scenes"
    end

    test "\"Main cast\" carries an info affordance, because it doesn't mean what it says",
         %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "Wren", status: :full})
      {:ok, view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      assert html =~ ~s(aria-label="About cast tiers")

      html = view |> element("button[phx-value-section=tier]") |> render_click()
      assert html =~ "Loaded only for the scenes they appear in"
    end
  end

  describe "tier" do
    test "is set on tap and saved at once, without touching the sheet's status",
         %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "The bellman", status: :stub})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view |> element("button[phx-click=set_tier][phx-value-tier=recurring]") |> render_click()

      saved = sheet_of(entry)
      assert saved.tier == :recurring
      assert saved.status == :stub, "tiering is a separate axis from whether the sheet is written"
    end
  end

  test "the groups card says which kind of belonging it means", %{conn: conn, user: user} do
    entry = character(user, %CharacterSheet{name: "Wren", status: :full})
    {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

    # "They belong to" on its own reads as an open question — to what? The sheet has
    # a world, a cast tier and a campaign, and only one of those is this card.
    assert html =~ "Groups they belong to"
  end

  describe "facts" do
    test "the two flags compose, and secret owns the structure", %{conn: conn, user: user} do
      sheet = %CharacterSheet{
        name: "Wren",
        status: :full,
        facts: [
          %Fact{statement: "She reads a manifest upside down."},
          %Fact{statement: "Her mother didn't die of the fever.", concealed: true, core: true}
        ]
      }

      entry = character(user, sheet)
      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      assert html =~ "She reads a manifest upside down."
      # The secret takes the left rule; always-in-mind is a chip, so both can show.
      assert html =~ ~s(class="secret min-w-0 flex-1")
      assert html =~ ~s(class="chip-core")
    end

    test "each flag toggles on its own — a secret she rarely thinks about is a real state",
         %{conn: conn, user: user} do
      entry =
        character(user, %CharacterSheet{
          name: "Wren",
          status: :full,
          facts: [%Fact{statement: "She signed for the Kestrel."}]
        })

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view
      |> element("button[phx-click=toggle_fact][phx-value-index='0'][phx-value-flag=concealed]")
      |> render_click()

      view |> form("form[phx-submit=save]", %{name: "Wren"}) |> render_submit()

      assert [%Fact{concealed: true, core: false}] = sheet_of(entry).facts
    end

    test "generate-all drafts facts onto an empty sheet, and leaves a written one alone",
         %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "Wren", status: :full})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view
      |> form("form[phx-submit=generate_all]", %{brief: "a harbor-master"})
      |> render_submit()

      generate(view)
      view |> form("form[phx-submit=save]", %{name: "Wren"}) |> render_submit()

      # "What's true about them" was generated by `Autofill` and dropped: a
      # quick-built or generated character arrived with none at all.
      assert [_ | _] = drafted = sheet_of(entry).facts
      assert Enum.all?(drafted, &(&1.concealed == false and String.trim(&1.statement) != ""))

      written = %CharacterSheet{
        name: "Ivo",
        status: :full,
        facts: [%Fact{statement: "He kept the ledger.", concealed: true}]
      }

      other = character(user, written)
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{other.id}")

      # The one-line card folds away once there is a sheet here — it leads on a blank
      # character and would be clutter on a written one — so this reopens it.
      view |> element("button[phx-click=toggle_brief]") |> render_click()

      view |> form("form[phx-submit=generate_all]", %{brief: "a clerk"}) |> render_submit()
      generate(view)
      view |> form("form[phx-submit=save]", %{name: "Ivo"}) |> render_submit()

      # Appending to facts somebody has already written and marked would be a second
      # author rather than a first draft — and would quietly un-hide a secret's place
      # in a list the author ordered.
      assert [%Fact{statement: "He kept the ledger.", concealed: true}] = sheet_of(other).facts
    end

    test "the one-line brief leads on a blank character and folds away on a written one",
         %{conn: conn, user: user} do
      blank = character(user, %CharacterSheet{name: "New character", status: :stub})
      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{blank.id}")

      # It used to sit several screens down, under the fields it fills — the wrong way
      # round on a blank sheet, where not starting with the fields is the whole point.
      # The world bible and the mock's own new-character flow both lead with it.
      assert html =~ "Who are they, in a line"
      assert :binary.match(html, "sheet-generate-all") < :binary.match(html, ~s(id="sheet-form"))

      written =
        character(user, %CharacterSheet{
          name: "Wren",
          status: :full,
          premise: "The harbourmaster's daughter."
        })

      {:ok, view, html} = live(conn, ~p"/authoring/character/#{written.id}")

      # Dead weight from this character's second day, so it folds — and says how to get
      # it back rather than vanishing.
      refute html =~ ~s(id="sheet-generate-all")
      assert html =~ "✦ Write it from a line"

      html = view |> element("button[phx-click=toggle_brief]") |> render_click()
      assert html =~ ~s(id="sheet-generate-all")
    end

    test "a fact's menu opens in the flow, where a sheet cannot clip it",
         %{conn: conn, user: user} do
      entry =
        character(user, %CharacterSheet{
          name: "Wren",
          status: :full,
          facts: [%Fact{statement: "She signed for the Kestrel."}]
        })

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      # The kit's `.sheet` is `overflow:hidden` — it is what rounds the corners — so an
      # absolutely-positioned menu was clipped by the sheet's bottom edge, and the last
      # facts on a sheet were the ones whose menus you could not read. This is one
      # control in three places (§04), so it is fixed the same way in each: the world
      # bible's lists have the same test.
      refute has_element?(view, "#fact-0 nav.absolute")
      refute has_element?(view, "#fact-0 nav.top-full")
      assert has_element?(view, "#fact-0 nav.sheet button[phx-click=toggle_fact]")

      # The whole row opens it, not the ⋯ alone — a fourteen-pixel target is not a
      # phone affordance.
      assert has_element?(view, "#fact-0 > summary", "She signed for the Kestrel.")
    end

    test "adding one goes through a panel, and persists on save", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "Wren", status: :full})
      {:ok, view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      refute html =~ ~s(phx-submit="add_fact")

      view
      |> open_panel("fact")
      |> form("form[phx-submit=add_fact]", %{statement: "She has done the job eleven years."})
      |> render_submit()

      view |> form("form[phx-submit=save]", %{name: "Wren"}) |> render_submit()

      assert [%Fact{statement: "She has done the job eleven years."}] = sheet_of(entry).facts
    end

    test "✦ Suggest fills the list, flags included", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "Wren", status: :full})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view |> element("button[phx-click=suggest_facts]") |> render_click()
      html = generate(view)

      assert html =~ "Added"
      # The Mock returns all four flag combinations, so both treatments appear.
      assert html =~ ~s(class="secret min-w-0 flex-1")
      assert html =~ ~s(class="chip-core")
    end
  end

  describe "pressures" do
    test "a compulsion is written in its own words, in its own list",
         %{conn: conn, user: user} do
      sheet = %CharacterSheet{
        name: "Wren",
        status: :full,
        boundaries: [
          %Boundary{
            topic: "Cover for her father",
            direction: :compulsion,
            stance: :conditional,
            condition: "she sees what it cost",
            after_release: "She lets the silences sit."
          }
        ]
      }

      entry = character(user, sheet)
      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      assert html =~ "Cover for her father"
      # The compulsion's own left rule, and its own reading of the same gate.
      assert html =~ ~s(class="compel")
      assert html =~ "and now"
      assert html =~ "She lets the silences sit."
      # The refusal list is still drawn, empty — the grouping is the meaning.
      assert html =~ "Nothing gives."
    end

    test "a flagged item says what the campaign ceiling will do to it",
         %{conn: conn, user: user} do
      sheet = %CharacterSheet{
        name: "Wren",
        status: :full,
        boundaries: [
          %Boundary{topic: "Anything to do with the drowned", category: :graphic_violence}
        ]
      }

      entry = character(user, sheet)
      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      assert html =~ "Flagged as graphic violence"
    end

    test "adding one carries its direction through to the sheet", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "Wren", status: :full})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view
      |> open_panel("pressure")
      |> form("form[phx-submit=add_boundary]", %{
        topic: "Sign whatever is put in front of her",
        direction: "compulsion",
        stance: "closed"
      })
      |> render_submit()

      view |> form("form[phx-submit=save]", %{name: "Wren"}) |> render_submit()

      assert [%Boundary{direction: :compulsion}] = sheet_of(entry).boundaries
    end
  end

  describe "the cover" do
    test "generates from the sheet and lands in the field", %{conn: conn, user: user} do
      entry =
        character(user, %CharacterSheet{
          name: "Wren",
          premise: "She keeps the bell.",
          status: :full
        })

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view |> element("button[phx-click=generate_cover]") |> render_click()
      generate(view)

      view |> form("form[phx-submit=save]", %{name: "Wren"}) |> render_submit()
      assert sheet_of(entry).cover not in [nil, ""]
    end

    test "a draft that gives the secret away is refused, and says so",
         %{conn: conn, user: user} do
      secret = "Her mother did not die of the fever but was drowned by the harbour council"

      entry =
        character(user, %CharacterSheet{
          name: "Wren",
          status: :full,
          facts: [%Fact{statement: secret, concealed: true}]
        })

      # A provider that will only ever hand back the secret — two attempts, both leak.
      Application.put_env(:polyphony, :llm,
        provider: Polyphony.LLM.Stub,
        stub_response: {:ok, secret}
      )

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view |> element("button[phx-click=generate_cover]") |> render_click()
      html = generate(view)

      assert html =~ "kept giving away a secret"
      # The author sees their own secrets in the fact list — what must not happen is the
      # leaked draft landing in the cover, so that's what's checked.
      assert html =~ ~s(placeholder="The only part strangers see."></textarea>)
    end
  end

  describe "groups" do
    test "shows what they belong to, and joining doesn't rewrite them",
         %{conn: conn, user: user} do
      owner = Owner.of(user)

      group =
        Groups.create(owner, %Group{
          name: "The Tidewatch",
          campaign_id: "camp",
          premise: "They keep the bell.",
          facts: [%Fact{statement: "They ring for the tide.", concealed: true}]
        })

      entry = character(user, %CharacterSheet{name: "Wren", status: :full})
      {:ok, view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      assert html =~ "Nobody has a claim on them yet."

      html =
        view
        |> open_panel("group")
        |> form("form[phx-submit=join_group]", %{group_id: to_string(group.id)})
        |> render_submit()

      assert html =~ "The Tidewatch"
      assert Groups.member_ids(group.id) == [to_string(entry.id)]

      # Joining is membership and nothing else — she doesn't quietly gain its secrets.
      assert sheet_of(entry).facts == []
      assert sheet_of(entry).premise == nil
    end
  end

  describe "the shape of the screen" do
    test "one form owns the sheet; adding to a list opens a panel outside it",
         %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "Wren", status: :full})
      {:ok, view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      # Exactly one save form, and the add-forms are absent until asked for. A form
      # inside a form isn't a thing, which is why the panels exist.
      assert length(Regex.scan(~r/phx-submit="save"/, html)) == 1
      refute html =~ ~s(phx-submit="add_fact")
      refute html =~ ~s(phx-submit="add_boundary")
      refute html =~ ~s(phx-submit="add_relationship")

      html = render(open_panel(view, "fact"))
      assert html =~ ~s(phx-submit="add_fact")
      assert length(Regex.scan(~r/phx-submit="save"/, html)) == 1
    end

    test "the cover is part of the sheet's own form, and saves with it",
         %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "Wren", status: :full})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view
      |> form("form[phx-submit=save]", %{
        name: "Wren",
        cover: "A bell, and the woman who rings it."
      })
      |> render_submit()

      assert sheet_of(entry).cover == "A bell, and the woman who rings it."
    end
  end
end

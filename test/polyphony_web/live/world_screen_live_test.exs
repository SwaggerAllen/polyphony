defmodule PolyphonyWeb.WorldScreenLiveTest do
  @moduledoc """
  The world bible as `ux/polyphony-world.html` draws it — the decisions, not the markup.

  The one that matters most isn't visible on screen. Marking a rule or a canon entry
  secret keeps it out of every character's **prompt**, and the preview here renders
  through the same filter (`WorldBible.for_character/1`) the context path uses, so the
  two cannot drift. A second implementation of "what a character sees" is how a
  preview ends up telling you something reassuring that isn't true.

  The rest: the cover says what it was checked against, the template relationship
  (§2.5b) is stated rather than implied, a duplicate world name is refused at the
  field, and previewing is read-only because editing a filtered view is how someone
  deletes something they couldn't see.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.WorldBible
  alias Polyphony.Authoring.WorldBible.Entry

  @secret "The harbourmaster has been paid to lose paperwork."
  @public "Nobody has seen a customs inspector in nine years."

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp world(user, attrs \\ %{}) do
    bible = struct(%WorldBible{name: "Saltmarch"}, attrs)
    Library.put(%{owner: Owner.of(user), kind: "world_bible", payload: bible})
  end

  defp bible_of(entry), do: Library.payload(Library.get(entry.id))

  defp with_secret(user) do
    world(user, %{
      setting: "A port town on a tidal flat.",
      starting_canon: [
        %Entry{statement: @public},
        %Entry{statement: @secret, concealed: true}
      ]
    })
  end

  describe "secrets" do
    test "a marked entry reads as secret and persists that way", %{conn: conn, user: user} do
      entry = world(user, %{starting_canon: [%Entry{statement: @secret}]})
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      html =
        view
        |> element(
          "button[phx-click=toggle_secret][phx-value-field=starting_canon][phx-value-index='0']"
        )
        |> render_click()

      assert html =~ ~s(class="secret min-w-0 flex-1")

      view |> form("form[phx-submit=save]", %{name: "Saltmarch"}) |> render_submit()
      assert [%Entry{concealed: true}] = bible_of(entry).starting_canon
    end

    test "the same control sits on rules, because it's the same control",
         %{conn: conn, user: user} do
      entry = world(user, %{rules: [%Entry{statement: "No magic."}]})
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> element("button[phx-click=toggle_secret][phx-value-field=rules][phx-value-index='0']")
      |> render_click()

      view |> form("form[phx-submit=save]", %{name: "Saltmarch"}) |> render_submit()
      assert [%Entry{concealed: true}] = bible_of(entry).rules
    end
  end

  describe "preview" do
    test "shows only what a character would be told", %{conn: conn, user: user} do
      entry = with_secret(user)
      {:ok, view, html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      # Authoring is omniscient: the secret is on the page.
      assert html =~ @secret

      html = view |> form("#preview-form") |> render_change(%{"as" => "stranger"})

      assert html =~ @public
      refute html =~ @secret
      assert html =~ "read-only"
    end

    test "is the same filter the context path uses, not a second implementation",
         %{conn: conn, user: user} do
      entry = with_secret(user)
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      previewed = view |> form("#preview-form") |> render_change(%{"as" => "stranger"})

      prefix =
        Polyphony.Context.materialize(%{
          scene_id: "S1",
          character_id: "wren",
          sheet: %Polyphony.Authoring.CharacterSheet{name: "Wren"},
          world_bible: bible_of(entry)
        }).prefix

      for s <- WorldBible.public(bible_of(entry).starting_canon) do
        assert previewed =~ s
        assert prefix =~ s
      end

      refute previewed =~ @secret
      refute prefix =~ @secret
    end

    test "is read-only — there is nothing to edit or save while previewing",
         %{conn: conn, user: user} do
      entry = with_secret(user)
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      html = view |> form("#preview-form") |> render_change(%{"as" => "stranger"})

      refute html =~ ~s(phx-submit="save")
      refute html =~ ~s(phx-click="toggle_secret")
    end

    test "says how much is being held back, without saying what", %{conn: conn, user: user} do
      entry = with_secret(user)
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      html = view |> form("#preview-form") |> render_change(%{"as" => "stranger"})
      assert html =~ "One thing is held back"
      refute html =~ @secret
    end
  end

  describe "the cover" do
    test "says what it was checked against, not just that it was checked",
         %{conn: conn, user: user} do
      entry = with_secret(user)
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view |> element("button[phx-click=generate_cover]") |> render_click()
      html = generate(view)

      assert html =~ "Checked against your 1 secret"
    end

    test "a world with nothing to hide claims nothing", %{conn: conn, user: user} do
      entry = world(user, %{setting: "A port town.", cover: "A port town, and its debts."})
      {:ok, _view, html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      refute html =~ "Checked against"
    end

    test "leads with Write it when empty, and Rewrite once written",
         %{conn: conn, user: user} do
      {:ok, _view, empty} = live(conn, ~p"/authoring/bible/#{world(user).id}")
      assert empty =~ "✦ Write it"

      written = world(user, %{name: "Low Water", cover: "A town under the tide."})
      {:ok, _view, html} = live(conn, ~p"/authoring/bible/#{written.id}")
      assert html =~ "✦ Rewrite"
    end
  end

  describe "the template relationship (§2.5b)" do
    test "a template says how many campaigns were started from it", %{conn: conn, user: user} do
      entry = world(user)
      {:ok, _view, html} = live(conn, ~p"/authoring/bible/#{entry.id}")
      assert html =~ "gives that campaign its own copy"

      Library.copy(entry, Owner.of(user))
      {:ok, _view, html} = live(conn, ~p"/authoring/bible/#{entry.id}")
      assert html =~ "One campaign was started from this"
      assert html =~ "used in 1 campaign"
    end

    test "a copy says it has a history, and offers the one route back",
         %{conn: conn, user: user} do
      template = world(user, %{tone: "Damp"})
      copy = Library.copy(template, Owner.of(user))

      {:ok, view, html} = live(conn, ~p"/authoring/bible/#{copy.id}")
      assert html =~ "This is a copy"
      assert html =~ "Save a copy to your library"

      view |> element("button[phx-click=save_to_library]") |> render_click()

      # A snapshot, not a link: the saved entry points at the copy it was taken from.
      saved = Library.copies_of(copy.id)
      assert [%{derived_from_id: id}] = saved
      assert id == copy.id
    end
  end

  describe "the name" do
    test "a repeat is refused at the field rather than saved", %{conn: conn, user: user} do
      world(user, %{name: "Saltmarch"})
      other = world(user, %{name: "Low Water"})

      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{other.id}")

      html = view |> form("form[phx-submit=save]", %{name: "Saltmarch"}) |> render_submit()

      assert html =~ "You already have a world called Saltmarch"
      assert bible_of(other).name == "Low Water", "the clashing name must not have been saved"
    end

    test "the refusal is visible from the foot of the sheet, and points at the culprit",
         %{conn: conn, user: user} do
      salt = world(user, %{name: "Saltmarch"})
      other = world(user, %{name: "Low Water"})

      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{other.id}")

      html = view |> form("form[phx-submit=save]", %{name: "Saltmarch"}) |> render_submit()

      # Save is at the foot of a sheet several viewports tall and Name is at its head.
      # Marked only at the field, the refusal rendered where the author wasn't looking,
      # and pressing Save read as nothing happening at all — which is how a working
      # guard gets reported as "saving is broken".
      assert html =~ "Not saved under that name — you already have a world called Saltmarch"

      # The other world is routinely one nobody made on purpose (an interrupted Quick
      # Build persists its world before anything associates it), so "open that one" has
      # to be reachable rather than advice.
      assert has_element?(view, ~s(a[href="/authoring/bible/#{salt.id}"]), "open that one")
    end

    test "saving a world under its own name is not a clash", %{conn: conn, user: user} do
      entry = world(user, %{name: "Saltmarch"})
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      html = view |> form("form[phx-submit=save]", %{name: "Saltmarch"}) |> render_submit()

      refute html =~ "You already have a world"
      assert html =~ "✓ Saved"
    end
  end

  describe "sharing" do
    test "the link appears the moment unlisted is picked, not before",
         %{conn: conn, user: user} do
      entry = world(user)
      {:ok, view, html} = live(conn, ~p"/authoring/bible/#{entry.id}")
      refute html =~ "Share link"

      html =
        view
        |> element("button[phx-click=set_visibility][phx-value-visibility=unlisted]")
        |> render_click()

      assert html =~ "Share link"
      assert html =~ Library.get(entry.id).share_token
    end

    test "a new link breaks the old one", %{conn: conn, user: user} do
      entry = world(user)
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> element("button[phx-click=set_visibility][phx-value-visibility=unlisted]")
      |> render_click()

      old = Library.get(entry.id).share_token

      html = view |> element("button[phx-click=rotate_link]") |> render_click()

      refute html =~ old
      assert Library.get_by_share_token(old) == nil
    end
  end

  describe "the first-run card" do
    test "leads an empty world, and folds away once there's something here",
         %{conn: conn, user: user} do
      {:ok, _view, html} = live(conn, ~p"/authoring/bible/#{world(user).id}")
      assert html =~ "Describe it in a line"

      filled = world(user, %{name: "Low Water", setting: "A town under the tide."})
      {:ok, _view, html} = live(conn, ~p"/authoring/bible/#{filled.id}")
      refute html =~ "Describe it in a line"
      assert html =~ "✦ Write it from a line"
    end
  end
end

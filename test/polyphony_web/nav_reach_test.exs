defmodule PolyphonyWeb.NavReachTest do
  @moduledoc """
  Every screen in the app, and whether you can get off it.

  The design has **no persistent global chrome** — a screen fills the viewport and
  carries its own header — so the `☰` is not a layout that arrives for free. It is a
  thing each screen has to render, which means "every page has one" is a claim that
  decays silently as screens are added. This walks the router and asserts it.

  Five screens didn't have one, and they were the five with no `Kit.header/1`: the
  landing page and the four single-card screens (sign in, sign up, resume, and a shared
  link). Each looked navigable because it wrote a couple of links into its own copy, and
  the counting is what gives it away — `/s/:token` offered a stranger nothing at all,
  and the landing page offered a signed-in visitor no route to their settings or out of
  their account. `Layouts.corner_menu/1` pins the same menu to the frame's corner
  without giving a spare centred card a header row it doesn't want.

  The list below is the point of the test: adding a route and not adding it here is the
  only way to dodge it, and that is a visible omission in a diff rather than an
  invisible one on a screen.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Reading}
  alias Polyphony.Owner
  alias Polyphony.Authoring.{CharacterSheet, Group, WorldBible}
  alias Polyphony.Commands.OpenScene

  setup :register_and_log_in_user

  defp entry(user, kind, payload),
    do: Library.put(%{owner: Owner.of(user), kind: kind, payload: payload})

  # One of everything the router's dynamic segments need.
  defp fixtures(user) do
    sheet = entry(user, "character", %CharacterSheet{name: "Wren", status: :full})

    bible =
      entry(user, "world_bible", %WorldBible{name: "Saltmarch", rules: [], starting_canon: []})

    group = entry(user, "group", %Group{name: "The Tidewatch"})

    scene = "nav-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = Polyphony.App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    camp =
      entry(user, "campaign", %{
        kind: :campaign,
        name: "The Salt Line",
        character_ids: [sheet.id],
        bible_id: bible.id,
        scenes: [scene]
      })

    %{sheet: sheet, bible: bible, group: group, camp: camp, scene: scene}
  end

  # A shared link that renders the card rather than handing off to `/browse`, which is
  # what an unfrozen (still-being-written) campaign behind a share token does.
  defp share_token(user) do
    entry = entry(user, "campaign", %{kind: :campaign, name: "A draft", character_ids: []})
    {:ok, entry} = Library.set_visibility(entry.id, "unlisted")
    entry.share_token
  end

  defp assert_menu(conn, path) do
    case live(conn, path) do
      {:ok, _view, html} ->
        assert html =~ ~s(class="hamb"), "#{path} renders no ☰"
        assert html =~ ~s(aria-label="Menu"), "#{path}'s ☰ is unlabelled"

      other ->
        flunk("#{path} didn't render: #{inspect(other)}")
    end
  end

  test "every signed-in screen carries the ☰", %{conn: conn, user: user} do
    %{sheet: sheet, bible: bible, group: group, camp: camp, scene: scene} = fixtures(user)
    Reading.mark(Owner.of(user), camp.id, %{scene_id: scene})

    for path <- [
          ~p"/",
          ~p"/library",
          ~p"/settings",
          ~p"/browse",
          ~p"/campaigns/#{camp.id}",
          ~p"/play/#{scene}",
          ~p"/authoring/character/#{sheet.id}",
          ~p"/authoring/bible/#{bible.id}",
          ~p"/authoring/group/#{group.id}",
          ~p"/arc/#{camp.id}"
        ],
        do: assert_menu(conn, path)
  end

  test "and so does the admin screen", %{user: _user} do
    conn = log_in_user(build_conn(), user_fixture(%{role: "superadmin"}))

    assert_menu(conn, ~p"/admin")
  end

  test "so do the screens you reach without an account", %{user: user} do
    token = share_token(user)
    out = build_conn()

    # The four with no header, plus the landing page. `/s/:token` is the one that
    # mattered most: somebody arriving on a link somebody sent them is the person with
    # the least idea what this is and the fewest ways to find out.
    for path <- [~p"/", ~p"/login", ~p"/signup", ~p"/browse", ~p"/docs", ~p"/s/#{token}"],
        do: assert_menu(out, path)
  end

  test "including the one you only see on a remembered device", %{user: user} do
    # `/resume` redirects to `/login` without the remember cookie, so the cookie is the
    # fixture — and the only honest way to get an encrypted one is the route that mints
    # it, the same magic link an email carries.
    conn = get(build_conn(), ~p"/auth/verify/#{PolyphonyWeb.Auth.sign_token(user.id)}")

    assert_menu(conn, ~p"/resume")
  end

  test "the signed-out menu offers the ways in, and no account actions" do
    {:ok, _view, html} = live(build_conn(), ~p"/login")

    assert html =~ "Create an account"
    assert html =~ "Sign in"
    assert html =~ "Browse published"
    assert html =~ "What Polyphony is"
    refute html =~ "Sign out"
    refute html =~ "Your stuff"
  end
end

defmodule PolyphonyWeb.BrowseScreenLiveTest do
  @moduledoc """
  Browse and the published reading view as `ux/polyphony-browse.html` draws them.

  The assertion that matters most is the one a reader would never see fail: **the same
  scene from two heads, each missing what the other knew.** Everything else on this
  screen is arrangement; that is the product.

  The rest: choosing how to read comes before reading, an action that isn't available
  isn't shown (no greyed-out buttons, no "request access"), reading never hits a wall
  for a signed-out visitor, and the moderation queue finally has a way in.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Library, Moderation, Owner, Reading}
  alias Polyphony.Authoring.WorldBible
  alias Polyphony.Commands.{CommitPacket, EnterCharacter, OpenScene}
  alias Polyphony.Library.Snapshot
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.{Move, SelfState}

  @halden "c-halden"
  @ruthe "c-ruthe"

  setup :register_and_log_in_user

  defp stair do
    scene = "sc-" <> Integer.to_string(System.unique_integer([:positive]))

    :ok =
      App.dispatch(%OpenScene{scene_id: scene, location_id: "The stair at Ninth", opened_beat: 0})

    for id <- [@halden, @ruthe] do
      :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: id, beat: 1})
    end

    commit(scene, @ruthe, %TurnPacket{
      moves: [
        %Move{seq: 1, type: :action, content: "She puts out the lamp."},
        %Move{seq: 2, type: :thought, content: "Eleven years she has had the answer ready."}
      ],
      self_state: %SelfState{demeanor: "still"}
    })

    commit(scene, @halden, %TurnPacket{
      moves: [
        %Move{seq: 1, type: :speech, content: "I know you're there.", audibility: :normal},
        %Move{seq: 2, type: :thought, content: "He does not know."}
      ],
      self_state: %SelfState{demeanor: "easy"}
    })

    scene
  end

  defp commit(scene, char, packet) do
    :ok =
      App.dispatch(%CommitPacket{
        scene_id: scene,
        character_id: char,
        beat: 2,
        packet_id: "#{scene}-2-#{char}",
        packet: packet
      })
  end

  defp publish(author, scene, pub_attrs, extra \\ %{}) do
    snapshot =
      Snapshot.build(
        Map.merge(
          %{
            campaign_id: "camp",
            publication: pub_attrs,
            bible: %WorldBible{name: "The Ninth Gate", cover: "A city with no sky."},
            scenes: [
              %{id: scene, title: "The stair at Ninth", cast: [@halden, @ruthe], beats: 2}
            ],
            characters: [
              %{source_id: @halden, source_version: 1, sheet: %{name: "Halden Voss", hue: 2}},
              %{source_id: @ruthe, source_version: 1, sheet: %{name: "Ruthe Kell", hue: 1}}
            ]
          },
          extra
        )
      )

    Library.put(%{
      owner: Owner.of(author),
      kind: "campaign",
      visibility: "public",
      frozen: true,
      payload: snapshot
    })
  end

  describe "the catalogue" do
    test "leads with what a story is about and how you're allowed to read it", %{conn: conn} do
      author = user_fixture()
      publish(author, stair(), %{perspectives: [@halden, @ruthe], forkable: true})

      {:ok, _view, html} = live(conn, ~p"/browse")

      assert html =~ "The Ninth Gate"
      assert html =~ "A city with no sky."
      assert html =~ "2 heads"
      assert html =~ "Forkable"
      assert html =~ "1 scene"
    end

    test "spectator-only says so rather than showing nothing", %{conn: conn} do
      publish(user_fixture(), stair(), %{perspectives: [], spectator: true})

      {:ok, _view, html} = live(conn, ~p"/browse")

      assert html =~ "Spectator only"
      refute html =~ "Forkable"
    end

    test "nothing published points back at your own stuff", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/browse")

      assert html =~ "Nobody&#39;s published anything yet."
      assert html =~ "Go to your stuff"
    end

    test "a world can be taken on its own, and only its cover is shown", %{conn: conn} do
      entry =
        Library.put(%{
          owner: Owner.of(user_fixture()),
          kind: "world_bible",
          visibility: "public",
          payload: %WorldBible{
            name: "Saltmarch",
            cover: "A port town that runs on tides.",
            setting: "THE SECRET INTERNALS"
          }
        })

      {:ok, _view, html} = live(conn, ~p"/browse?tab=worlds")

      assert html =~ "Saltmarch"
      assert html =~ "A port town that runs on tides."
      # The cover is written under instruction to give the secrets away to nobody
      # (§2.12); the bible itself never leaves the author's library.
      refute html =~ "THE SECRET INTERNALS"
      assert html =~ "phx-value-id=\"#{entry.id}\""
    end
  end

  describe "a story's front page" do
    test "choosing how to read comes before reading", %{conn: conn} do
      author = user_fixture()
      story = publish(author, stair(), %{perspectives: [@halden, @ruthe]})

      {:ok, _view, html} = live(conn, ~p"/browse?#{[story: story.id]}")

      assert html =~ "How you can read it"
      assert html =~ "Everyone @#{author.username} shared"
      assert html =~ "As a spectator"
      assert html =~ "As Halden Voss"
      assert html =~ "Start reading"
    end

    test "an unshared head is named as a count, not left as an absence", %{conn: conn} do
      story =
        publish(user_fixture(), stair(), %{perspectives: [@halden]}, %{
          characters: [
            %{source_id: @halden, source_version: 1, sheet: %{name: "Halden Voss"}},
            %{source_id: @ruthe, source_version: 1, sheet: %{name: "Ruthe Kell"}}
          ]
        })

      {:ok, _view, html} = live(conn, ~p"/browse?#{[story: story.id]}")

      assert html =~ "hasn&#39;t shared everyone"
      assert html =~ "One more person is in this and you don&#39;t get their side."
    end

    test "an action that isn't available simply isn't shown", %{conn: conn} do
      story = publish(user_fixture(), stair(), %{perspectives: [@halden], forkable: false})

      {:ok, _view, html} = live(conn, ~p"/browse?#{[story: story.id]}")

      refute html =~ "Make it mine"
      assert html =~ "shared this to be read"
      # No greyed-out buttons and no request-access.
      refute html =~ "request access"
    end

    test "a forkable story offers to be carried on", %{conn: conn} do
      story = publish(user_fixture(), stair(), %{perspectives: [@halden], forkable: true})

      {:ok, _view, html} = live(conn, ~p"/browse?#{[story: story.id]}")
      assert html =~ "Make it mine"
    end

    test "forking puts a copy in your library and leaves the original alone", %{
      conn: conn,
      user: user
    } do
      story = publish(user_fixture(), stair(), %{perspectives: [@halden], forkable: true})

      {:ok, view, _html} = live(conn, ~p"/browse?#{[story: story.id]}")
      view |> element("button[phx-click=fork]") |> render_click()

      assert [copy] = Library.list_for_owner(Owner.of(user))
      assert copy.derived_from_id == story.id
      assert copy.root_id == story.id
      # Ilse's version stays exactly as it is.
      assert Library.get(story.id).visibility == "public"
    end
  end

  describe "taking the world out of a story" do
    test "copies the setting and leaves what the author kept back", %{conn: conn, user: user} do
      bible = %WorldBible{
        name: "The Ninth Gate",
        cover: "A city with no sky.",
        rules: [
          %WorldBible.Entry{statement: "Nobody walks the stair twice."},
          %WorldBible.Entry{statement: "The ninth district is a lie.", concealed: true}
        ]
      }

      story = publish(user_fixture(), stair(), %{perspectives: [@halden]}, %{bible: bible})

      {:ok, view, _html} = live(conn, ~p"/browse?#{[story: story.id]}")
      view |> element("button[phx-click=take_story_world]") |> render_click()

      assert [copy] = Library.list_for_owner(Owner.of(user))
      taken = Library.payload(copy)

      assert taken.name == "The Ninth Gate"
      assert WorldBible.statements(taken.rules) == ["Nobody walks the stair twice."]
      # The one that matters: a secret doesn't travel with the setting.
      refute "The ninth district is a lie." in WorldBible.statements(taken.rules)
    end

    test "and the offer says so rather than implying it away", %{conn: conn} do
      story = publish(user_fixture(), stair(), %{perspectives: [@halden], forkable: false})

      {:ok, _view, html} = live(conn, ~p"/browse?#{[story: story.id]}")

      assert html =~ "Use this world"
      assert html =~ "take the world and write your own people into it"
    end
  end

  describe "the same scene, twice" do
    test "each head reads their own story and misses the other's", %{conn: conn} do
      scene = stair()
      story = publish(user_fixture(), scene, %{perspectives: [@halden, @ruthe]})

      {:ok, _v, as_halden} =
        live(conn, ~p"/browse?#{[story: story.id, scene: scene, as: @halden]}")

      {:ok, _v, as_ruthe} =
        live(conn, ~p"/browse?#{[story: story.id, scene: scene, as: @ruthe]}")

      assert as_halden =~ "He does not know."
      refute as_halden =~ "Eleven years she has had the answer ready."

      assert as_ruthe =~ "Eleven years she has had the answer ready."
      refute as_ruthe =~ "He does not know."

      # And what was said aloud is in both, so the story still hangs together.
      assert as_halden =~ "I know you&#39;re there."
      assert as_ruthe =~ "I know you&#39;re there."
    end

    test "everyone-shared blends both heads", %{conn: conn} do
      scene = stair()
      story = publish(user_fixture(), scene, %{perspectives: [@halden, @ruthe]})

      {:ok, _v, html} =
        live(conn, ~p"/browse?#{[story: story.id, scene: scene, as: "limited"]}")

      assert html =~ "He does not know."
      assert html =~ "Eleven years she has had the answer ready."
    end

    test "spectator gets everything said and done and nobody's thoughts", %{conn: conn} do
      scene = stair()
      story = publish(user_fixture(), scene, %{perspectives: [@halden, @ruthe]})

      {:ok, _v, html} =
        live(conn, ~p"/browse?#{[story: story.id, scene: scene, as: "spectator"]}")

      assert html =~ "I know you&#39;re there."
      assert html =~ "She puts out the lamp."
      refute html =~ "He does not know."
      refute html =~ "Eleven years she has had the answer ready."
    end

    test "a perspective the author kept back falls back rather than opening", %{conn: conn} do
      scene = stair()
      story = publish(user_fixture(), scene, %{perspectives: [@halden]})

      # Naming Ruthe in the URL is not a grant.
      {:ok, _v, html} = live(conn, ~p"/browse?#{[story: story.id, scene: scene, as: @ruthe]}")

      refute html =~ "Eleven years she has had the answer ready."
    end
  end

  describe "the two kinds of empty" do
    test "they weren't there — and the way out is the control already on screen", %{conn: conn} do
      scene = stair()

      story =
        publish(user_fixture(), scene, %{perspectives: [@halden, @ruthe]}, %{
          scenes: [
            %{id: scene, title: "The stair at Ninth", cast: [@halden, @ruthe], beats: 2},
            %{id: "sixth", title: "Sixth", cast: [@ruthe], beats: 5}
          ]
        })

      {:ok, _v, html} = live(conn, ~p"/browse?#{[story: story.id, scene: "sixth", as: @halden]}")

      assert html =~ "Halden Voss wasn&#39;t here."
      assert html =~ "afterwards, from someone else"
      # And Next carries on for a reader who only wants Halden's story.
      assert html =~ "Scene 2 of 2"
    end

    test "nobody's side was shared — shown rather than skipped", %{conn: conn} do
      scene = stair()

      story =
        publish(user_fixture(), scene, %{perspectives: [@halden], spectator: false}, %{
          scenes: [
            %{id: scene, title: "The stair at Ninth", cast: [@halden], beats: 2},
            %{id: "after", title: "The counting house, after", cast: ["c-ada"], beats: 3}
          ]
        })

      {:ok, _v, html} = live(conn, ~p"/browse?#{[story: story.id, scene: "after"]}")

      assert html =~ "This one isn&#39;t shared."
      # Silently omitting it would make the numbering lie.
      assert html =~ "Scene 2 of 2"
    end

    test "the contents list marks what you can't reach rather than hiding it", %{conn: conn} do
      scene = stair()

      story =
        publish(user_fixture(), scene, %{perspectives: [@halden, @ruthe]}, %{
          scenes: [
            %{id: scene, title: "The stair at Ninth", cast: [@halden, @ruthe], beats: 2},
            %{id: "sixth", title: "Sixth", cast: [@ruthe], beats: 5}
          ]
        })

      {:ok, _v, html} = live(conn, ~p"/browse?#{[story: story.id, as: @halden]}")

      assert html =~ "Sixth"
      assert html =~ "Halden Voss wasn&#39;t here"
    end
  end

  describe "keeping your place" do
    test "reading a scene records where you were and who you were" do
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: Phoenix.ConnTest.build_conn()})
      scene = stair()
      story = publish(user_fixture(), scene, %{perspectives: [@halden, @ruthe]})

      {:ok, _v, _html} = live(conn, ~p"/browse?#{[story: story.id, scene: scene, as: @ruthe]}")

      assert {^scene, _beat, @ruthe} = Reading.resume(Owner.of(user), story.id)
    end
  end

  describe "reporting" do
    test "the moderation queue finally has a way in", %{conn: conn, user: user} do
      author = user_fixture()
      story = publish(author, stair(), %{perspectives: [@halden]})

      {:ok, view, _html} = live(conn, ~p"/browse?#{[story: story.id]}")

      opened = view |> element("button[phx-click=report]") |> render_click()
      assert opened =~ "Sexual content involving minors"
      assert opened =~ "A person reads every one of these."

      view
      |> form("#report-form", %{reason: "harassment", detail: "please look"})
      |> render_submit()

      assert [report] = Moderation.list_open()
      assert report.reason == "harassment"
      # Targets the frozen snapshot, so a take-down leaves the author's original alone.
      assert report.item_id == story.id
      assert report.reporter_id == user.id
    end
  end

  describe "carrying on" do
    test "the library links straight back to the scene, in the head they were in", %{conn: conn} do
      scene = stair()
      story = publish(user_fixture(), scene, %{perspectives: [@halden, @ruthe]})

      # Read a scene as Ruthe…
      {:ok, _v, _html} = live(conn, ~p"/browse?#{[story: story.id, scene: scene, as: @ruthe]}")

      # …then come at it from the shelf.
      {:ok, _v, shelf} = live(conn, ~p"/library?tab=reading")

      # Named by its world, not rendered "Untitled campaign" — a snapshot has no
      # `:name`, and asking it for one is how a titled story loses its title.
      assert shelf =~ "The Ninth Gate"
      assert shelf =~ "As Ruthe Kell"
      assert shelf =~ "Carry on reading"
      assert shelf =~ "story=#{story.id}"
      assert shelf =~ "scene=#{scene}"
      assert shelf =~ "as=#{@ruthe}"

      {:ok, _v, back} = live(conn, ~p"/browse?#{[story: story.id, scene: scene, as: @ruthe]}")
      # Her interiority, not his — the same story they left.
      assert back =~ "Eleven years she has had the answer ready."
      refute back =~ "He does not know."
    end

    test "the front page picks up where they were rather than at the beginning", %{conn: conn} do
      scene = stair()

      story =
        publish(user_fixture(), scene, %{perspectives: [@halden, @ruthe]}, %{
          scenes: [
            %{id: "first", title: "Before", cast: [@halden, @ruthe], beats: 1},
            %{id: scene, title: "The stair at Ninth", cast: [@halden, @ruthe], beats: 2}
          ]
        })

      {:ok, _v, fresh} = live(conn, ~p"/browse?#{[story: story.id]}")
      assert fresh =~ "Start reading"
      refute fresh =~ "Carry on reading"

      {:ok, _v, _} = live(conn, ~p"/browse?#{[story: story.id, scene: scene, as: @ruthe]}")
      {:ok, _v, returning} = live(conn, ~p"/browse?#{[story: story.id]}")

      assert returning =~ "Carry on reading"
      assert returning =~ "You were on scene 2 of 2, as Ruthe Kell."
      # And the perspective comes back with it — a bookmark beats a default.
      assert returning =~ "scene=#{scene}"
      assert returning =~ "as=#{@ruthe}"
    end

    test "a perspective the author has since withdrawn falls back rather than opening", %{
      conn: conn,
      user: user
    } do
      scene = stair()
      story = publish(user_fixture(), scene, %{perspectives: [@halden, @ruthe]})
      {:ok, _v, _} = live(conn, ~p"/browse?#{[story: story.id, scene: scene, as: @ruthe]}")

      # The author republishes without Ruthe. The bookmark still names her.
      narrowed = publish(user_fixture(), scene, %{perspectives: [@halden]})
      Reading.mark(Owner.of(user), narrowed.id, %{scene_id: scene, perspective: @ruthe})

      {:ok, _v, html} = live(conn, ~p"/browse?#{[story: narrowed.id, scene: scene]}")

      # The link carries an intent, never an authorization.
      refute html =~ "Eleven years she has had the answer ready."
    end

    test "a bookmarked scene that's gone falls back to the beginning", %{conn: conn, user: user} do
      scene = stair()
      story = publish(user_fixture(), scene, %{perspectives: [@halden]})
      Reading.mark(Owner.of(user), story.id, %{scene_id: "a-scene-since-removed"})

      {:ok, _v, html} = live(conn, ~p"/browse?#{[story: story.id]}")

      # Rather than linking into nothing.
      assert html =~ "scene=#{scene}"
    end
  end

  describe "an unlisted share link" do
    test "is a grant, so it opens the reading surface rather than a card", %{conn: conn} do
      story = publish(user_fixture(), stair(), %{perspectives: [@halden]})
      {:ok, entry} = Library.set_visibility(story.id, "unlisted")

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/s/#{entry.share_token}")
      assert to =~ "/browse?story=#{story.id}"
    end

    test "a hidden one leads nowhere, and doesn't say which kind of nowhere", %{conn: conn} do
      story = publish(user_fixture(), stair(), %{perspectives: [@halden]})
      {:ok, entry} = Library.set_visibility(story.id, "unlisted")
      {:ok, _} = Library.hide(entry.id, "suspended")

      {:ok, _view, html} = live(conn, ~p"/s/#{entry.share_token}")

      assert html =~ "doesn&#39;t lead anywhere any more"
      refute html =~ "suspended"
    end
  end

  describe "signed out" do
    test "reading is open to anyone; only the actions need an account" do
      conn = Phoenix.ConnTest.build_conn()
      scene = stair()
      story = publish(user_fixture(), scene, %{perspectives: [@halden]})

      {:ok, _v, html} = live(conn, ~p"/browse?#{[story: story.id, scene: scene, as: @halden]}")

      assert html =~ "I know you&#39;re there."
      assert html =~ "Reading is open to anyone."
      assert html =~ "Sign in"
    end
  end
end

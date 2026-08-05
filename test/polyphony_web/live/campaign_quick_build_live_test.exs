defmodule PolyphonyWeb.CampaignQuickBuildLiveTest do
  @moduledoc """
  The campaign editor's Quick Build (scaffold a world, cast & premise in one shot), the
  premise ✨ Expand button, and the edit links that jump into the world / character
  editors. Driven by the offline Mock so generation is deterministic.

  Quick Build is an **Oban job** rather than a `start_async` — see
  `Polyphony.Jobs.QuickBuild` for why — so these tests submit the form and then drain
  the queue. The screen's job is to start it and watch it; the build's job is to finish
  whether or not anyone is watching, which is the thing worth pinning here.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.{CharacterSheet, WorldBible}

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp campaign(user, attrs \\ %{}) do
    payload =
      Map.merge(
        %{kind: :campaign, name: "Camp", character_ids: [], bible_id: nil, scenes: []},
        attrs
      )

    Library.put(%{owner: Owner.of(user), kind: "campaign", payload: payload})
  end

  # Quick Build is a first-run card rather than a tab: a one-shot that would be dead
  # weight from a campaign's second day. It opens on request.
  defp open_quick_build(view),
    do: view |> element("button[phx-click=toggle_quick_build]") |> render_click()

  # Oban runs `testing: :manual`, so the enqueued build executes when the test says so.
  # That separation is the point: the form submit and the work are no longer one act.
  defp drain, do: Oban.drain_queue(queue: :generation, with_scheduled: true)

  # A build retries (`max_attempts: 3`) and resumes rather than restarting, so getting to
  # a *failed* run means exhausting the attempts.
  defp drain_to_failure, do: Enum.each(1..3, fn _ -> drain() end)

  test "quick build scaffolds a world, cast, and premise onto the campaign",
       %{conn: conn, user: user} do
    camp = campaign(user)
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}")
    open_quick_build(view)

    # Add a second character row (starts with one), then submit both.
    view |> element("button[phx-click=add_seed]") |> render_click()

    view
    |> form("#quick-build", %{
      "world_seed" => "a rain-drowned harbor city",
      "char_seed" => ["a disgraced harbor-master", "the collector who bought her past"]
    })
    |> render_submit()

    drain()

    payload = Library.payload(Library.get(camp.id))
    # A world and two characters are attached, and a premise was drafted.
    assert payload[:bible_id]
    assert payload[:premise] not in [nil, ""]

    sheets = Enum.map(payload[:character_ids], &Library.payload(Library.get(&1)))
    {cast, walk_ons} = Enum.split_with(sheets, &(&1.status == :full))

    assert length(cast) == 2

    # The off-screen people the cast introduced are on the roster too. They are this
    # story's walk-ons — invented for it, by its people — and one that belongs to no
    # campaign is invisible to the roster, to "fill them in", and to the library's own
    # grouping by campaign.
    assert walk_ons != []
    assert Enum.all?(walk_ons, &(&1.status == :stub))
    assert Enum.all?(walk_ons, &(&1.tier == :incidental))

    # The world is a real bible; everyone on the roster is linked to it.
    assert %WorldBible{} = Library.payload(Library.get(payload[:bible_id]))

    for sheet <- sheets do
      assert %CharacterSheet{world_bible_id: wid} = sheet
      assert wid == payload[:bible_id]
    end

    # The cast now renders with edit links into the character editor.
    [cid | _] = payload[:character_ids]
    # The built cast shows on its own tab now, each row linking into its sheet.
    {:ok, _cast_view, cast_html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")
    assert cast_html =~ ~s(href="/authoring/character/#{cid}")

    # And the world it built is legible on the World tab — the reported symptom was a
    # name in a dropdown and nothing else, with the setting written but never rendered.
    built = Library.payload(Library.get(payload[:bible_id]))
    {:ok, _world_view, world_html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

    # Guard the assertions below against passing on emptiness: `html =~ ""` is true of
    # every page, and a `for` over no rules checks nothing at all.
    assert built.setting not in [nil, ""]
    assert built.tone not in [nil, ""]
    assert WorldBible.entries(built.rules) != []

    assert world_html =~ "This campaign&#39;s copy"
    assert world_html =~ Phoenix.HTML.html_escape(built.setting) |> Phoenix.HTML.safe_to_string()
    assert world_html =~ Phoenix.HTML.html_escape(built.tone) |> Phoenix.HTML.safe_to_string()

    for entry <- WorldBible.entries(built.rules) do
      assert world_html =~
               entry.statement |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    end
  end

  test "a built campaign is not still being offered the builder", %{conn: conn, user: user} do
    camp = campaign(user)
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}")
    open_quick_build(view)

    html =
      view
      |> form("#quick-build", %{"world_seed" => "a city", "char_seed" => ["a harbor-master"]})
      |> render_submit()

    assert html =~ "quick-build"

    drain()
    html = render(view)

    # Quick Build is a one-shot. The card is first-run only and disappears on its own,
    # but the form it opens was shown on the open flag alone and nothing cleared it —
    # so it stayed on screen offering to build the world and cast that had just been
    # built, underneath the settings for them.
    refute html =~ "quick-build"
    refute html =~ "Try Quick Build"

    # And it stays gone on a fresh mount, rather than only in the socket that built it.
    {:ok, _view, reloaded} = live(conn, ~p"/campaigns/#{camp.id}")
    refute reloaded =~ "quick-build"
  end

  test "a failed build leaves the form up, because the next move is to try again",
       %{conn: conn, user: user} do
    # Every call errors, so nothing is written at all — the total failure, not the
    # partial one, which takes the success path with a list of what it couldn't make.
    Application.put_env(:polyphony, :llm,
      provider: Polyphony.LLM.Stub,
      stub_response: {:error, :nope}
    )

    on_exit(fn -> Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock) end)

    camp = campaign(user, %{name: "Doomed"})
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}")
    open_quick_build(view)

    view
    |> form("#quick-build", %{"world_seed" => "", "char_seed" => [""]})
    |> render_submit()

    drain_to_failure()
    html = render(view)

    # Nothing was built, so the campaign is still first-run — and taking the form away
    # here would leave someone staring at the card that opens it.
    assert html =~ "quick-build"

    # And it says so rather than going quiet. The author was probably not looking when
    # it failed, so a build that just stops is indistinguishable from one that never ran.
    assert html =~ "Failed"
    assert html =~ "The world couldn&#39;t be written"
  end

  test "character rows can be added and removed", %{conn: conn, user: user} do
    camp = campaign(user)
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}")
    html = open_quick_build(view)

    # Starts with a single row.
    assert length(Regex.scan(~r/name="char_seed\[\]"/, html)) == 1

    view |> element("button[phx-click=add_seed]") |> render_click()
    view |> element("button[phx-click=add_seed]") |> render_click()
    assert length(Regex.scan(~r/name="char_seed\[\]"/, render(view))) == 3

    view
    |> element("button[phx-click=remove_seed][phx-value-index='1']")
    |> render_click()

    assert length(Regex.scan(~r/name="char_seed\[\]"/, render(view))) == 2
  end

  describe "the attached world" do
    test "is shown, not just named", %{conn: conn, user: user} do
      bible =
        Library.put(%{
          owner: Owner.of(user),
          kind: "world_bible",
          payload: %WorldBible{
            name: "Saltmarch",
            setting: "A port town on a tidal flat, half of it underwater twice a day.",
            tone: "Damp, close, quietly criminal.",
            rules:
              WorldBible.entries([
                "The tide bell is never rung twice by accident.",
                %{statement: "Debts outlive the people who owe them.", concealed: true}
              ])
          }
        })

      camp = campaign(user, %{bible_id: bible.id})
      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

      # The complaint this fixes: the tab showed the picker and nothing about what it
      # had picked, so a quick-built campaign read as a name in a dropdown.
      assert html =~ "Saltmarch"
      assert html =~ "underwater twice a day"
      assert html =~ "quietly criminal"
      assert html =~ "The tide bell is never rung twice by accident"

      # Attaching copies, and the label is the only place that says so.
      assert html =~ "This campaign&#39;s copy"
    end

    test "a concealed rule is the author's to see, and marked the way the editor marks it",
         %{conn: conn, user: user} do
      bible =
        Library.put(%{
          owner: Owner.of(user),
          kind: "world_bible",
          payload: %WorldBible{
            name: "Saltmarch",
            rules: WorldBible.entries([%{statement: "The bell is a signal.", concealed: true}])
          }
        })

      camp = campaign(user, %{bible_id: bible.id})
      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

      # The author is omniscient over their own world — what a *character* may know is
      # `Polyphony.Visibility`'s business and not this screen's. `secret` is the kit
      # mark the bible editor uses, so the two don't describe one entry differently.
      assert html =~ "The bell is a signal."
      assert html =~ ~s(class="secret)
    end

    test "a world that is only a name renders no empty headings", %{conn: conn, user: user} do
      bible =
        Library.put(%{
          owner: Owner.of(user),
          kind: "world_bible",
          payload: %WorldBible{name: "Bare", setting: "", tone: nil, rules: []}
        })

      camp = campaign(user, %{bible_id: bible.id})
      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

      assert html =~ "Bare"
      # A heading over an empty space reads as a bug rather than as an absence.
      refute html =~ ">Setting<"
      refute html =~ ">Tone<"
      refute html =~ ">Rules<"
    end

    test "with nothing attached and nothing to attach, the tab offers writing one",
         %{conn: conn, user: user} do
      camp = campaign(user)
      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

      assert html =~ "The world"
      refute html =~ "This campaign&#39;s copy"

      # A `<select>` whose only option is "— none —" is not a picker, and the advice it
      # used to carry was to go to the library — which has no world-create button
      # either. Nothing in the app wrote a world at all.
      refute html =~ ~s(id="bible-select")
      assert html =~ "No world yet."
      assert html =~ ~s(phx-click="new_world")
    end

    test "with a world to pick from, the picker is there and so is the other way",
         %{conn: conn, user: user} do
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %WorldBible{name: "Saltmarch"}
      })

      camp = campaign(user)
      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

      # Taking one you already have is the cheaper move, so it stays first.
      assert html =~ ~s(id="bible-select")
      assert html =~ "Write a new one instead"
    end

    test "the picker survives an attachment, so a world can still be swapped",
         %{conn: conn, user: user} do
      bible =
        Library.put(%{
          owner: Owner.of(user),
          kind: "world_bible",
          payload: %WorldBible{name: "Saltmarch", setting: "A port town."}
        })

      camp = campaign(user, %{bible_id: bible.id})
      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

      assert html =~ ~s(id="bible-select")
    end
  end

  test "the world card links into the bible editor once a world is attached",
       %{conn: conn, user: user} do
    bible =
      Library.put(%{owner: Owner.of(user), kind: "world_bible", payload: %WorldBible{name: "Bay"}})

    camp = campaign(user, %{bible_id: bible.id})

    {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")
    assert html =~ ~s(href="/authoring/bible/#{bible.id}")
  end

  test "a scene opens where the author said, not nowhere", %{conn: conn, user: user} do
    char =
      Library.put(%{
        owner: Owner.of(user),
        kind: "character",
        payload: %CharacterSheet{name: "Wren", status: :full}
      })

    camp = campaign(user, %{character_ids: [char.id]})
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")

    view
    |> form("#scene-where", %{location: "The quay, after the second bell"})
    |> render_change()

    # Two "Set a scene" buttons on this tab — the header's and the empty state's — and
    # they do the same thing, so the event is what matters rather than which one.
    render_click(view, "start_scene", %{})

    [scene | _] = Library.payload(Library.get(camp.id))[:scenes]

    # `OpenScene` has carried `location_id` since §2.3 and nothing ever passed one, so
    # every scene opened nowhere.
    opened =
      for %Polyphony.Events.SceneOpened{} = e <-
            Polyphony.App
            |> Commanded.EventStore.stream_forward(scene)
            |> Enum.map(& &1.data),
          do: e

    assert [%{location_id: "The quay, after the second bell"}] = opened
  end

  test "expand deepens the campaign premise", %{conn: conn, user: user} do
    camp = campaign(user, %{premise: "A heist."})
    # Premise is its own tab now, and sits after Cast — the pitch is written from
    # the cast, so ordering it earlier invites writing it twice.
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=premise")

    view |> element("button[phx-click=expand_premise]") |> render_click()
    drain()
    render(view)

    # The premise was regenerated (Mock lorem replaces the seed).
    assert Library.payload(Library.get(camp.id))[:premise] != "A heist."
  end
end

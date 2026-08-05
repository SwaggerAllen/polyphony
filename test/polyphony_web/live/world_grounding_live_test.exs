defmodule PolyphonyWeb.WorldGroundingLiveTest do
  @moduledoc """
  Every ✦ on the campaign screen that grounds itself in the world.

  A world bible's `rules` and `starting_canon` are lists of `WorldBible.Entry` structs,
  not strings — `Entry` carries `concealed`, which is how a rule can be a secret law of
  the world. `world_display/1` joined `starting_canon` through `WorldBible.public/1` and
  joined `rules` **raw**, so any bible with a rule written on it raised
  `Protocol.UndefinedError` the moment somebody pressed ✦ Expand or ✦ Suggest.

  Fixing it with `public/1` rather than `statements/1` is the same call the character
  sheet already makes: a premise and a scene opening are read by characters, so a
  concealed rule must not travel into either. The crash and the visibility question have
  the same answer, which is why this pins both.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.WorldBible
  alias Polyphony.Authoring.WorldBible.Entry

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp campaign_with_world(user, world_attrs) do
    bible =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: struct(%WorldBible{name: "Isle"}, world_attrs)
      })

    Library.put(%{
      owner: Owner.of(user),
      kind: "campaign",
      payload: %{
        kind: :campaign,
        name: "",
        character_ids: [],
        bible_id: bible.id,
        scenes: []
      }
    })
  end

  @structured [
    rules: [
      %Entry{statement: "Gravity weakens at the jagged edges.", concealed: false},
      %Entry{statement: "The core is a sleeping thing.", concealed: true}
    ],
    starting_canon: [%Entry{statement: "The last ferry left a year ago.", concealed: false}]
  ]

  test "the premise ✦ survives a world with rules on it", %{conn: conn, user: user} do
    camp = campaign_with_world(user, @structured)

    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=premise")
    html = view |> element("button[phx-click=expand_premise]") |> render_click()

    # It raised `String.Chars` here — joining a list of structs — and `SafeEvent` turned
    # a crash into a flash, so the button read as broken rather than as a bug.
    refute html =~ "Something went wrong"
    refute html =~ "Error:"

    # And it actually ran, rather than failing quietly further along.
    generate(view)
    assert Library.payload(Library.get(camp.id))[:premise] not in [nil, ""]
  end

  test "the scene ✦ survives it too", %{conn: conn, user: user} do
    camp = campaign_with_world(user, @structured)

    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")
    html = view |> element("button[phx-click=suggest_scene]") |> render_click()

    refute html =~ "Something went wrong"
    refute html =~ "Error:"
  end

  test "a concealed rule does not travel into a character-facing premise",
       %{conn: conn, user: user} do
    test = self()

    Application.put_env(:polyphony, :llm,
      provider: Polyphony.LLM.Stub,
      stub_response: fn messages ->
        send(test, {:prompt, Enum.map_join(messages, "\n", & &1.content)})
        {:ok, Jason.encode!(%{"name" => "X", "premise" => "Y."})}
      end
    )

    camp = campaign_with_world(user, @structured)

    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=premise")
    view |> element("button[phx-click=expand_premise]") |> render_click()
    generate(view)

    assert_received {:prompt, prompt}

    # `public/1`, not `statements/1`. A premise is read by characters, so a secret law
    # of the world is exactly the thing that must not be in the prompt that writes it.
    assert prompt =~ "Gravity weakens at the jagged edges."
    refute prompt =~ "The core is a sleeping thing."
  end
end

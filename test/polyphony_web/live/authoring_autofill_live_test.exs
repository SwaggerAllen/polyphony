defmodule PolyphonyWeb.AuthoringAutofillLiveTest do
  @moduledoc """
  The editor auto-generation UI (§15): a free-text brief that fills every field, and
  a per-field ✨ button. Driven by the offline Mock so async generation is
  deterministic; `render_async/1` awaits the `start_async` task.
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

  defp character(user, sheet) do
    Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})
  end

  defp world(user, bible) do
    Library.put(%{owner: Owner.of(user), kind: "world_bible", payload: bible})
  end

  describe "character sheet editor" do
    test "the brief fills every field", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "", status: :full})

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view
      |> form("form[phx-submit=generate_all]", %{brief: "a jaded harbor detective"})
      |> render_submit()

      html = render_async(view)
      assert html =~ "review and Save"
      # The name field, empty at mount, now carries generated content.
      assert Regex.match?(~r/name="name" value="[^"]+"/, html)
    end

    test "a per-field button generates just that field", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "Mara", premise: "", status: :full})

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view
      |> element("button[phx-value-field=premise]")
      |> render_click()

      html = render_async(view)
      # The premise textarea (empty at mount) now has content; other fields untouched.
      refute html =~ ~r/<textarea name="premise">\s*<\/textarea>/
      assert html =~ ~s(value="Mara")
    end

    test "generation only populates the form — saving persists it", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "", premise: "", status: :full})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view
      |> form("form[phx-submit=generate_all]", %{brief: "a smuggler"})
      |> render_submit()

      render_async(view)
      # Not persisted yet — generation only populates the form.
      assert Library.payload(Library.get(entry.id)).premise in [nil, ""]

      view |> form("form[phx-submit=save]") |> render_submit()
      refute Library.payload(Library.get(entry.id)).premise in [nil, ""]
    end
  end

  describe "world bible editor" do
    test "the brief fills every field including the list-typed ones", %{conn: conn, user: user} do
      entry = world(user, %WorldBible{name: "", rules: [], starting_canon: []})

      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> form("form[phx-submit=generate_all]", %{brief: "a drowned neon city"})
      |> render_submit()

      html = render_async(view)
      assert html =~ "review and Save"
      # rules textarea now has content
      refute html =~ ~r/<textarea name="rules">\s*<\/textarea>/
    end
  end
end

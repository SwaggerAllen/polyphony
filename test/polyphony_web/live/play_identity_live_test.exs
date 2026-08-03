defmodule PolyphonyWeb.PlayIdentityLiveTest do
  @moduledoc """
  The play view is id-native, and a rename can't corrupt a scene (§5.2).

  This is the test the identity migration exists for. `character_id` used to be a
  character's **display name**, keyed on with string equality through every play-side
  subsystem — membership, packet ids, arc, and the one that matters most here, a
  whisper's `addressed_to`. Renaming a character in the sheet editor silently broke
  all of it: the rename stopped them witnessing their own history, and whispers
  addressed to their old name stopped reaching them.

  So there are two things to pin, and they're different:

  1. **Ids route, names display.** A whisper typed as "(whisper to Bram: …)" must
     enter the log addressed to Bram's *library id*, and come back out rendered as
     his name. Nothing that routes may hold a name.

  2. **A rename changes only what's displayed.** Rename a character mid-scene and the
     whisper still reaches them, the bystander still can't see it, and the transcript
     starts showing the new name — because the log never held the old one.

  Point 2 is a visibility test, so note which way it fails. If an id-vs-name mismatch
  slipped in, `Visibility.visible_to?/3` would match *nobody* and the whisper would
  vanish from its addressee — a caught functional bug under default-deny (rule 3),
  never a leak. That's the failure mode these assertions are shaped to catch: they
  check the addressee still *sees* it as hard as they check the bystander doesn't.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Library, Owner, Packets}
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Commands.{OpenScene, EnterCharacter}
  alias Polyphony.Events.SpeechUttered
  alias Polyphony.Director.BeatOps

  setup :register_and_log_in_user

  defp character(user, name) do
    Library.put(%{
      owner: Owner.of(user),
      kind: "character",
      payload: %CharacterSheet{name: name, status: :full}
    })
  end

  # A scene whose cast entered by **library id**, the way campaign_live mints them.
  defp scene_with_cast(user, names) do
    scene = "ident-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    cast =
      Map.new(names, fn name ->
        entry = character(user, name)

        :ok =
          App.dispatch(%EnterCharacter{
            scene_id: scene,
            character_id: to_string(entry.id),
            beat: 1
          })

        {name, to_string(entry.id)}
      end)

    {scene, cast}
  end

  defp rename(character_id, new_name) do
    entry = Library.get(character_id)
    Library.update_payload(entry.id, %{Library.payload(entry) | name: new_name})
  end

  defp whispers(scene) do
    scene
    |> BeatOps.stored_events()
    |> Packets.canonical()
    |> Enum.filter(&match?(%SpeechUttered{audibility: :private}, &1))
  end

  describe "ids route" do
    test "a whisper typed by name is stored addressed to the target's id", %{
      conn: conn,
      user: user
    } do
      {scene, cast} = scene_with_cast(user, ["Wren", "Bram", "Cara"])

      {:ok, wren, _html} = live(conn, ~p"/play/#{scene}?as=#{cast["Wren"]}")

      wren
      |> form("form[phx-submit=say]", %{text: "(whisper to Bram: meet me at dawn)"})
      |> render_submit()

      assert [%SpeechUttered{speaker_id: speaker, addressed_to: to}] = whispers(scene)

      # The routing keys are ids — not the names the player actually typed.
      assert speaker == cast["Wren"]
      assert to == [cast["Bram"]]
      refute "Bram" in to
    end

    test "the roster is keyed by id and labelled by name", %{conn: conn, user: user} do
      {scene, cast} = scene_with_cast(user, ["Wren", "Bram"])

      {:ok, _view, html} = live(conn, ~p"/play/#{scene}")

      assert html =~ ~s(<option value="#{cast["Wren"]}")
      assert html =~ ">Wren</option>"
      refute html =~ ~s(<option value="Wren")
    end

    test "the transcript renders ids back as names", %{conn: conn, user: user} do
      {scene, cast} = scene_with_cast(user, ["Wren", "Bram"])

      {:ok, wren, _html} = live(conn, ~p"/play/#{scene}?as=#{cast["Wren"]}")
      wren |> form("form[phx-submit=say]", %{text: "Nothing came in tonight."}) |> render_submit()

      {:ok, _author, html} = live(conn, ~p"/play/#{scene}")

      # The design attributes a turn once, at the top of its block, rather than
      # prefixing every line — so the name appears as the block's heading.
      assert html =~ ~r{ttl[^>]*>\s*Wren\s*<}
      # The reader never sees the routing key.
      refute html =~ ~r{ttl[^>]*>\s*#{cast["Wren"]}\s*<}
    end

    test "an unknown whisper target passes through rather than raising", %{
      conn: conn,
      user: user
    } do
      {scene, cast} = scene_with_cast(user, ["Wren", "Bram"])

      {:ok, wren, _html} = live(conn, ~p"/play/#{scene}?as=#{cast["Wren"]}")

      wren
      |> form("form[phx-submit=say]", %{text: "(whisper to Nobody: hello)"})
      |> render_submit()

      # Identity fallback: the name stays as itself, so it addresses nobody in the
      # scene. The turn still commits — a typo shouldn't lose the player's writing.
      assert [%SpeechUttered{addressed_to: ["Nobody"]}] = whispers(scene)

      {:ok, _bram, bram_html} = live(conn, ~p"/play/#{scene}?as=#{cast["Bram"]}")
      refute bram_html =~ "hello"
    end
  end

  describe "a rename changes only what's displayed" do
    test "the whisper still reaches its addressee, and still not a bystander", %{
      conn: conn,
      user: user
    } do
      {scene, cast} = scene_with_cast(user, ["Wren", "Bram", "Cara"])

      {:ok, wren, _html} = live(conn, ~p"/play/#{scene}?as=#{cast["Wren"]}")

      wren
      |> form("form[phx-submit=say]", %{text: "(whisper to Bram: meet me at dawn)"})
      |> render_submit()

      # The rename that used to corrupt the scene.
      rename(cast["Bram"], "Bramwell Ashe")

      # He is the same person to the log, so he still hears it. This is the
      # assertion that fails first if a name leaked into a routing key: under
      # default-deny the whisper would reach nobody, including him.
      {:ok, _bram, bram_html} = live(conn, ~p"/play/#{scene}?as=#{cast["Bram"]}")
      assert bram_html =~ "meet me at dawn"

      # And the bystander still can't see it — the guarantee didn't loosen to buy this.
      {:ok, _cara, cara_html} = live(conn, ~p"/play/#{scene}?as=#{cast["Cara"]}")
      refute cara_html =~ "meet me at dawn"
    end

    test "the scene starts calling them by their new name", %{conn: conn, user: user} do
      {scene, cast} = scene_with_cast(user, ["Wren", "Bram"])

      {:ok, wren, _html} = live(conn, ~p"/play/#{scene}?as=#{cast["Wren"]}")
      wren |> form("form[phx-submit=say]", %{text: "Nothing came in tonight."}) |> render_submit()

      rename(cast["Wren"], "Wren Ashgrove")

      {:ok, _author, html} = live(conn, ~p"/play/#{scene}")

      # Rendered fresh from the sheet on every load, including for turns committed
      # before the rename — the log stored an id, so there's no stale copy of the name.
      assert html =~ ~r{ttl[^>]*>\s*Wren Ashgrove\s*<}
      assert html =~ ">Wren Ashgrove</option>"
    end

    test "a renamed character can still take a turn", %{conn: conn, user: user} do
      {scene, cast} = scene_with_cast(user, ["Wren", "Bram"])

      rename(cast["Wren"], "Wren Ashgrove")

      {:ok, wren, _html} = live(conn, ~p"/play/#{scene}?as=#{cast["Wren"]}")

      # Membership and the CommitPacket guard key on the id, so the rename can't make
      # her a stranger to her own scene (this used to fail as `:not_a_member`).
      html =
        wren
        |> form("form[phx-submit=say]", %{text: "Still here."})
        |> render_submit()

      assert html =~ "Still here."
      assert html =~ "What does Wren Ashgrove do?"
    end
  end

  describe "editing a turn round-trips through names" do
    test "an author edits names and the log keeps ids", %{conn: conn, user: user} do
      {scene, cast} = scene_with_cast(user, ["Wren", "Bram", "Cara"])

      {:ok, wren, _html} = live(conn, ~p"/play/#{scene}?as=#{cast["Wren"]}")

      wren
      |> form("form[phx-submit=say]", %{text: "(whisper to Bram: meet me at dawn)"})
      |> render_submit()

      {:ok, author, _html} = live(conn, ~p"/play/#{scene}")

      # The editor shows the addressee as a name — an author can't be asked to type ids.
      packet_id = hd(whispers(scene)).packet_id

      author
      |> element("button[phx-click=edit_turn][phx-value-packet=#{packet_id}]")
      |> render_click()

      assert render(author) =~ "(whisper to Bram: meet me at dawn)"

      # Saving the edit resolves the name back to the id.
      # Only the text changes — beat/character/packet ride the form's hidden fields,
      # and the character one is already an id.
      author
      |> form("form#edit-#{packet_id}", %{text: "(whisper to Bram: meet me at midnight)"})
      |> render_submit()

      assert [%SpeechUttered{content: content, addressed_to: to}] =
               Enum.filter(whispers(scene), &(&1.content =~ "midnight"))

      assert content =~ "midnight"
      assert to == [cast["Bram"]]

      # And it routes: the addressee sees the correction, the bystander sees neither take.
      {:ok, _bram, bram_html} = live(conn, ~p"/play/#{scene}?as=#{cast["Bram"]}")
      assert bram_html =~ "meet me at midnight"

      {:ok, _cara, cara_html} = live(conn, ~p"/play/#{scene}?as=#{cast["Cara"]}")
      refute cara_html =~ "midnight"
      refute cara_html =~ "dawn"
    end
  end
end

defmodule PolyphonyWeb.KitTest do
  @moduledoc """
  The kit components render the design's markup.

  These are deliberately assertions about *classes and structure*, not about
  pixels: `assets/css/kit.css` owns the look and `KitPortTest` guards that it
  matches the design. What can still drift is the markup — a component quietly
  growing a screen-local class, or a state losing the class that gives it
  meaning — so that's what's pinned here.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PolyphonyWeb.Kit
  alias PolyphonyWeb.Voice

  describe "frame" do
    test "carries the register and theme the kit's tokens key on" do
      html = render_component(&Kit.frame/1, register: :page, theme: :light, inner_block: block())

      assert html =~ ~s(class="fr page light")
    end

    test "defaults to the working register, dark" do
      html = render_component(&Kit.frame/1, inner_block: block())

      assert html =~ ~s(class="fr stage dark")
    end
  end

  describe "the perspective control" do
    test "is one class and one markup shape, whatever the viewpoint" do
      omniscient = render_component(&Kit.viewas/1, label: "Omniscient")
      character = render_component(&Kit.viewas/1, label: "Wren", colour: "var(--v1)")

      for html <- [omniscient, character] do
        assert html =~ "viewas"
        assert html =~ "<i></i>"
      end

      # The hue is the only difference — that's what makes it the same control.
      assert omniscient =~ "--vc:var(--bc)"
      assert character =~ "--vc:var(--v1)"
    end

    test "becomes a real control when it switches, and drops the caret when it can't" do
      live =
        render_component(&Kit.viewas/1,
          label: "Wren",
          tag: "button",
          rest: %{"phx-click" => "pick"}
        )

      fixed = render_component(&Kit.viewas/1, label: "Wren", caret: false)

      assert live =~ "<button"
      assert live =~ ~s(phx-click="pick")
      assert live =~ "▾"
      refute fixed =~ "▾"
    end
  end

  describe "buttons" do
    test "map each kind to the kit's treatment" do
      for {kind, class} <- [
            primary: "btn-pri",
            ghost: "btn-gh",
            pen: "btn-pen",
            red: "btn-red",
            off: "btn-off"
          ] do
        html = render_component(&Kit.btn/1, kind: kind, inner_block: block("Go"))
        assert html =~ "btn " <> class or html =~ class
        assert html =~ "btn"
      end
    end

    test "the editorial layer is never the primary treatment" do
      # The kit is explicit: pencil is reroll/edit/delete/branch and every error,
      # and it is never a primary action. Guard the pairing can't be written.
      pen = render_component(&Kit.btn/1, kind: :pen, inner_block: block("Reroll"))

      assert pen =~ "btn-pen"
      refute pen =~ "btn-pri"
    end
  end

  describe "status strip" do
    test "one slot per cast member, each carrying its own state" do
      html =
        render_component(&Kit.strip/1,
          sentence: "Your turn.",
          tone: "var(--lamp)",
          slot_item: [
            slot(%{label: "WREN", state: :took, colour: "var(--v1)"}, "WREN"),
            slot(%{label: "YOU", state: :now, you: true}, "YOU"),
            slot(%{label: "CORR", state: :wait}, "CORR")
          ]
        )

      assert html =~ "slot-took"
      assert html =~ "--sc:var(--v1)"
      assert html =~ "slot-now"
      assert html =~ "slot-you"
      assert html =~ "slot-wait"
      assert html =~ "Your turn."
      assert html =~ "color:var(--lamp)"
    end

    test "an unknown state waits rather than disappearing" do
      html =
        render_component(&Kit.strip/1,
          slot_item: [slot(%{label: "W", state: nil}, "W")]
        )

      assert html =~ "slot-wait"
    end

    test "carries no beat number — the transcript rule owns that" do
      html =
        render_component(&Kit.strip/1,
          sentence: "Wren is writing.",
          slot_item: [slot(%{label: "W", state: :now}, "W")]
        )

      refute html =~ "Beat"
    end
  end

  describe "transcript moves" do
    test "interior monologue is a voice-coloured rule, never italics" do
      html =
        render_component(&Kit.thought/1,
          colour: "var(--v1)",
          note: "Thought · only Wren",
          inner_block: block("If he counts the crates, he'll know.")
        )

      assert html =~ "m-thought"
      assert html =~ "--vc:var(--v1)"
      assert html =~ "Thought · only Wren"
      refute html =~ "italic"
    end

    test "Director narration attributes itself only in the working register" do
      stage =
        render_component(&Kit.world_move/1,
          register: :stage,
          inner_block: block("The tide bell rings.")
        )

      page =
        render_component(&Kit.world_move/1,
          register: :page,
          inner_block: block("The tide bell rings.")
        )

      assert stage =~ "m-world"
      assert stage =~ "The Director"
      assert page =~ "m-world"
      refute page =~ "The Director"
    end

    test "a failure renders where it happened and says what happens next" do
      html =
        render_component(&Kit.fail_move/1,
          title: "Mother Corrigan didn't generate",
          detail: "Moved to the end of the beat."
        )

      assert html =~ "m-fail"
      assert html =~ "Mother Corrigan didn&#39;t generate"
      assert html =~ "Moved to the end of the beat."
    end

    test "a beat rule is plain — it records an opening and never changes" do
      html = render_component(&Kit.beat_rule/1, beat: 4)

      assert html =~ "beat-rule"
      assert html =~ "Beat 4"
      refute html =~ "btn"
      refute html =~ "href"
    end
  end

  describe "marked list items" do
    test "each state takes the left rule the kit assigns it" do
      for mark <- [:secret, :core, :prop, :canon, :drop, :bound, :compel, :urgent, :arch, :was] do
        html = render_component(&Kit.marked/1, mark: mark, inner_block: block("x"))
        assert html =~ to_string(mark)
      end
    end

    test "an unmarked item takes no rule at all" do
      html = render_component(&Kit.marked/1, inner_block: block("x"))

      refute html =~ "plain"
    end

    test "secrecy owns the border so always-in-mind can compose with it" do
      html =
        render_component(&Kit.marked/1,
          mark: :secret,
          inner_block: block(render_component(&Kit.chip_core/1, []))
        )

      assert html =~ "secret"
      assert html =~ "chip-core"
    end
  end

  describe "controls" do
    test "the switch is one geometry coloured by meaning" do
      core = render_component(&Kit.sw/1, on: true, colour: "var(--lamp)")
      secret = render_component(&Kit.sw/1, on: true, colour: "var(--secret)")
      off = render_component(&Kit.sw/1)

      assert core =~ "sw sw-on"
      assert core =~ "--sc:var(--lamp)"
      assert secret =~ "--sc:var(--secret)"
      refute off =~ "sw-on"
    end

    test "an inherited tick is outlined, so it reads as not individually removable" do
      via = render_component(&Kit.chk/1, state: :via)

      assert via =~ "chk-via"
      assert via =~ "✓"
    end

    test "a pill is status, and takes its colour on border and text together" do
      html = render_component(&Kit.pill/1, colour: "var(--ok)", inner_block: block("Done"))

      assert html =~ "pill"
      assert html =~ "border-color:var(--ok)"
      assert html =~ "color:var(--ok)"
      refute html =~ "<button"
    end

    test "the bar clamps rather than overflowing its track" do
      assert render_component(&Kit.bar/1, fraction: 0.5) =~ "width:50.0%"
      assert render_component(&Kit.bar/1, fraction: 2.0) =~ "width:100.0%"
      assert render_component(&Kit.bar/1, fraction: -1.0) =~ "width:0.0%"
    end

    test "the info affordance names what it explains" do
      html = render_component(&Kit.info/1, label: "facts")

      assert html =~ ~s(class="info")
      assert html =~ ~s(aria-label="About facts")
    end
  end

  describe "navigation" do
    test "an unbuilt tab carries the amber dot" do
      html =
        render_component(&Kit.tabs/1,
          tab: [
            slot(%{on: true, patch: "/x"}, "Settings"),
            slot(%{todo: true, patch: "/y"}, "World")
          ]
        )

      assert html =~ "tab-on"
      assert html =~ "tab-todo"
      assert html =~ ~s(aria-selected="true")
    end

    test "the jump bar and the scrubber are the same primitive" do
      jump = render_component(&Kit.jump/1, stop: [slot(%{on: true}, "Premise")])
      scrub = render_component(&Kit.jump/1, scrub: true, stop: [slot(%{on: true}, "Now")])

      assert jump =~ ~s(class="jump")
      assert scrub =~ ~s(class="scrub")
      assert jump =~ ~s(class="on")
      assert scrub =~ ~s(class="on")
    end
  end

  describe "absence" do
    test "an empty state is a headline, a line, and one action" do
      html =
        render_component(&Kit.empty/1,
          headline: "Nobody is on the quay yet.",
          inner_block: block("Pick who's in the room and the Director will open the scene."),
          action: [slot(%{}, "Open the scene")]
        )

      assert html =~ "ttl"
      assert html =~ "Nobody is on the quay yet."
      assert html =~ "Open the scene"
      # The copy rule, guarded: never the generic phrasing.
      refute html =~ "No items found"
    end
  end

  describe "voice colours" do
    test "are assigned by cast order and stay put" do
      voices = Voice.assign(["wren", "ilias", "corrigan"])

      assert voices["wren"] == "var(--v1)"
      assert voices["ilias"] == "var(--v2)"
      assert voices["corrigan"] == "var(--v3)"
    end

    test "re-entry doesn't reshuffle the cast" do
      assert Voice.assign(["wren", "ilias", "wren"]) == Voice.assign(["wren", "ilias"])
    end

    test "wrap past eight rather than leaving a character unstyled" do
      ids = Enum.map(1..10, &"c#{&1}")
      voices = Voice.assign(ids)

      assert voices["c9"] == "var(--v1)"
      assert voices["c10"] == "var(--v2)"
      assert map_size(voices) == 10
    end

    test "anything without a voice takes the register's plain foreground" do
      voices = Voice.assign(["wren"])

      assert Voice.of(voices, nil) == "var(--bc)"
      assert Voice.of(voices, "the-director") == "var(--bc)"
      refute Voice.of(voices, "the-director") in Map.values(voices)
    end

    test "resolve against the register, never a fixed hex" do
      for colour <- Map.values(Voice.assign(Enum.map(1..8, &"c#{&1}"))) do
        assert colour =~ ~r/^var\(--v[1-8]\)$/
      end
    end
  end

  # The default slot takes a map; a named slot's entry takes the function itself.
  defp block(text \\ "content"), do: %{inner_block: fn _, _ -> text end}
  defp slot(attrs, text), do: Map.put(attrs, :inner_block, fn _, _ -> text end)
end

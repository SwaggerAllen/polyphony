defmodule Storybook.Screens.SheetEditor do
  use PhoenixStorybook.Story, :component

  alias Polyphony.Authoring.Audience
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Authoring.CharacterSheet.{Boundary, Fact, Relationship}

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Screens.SheetEditor.screen/1

  defp fact(statement, opts \\ []),
    do: %Fact{
      statement: statement,
      concealed: opts[:concealed] || false,
      core: opts[:core] || false,
      audience: opts[:audience]
    }

  defp boundary(topic, opts),
    do: %Boundary{
      topic: topic,
      stance: opts[:stance] || :conditional,
      direction: opts[:direction] || :refusal,
      condition: opts[:condition],
      on_pressure: opts[:on_pressure],
      after_release: opts[:after_release],
      category: opts[:category]
    }

  defp sheet,
    do: %CharacterSheet{
      name: "Wren Ashgrove",
      pronouns: "she / her",
      premise: "Keeps the tide ledger, and keeps it honest, mostly.",
      status: :full
    }

  # Storybook does not apply `attr` defaults — a variation's attributes are the whole of
  # the assigns — so every key the screen reads is named once, here.
  defp defaults do
    %{
      current_user: %{id: "u1", username: "wren", role: "user"},
      entry: %{id: "e1"},
      campaign: %{id: "c1", name: "The Salt Line"},
      sheet: sheet(),
      name: "Wren Ashgrove",
      role: "Customs clerk",
      tier: :main,
      pronouns: "she / her",
      cover: nil,
      blocks: %{
        "premise" => ["Keeps the tide ledger, and keeps it honest, mostly."],
        "appearance" => ["Oilskins that have been wet since Tuesday."],
        "voice" => ["Flat, and slower than you expect."],
        "temperament" => ["Unhurried. She has seen the water do this before."],
        "backstory" => ["Came up on the wall, like her mother."]
      },
      facts: [
        fact("She walks the wall on nights nobody else will."),
        fact("She signed for a crate she never saw.", concealed: true, core: true)
      ],
      boundaries: [],
      relationships: [],
      groups: [%{id: "g1", name: "The Tidewatch", hue: "hsl(210 40% 55%)"}],
      all_groups: [
        %{id: "g1", name: "The Tidewatch", hue: "hsl(210 40% 55%)"},
        %{id: "g2", name: "The harbour office", hue: "hsl(40 40% 55%)"}
      ],
      knows: [],
      char_names: %{"p2" => "Ilias"},
      char_hues: %{"p2" => "hsl(40 40% 55%)"},
      char_links: %{},
      world_context: nil,
      scene_count: 4,
      generating: MapSet.new(),
      panel: nil,
      drawer: nil,
      brief_open: false,
      dirty: false,
      saved: false,
      audience_at: nil,
      arc_counts: %{},
      arc_prompt: nil,
      arc_scenes: [],
      picker_groups: [{"g1", "The Tidewatch", "6 members"}],
      picker_people: [{"p2", "Ilias", :recurring, "hsl(40 40% 55%)"}],
      picker_labels: %{"g1" => "The Tidewatch", "p2" => "Ilias"},
      resolved_audience: []
    }
  end

  defp v(id, description, overrides),
    do: %Variation{
      id: id,
      description: description,
      attributes: defaults() |> Map.merge(overrides) |> Map.put(:id, to_string(id))
    }

  def variations do
    [
      v(
        :written,
        "A sheet with something on it. Pronouns are a **field** rather than an inference — every character prompt renders this sheet, and a model guessing from a name lands a wrong guess inside the fiction, where it reads as the story being wrong about her.",
        %{}
      ),
      v(
        :blank,
        "A character who exists and nothing more. The first-run card leads rather than showing five empty fields, because an empty form is a worse question than a prompt.",
        %{
          name: "",
          role: nil,
          sheet: %CharacterSheet{status: :full},
          blocks: %{
            "premise" => [""],
            "appearance" => [""],
            "voice" => [""],
            "temperament" => [""],
            "backstory" => [""]
          },
          facts: [],
          groups: [],
          scene_count: 0
        }
      ),
      v(
        :a_secret,
        "A fact somebody else knows. The audience picker is **always on the row** — *Nobody* is the honest resting state — and the purple treatment is derived from the audience rather than stored beside it, so a fact marked secret with an empty audience cannot be represented at all.",
        %{audience_at: 1, panel: :facts}
      ),
      v(
        :arc_touched,
        "Editing a field play has revised asks **which you mean**: *she's changed again* proposes on top of what play did and leaves her history standing, while *I wrote her wrong* rewrites the origin and play's changes still apply on top. Guessing would produce a sheet whose history is quietly false.",
        %{
          arc_counts: %{"temperament" => 2},
          arc_scenes: [%{id: "c1-s3", label: "Scene 3"}],
          arc_prompt: %{
            field: "temperament",
            label: "Temperament",
            value: "Steady, and starting to sound like it costs her.",
            count: 2,
            because: "",
            scene_id: nil
          }
        }
      ),
      v(
        :audience_open,
        "The picker itself, with somebody already in the audience. Additive only — an inherited tick can't be individually removed, and the picker says so.",
        %{
          audience_at: 1,
          panel: :facts,
          facts: [
            fact("She walks the wall on nights nobody else will."),
            fact("She signed for a crate she never saw.",
              concealed: true,
              audience: %Audience{group_ids: ["g1"], character_ids: ["p2"]}
            )
          ],
          resolved_audience: ["e1", "p2"]
        }
      ),
      v(
        :boundaries,
        "What she won't do, and which way the pressure runs — a **refusal** is a line she holds, a **compulsion** is one she can't help crossing. Same gate, two directions.",
        %{
          panel: :boundaries,
          boundaries: [
            boundary("Informing on the wall crews", stance: :closed, condition: "Ever."),
            boundary("Drinking before a shift",
              stance: :conditional,
              direction: :compulsion,
              condition: "After a bad tide."
            )
          ]
        }
      ),
      v(
        :relationships,
        "Who she's connected to. The target is an **id** with a name rendered beside it — a name is display and two people can share one.",
        %{
          panel: :relations,
          relationships: [
            %Relationship{
              target_id: "p2",
              target: "Ilias",
              descriptor: "Signs what she logs.",
              reciprocal: "Trusts her to be right."
            }
          ]
        }
      ),
      v(
        :generating,
        "A field being written. The skeleton is per-field, so the rest of the sheet stays editable while one field thinks.",
        %{generating: MapSet.new(["appearance"])}
      ),
      v(
        :dirty,
        "Unsaved. The save bar is pinned to the frame rather than the document — on a phone, a save control at the bottom of a long form is one nobody finds.",
        %{dirty: true}
      ),
      v(
        :in_scenes,
        "A sheet for somebody already played. The scene count is the quiet warning: renaming her is safe, but what she has already said isn't editable from here.",
        %{scene_count: 12}
      )
    ]
  end
end

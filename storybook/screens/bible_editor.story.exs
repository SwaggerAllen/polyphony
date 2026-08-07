defmodule Storybook.Screens.BibleEditor do
  use PhoenixStorybook.Story, :component

  alias Polyphony.Authoring.{Audience, WorldBible}
  alias Polyphony.Authoring.WorldBible.Entry

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Screens.BibleEditor.screen/1

  defp entry(statement, opts \\ []),
    do: %Entry{
      statement: statement,
      concealed: opts[:concealed] || false,
      audience: opts[:audience]
    }

  defp bible(opts),
    do: %WorldBible{
      name: "Saltmarch",
      cover: opts[:cover],
      rules: opts[:rules] || [],
      starting_canon: opts[:canon] || []
    }

  defp rules,
    do: [
      entry("The tide comes in twice on a bad night."),
      entry("The bell is rung by somebody, not something.", concealed: true)
    ]

  defp canon, do: [entry("The wall failed twice the year Wren was born.")]

  # Storybook does not apply `attr` defaults — a variation's attributes are the whole of
  # the assigns — so every key the screen reads is named once, here.
  defp defaults do
    %{
      current_user: %{id: "u1", username: "wren", role: "user"},
      entry: %{id: "e1", visibility: "private", share_token: nil},
      campaign: %{id: "c1", name: "The Salt Line"},
      name: "Saltmarch",
      name_error: nil,
      name_clash: nil,
      cover: nil,
      blocks: %{
        "setting" => ["A drowned county that still collects its tolls."],
        "tone" => ["Patient, and a little tired."]
      },
      items: %{"rules" => rules(), "starting_canon" => canon()},
      knows_counts: %{{"rules", 1} => "nobody else"},
      copied_from: nil,
      copy_count: 0,
      preview: false,
      seen: nil,
      draft: nil,
      generating: MapSet.new(),
      panel: nil,
      drawer: nil,
      brief_open: false,
      dirty: false,
      saved: false,
      picker_groups: [{"g1", "The Tidewatch", "6 members"}],
      picker_people: [{"p2", "Ilias", :recurring, "hsl(40 40% 55%)"}],
      picker_labels: %{"g1" => "The Tidewatch", "p2" => "Ilias"},
      resolved_audience: [],
      audience_at: nil
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
        "A world with something in it. Rules and starting canon are both entry lists carrying the same secret control — that sameness is the point, because to a reader they are the same thing: something true that may or may not be known.",
        %{}
      ),
      v(
        :blank,
        "A world that exists and nothing more. The cover placeholder does the explaining, since it is the only part a stranger ever sees.",
        %{
          name: "",
          blocks: %{"setting" => [""], "tone" => [""]},
          items: %{"rules" => [], "starting_canon" => []},
          knows_counts: %{}
        }
      ),
      v(
        :a_secret,
        "A concealed rule, and the line that says how many others know. The count is resolved once in the LiveView — doing it in the markup meant a group-membership read per rule, per render.",
        %{
          knows_counts: %{{"rules", 1} => "2"}
        }
      ),
      v(
        :audience_open,
        "The picker, with a group ticked. The resolved line answers *right now* rather than when it was written, so somebody joining that group changes what this says without anybody touching the secret.",
        %{
          audience_at: {"rules", 1},
          items: %{
            "rules" => [
              entry("The tide comes in twice on a bad night."),
              entry("The bell is rung by somebody, not something.",
                concealed: true,
                audience: %Audience{group_ids: ["g1"], character_ids: []}
              )
            ],
            "starting_canon" => canon()
          },
          resolved_audience: ["p2"],
          knows_counts: %{{"rules", 1} => "1"}
        }
      ),
      v(
        :preview,
        "The read-only preview, filtered through the **same** call the context path uses — so what an author previews cannot drift from what a character's prompt actually contains. It says how much is held back without saying what.",
        %{
          preview: true,
          draft:
            bible(
              rules: rules(),
              canon: canon(),
              cover: "A drowned county that still collects its tolls."
            ),
          seen: bible(rules: [Enum.at(rules(), 0)], canon: canon())
        }
      ),
      v(
        :cover_written,
        "The cover. Written from everything below, secrets included, under instruction to give none of them away — which is why it is the one field a stranger is allowed to see.",
        %{
          cover:
            "A drowned county that still collects its tolls, and asks after the ones it took."
        }
      ),
      v(
        :generating,
        "A field being written. The skeleton is per-field, so the rest stays editable while one field thinks.",
        %{generating: MapSet.new(["setting"])}
      ),
      v(
        :name_clash,
        "Two worlds with the same name. Flagged on save rather than on every keystroke, because a name you are halfway through typing always clashes with nothing.",
        %{
          name: "Saltmarch",
          name_clash: %{id: "e2", name: "Saltmarch"}
        }
      ),
      v(
        :copied,
        "A world attached to a campaign is a **copy** — the original stays on the shelf and this one belongs to the story. The line says where it came from, so nobody edits this expecting the other to change.",
        %{
          copied_from: %{id: "e0", name: "Saltmarch"},
          copy_count: 3
        }
      ),
      v(
        :dirty,
        "Unsaved. The save bar is pinned to the frame rather than the document, and it carries the name clash — which is the one thing only Save can tell you.",
        %{dirty: true}
      )
    ]
  end
end

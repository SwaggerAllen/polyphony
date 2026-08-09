defmodule Storybook.Screens.ArcReview do
  use PhoenixStorybook.Story, :component

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Screens.ArcReview.screen/1

  defp entry(id, statement, opts \\ []) do
    %{
      id: id,
      statement: statement,
      reason: opts[:reason],
      kind: opts[:kind] || :revision,
      scope: opts[:scope] || "global",
      concealed: opts[:concealed] || false,
      released_topic: opts[:released_topic],
      sheet_field: opts[:sheet_field],
      subject_id: opts[:subject_id],
      # STR-62: who says so, the authoring axes, and a release's written condition.
      author: opts[:author],
      operation: opts[:operation],
      condition_met: opts[:condition_met],
      line_condition: opts[:line_condition]
    }
  end

  defp cast, do: [%{id: "wren", name: "Wren Ashgrove"}, %{id: "ilias", name: "Ilias"}]

  # The authoring form's whole state — the LiveView owns every value; a variation is
  # one shape of it.
  defp authoring(overrides) do
    Map.merge(
      %{
        world: false,
        subject_id: "wren",
        subject_name: "Wren Ashgrove",
        colour: "hsl(210 40% 55%)",
        kind: "fact",
        op: "add",
        items: [],
        picked: nil,
        picker_label: "Which one",
        was: nil,
        statement: "",
        because: "",
        until: "",
        and_then: "",
        never: false,
        timing: "now",
        scene_id: nil,
        scenes: [%{id: "c1-s3", label: "Scene 3"}],
        core: false,
        audience_label: "Nobody",
        audience_secret: false,
        who: "everyone",
        target: "",
        target_known: false,
        satisfied_disabled: false
      },
      overrides
    )
  end

  defp base do
    %{
      campaign_id: "camp-1",
      campaign_name: "The Salt Line",
      cast: cast(),
      tab: "wren",
      per_character: %{
        "wren" => [
          entry("a1", "She has stopped pretending the ledger is honest.",
            reason: "She signed for a crate she never saw, and said nothing.",
            sheet_field: "temperament"
          ),
          entry("a2", "Knows the tide bell is being rung by someone.",
            reason: "She heard it twice on a night with one tide.",
            kind: :release,
            concealed: true
          ),
          entry("a3", "Covering for her father — it broke.",
            reason:
              "She told Ilias the truth in front of three people. Nothing you wrote fired, but the scene reads as the line giving.",
            kind: :release,
            released_topic: "Can't stop covering for her father",
            condition_met: false,
            line_condition: "Someone she loves is going to be hurt by the silence."
          ),
          entry("a4", "She has taken to carrying her father's key.",
            kind: :discovery,
            sheet_field: "facts",
            author: "allen",
            operation: :add
          )
        ],
        "ilias" => []
      },
      world: [],
      groups: [],
      authoring: nil
    }
  end

  defp v(id, description, overrides),
    do: %Variation{
      id: id,
      description: description,
      attributes: base() |> Map.merge(overrides) |> Map.put(:id, to_string(id))
    }

  def variations do
    [
      v(
        :proposals,
        "What a scene decided about somebody, proposed rather than applied. Each carries a **Because** line and its provenance — accepting is a deliberate act, and refusing one is how you write the person who didn't go along with it.",
        %{}
      ),
      v(
        :nothing_pending,
        "A character the scene had nothing to say about. The gate is per-cast rather than per-backlog, so nineteen pending elsewhere does not block a scene with two.",
        %{tab: "ilias"}
      ),
      v(
        :editing,
        "Correcting a proposal before taking it, rather than accepting or rejecting whole. The precedent the authoring review panel is meant to copy.",
        %{editing: "a1"}
      ),
      v(
        :world_arc,
        "The world tab. A **global** fact reaches everywhere; a **local** one only its scene's location — which is why the scope is a control here rather than an assumption.",
        %{
          tab: "world",
          world: [
            entry("w1", "The tide bell is rung on nights with one tide.", scope: "global"),
            entry("w2", "The customs house keeps a second ledger.", scope: "local")
          ]
        }
      ),
      v(
        :group_fan_out,
        "A group change, collapsed into one card. It is really one proposal against the template plus one per current member — a group of twelve would otherwise flood the queue from a change nobody made twelve times.",
        %{
          groups: [
            %{
              id: "g1",
              name: "The Tidewatch",
              counts: %{group: 1, members: 1},
              pending: %{
                group: [entry("t1", "They no longer answer to the harbourmaster.")],
                members: [{"wren", [entry("m1", "She has stopped reporting in.")]}]
              }
            }
          ]
        }
      ),
      v(
        :authoring,
        "Writing an entry yourself — the simple case, a field holding **one value** like temperament or cover. The current value is struck through above the replacement, the Because is offered rather than demanded, and *when it became true* has three answers that are not degrees of the same thing.",
        %{
          authoring:
            authoring(%{
              kind: "temperament",
              op: "change",
              was: "Steady in the way of someone holding a door shut.",
              statement: "Steady, and starting to sound like it costs her.",
              because: "Two scenes of holding it together in front of Ilias.",
              timing: "scene",
              scene_id: "c1-s3"
            })
        }
      ),
      v(
        :authoring_list,
        "A field that holds many, so an operation comes first: add, change, remove. *Which one* has to be answerable before *what about it* — change strikes the picked fact through above its replacement, and removing is not deleting: it stops being true from here and stays in the history.",
        %{
          authoring:
            authoring(%{
              kind: "fact",
              op: "change",
              items: [
                %{
                  key: "She has stopped signing the register in her mother's hand.",
                  label: "She has stopped signing the register in her mother's hand."
                },
                %{
                  key: "She reads every manifest twice.",
                  label: "She reads every manifest twice."
                },
                %{
                  key: "Her father taught her the tide tables before she could write.",
                  label: "Her father taught her the tide tables before she could write."
                }
              ],
              picked: "She has stopped signing the register in her mother's hand.",
              was: "She has stopped signing the register in her mother's hand.",
              statement: "She has stopped signing the register at all."
            })
        }
      ),
      v(
        :authoring_line,
        "A refusal or a compulsion. A line is **never** or **earnable** — an earnable one carries an *until* and an *and then*, written now and not told to her until it happens. Four operations rather than three, because satisfaction is its own operation.",
        %{
          authoring:
            authoring(%{
              kind: "compulsion",
              op: "add",
              statement: "Can't stop covering for her father.",
              until: "Someone she loves is going to be hurt by the silence.",
              and_then: "She lets the silences sit, and lets people draw their own conclusions.",
              because: "She did it twice off-screen between sessions.",
              timing: "now"
            })
        }
      ),
      v(
        :authoring_relationship,
        "Directional, so you pick a direction: *Wren → Aldous* and *Aldous → Wren* are separate rows, four rows for two people. Changing what she thinks of him must not touch what he thinks of her, and a picker listing names invites exactly that.",
        %{
          authoring:
            authoring(%{
              kind: "relationship",
              op: "change",
              picker_label: "Which direction",
              items: [
                %{key: "aldous", label: "Aldous Ashgrove", prefix: "Wren → "},
                %{key: "ilias", label: "Ilias Vane", prefix: "Wren → "}
              ],
              picked: "aldous",
              was:
                "She has spent her whole life covering for him and has never once asked what for.",
              statement: "She has started asking, and doesn't like the answers.",
              target: "Aldous Ashgrove",
              target_known: true
            })
        }
      ),
      v(
        :authoring_world,
        "The world's own entries: the same form with a shorter dropdown — a fact or a rule — and one control more. Every entry carries **who knows**, and a world's default audience is everyone, so narrowing is what marks an entry rather than widening.",
        %{
          tab: "world",
          authoring:
            authoring(%{
              world: true,
              subject_id: "camp-1",
              subject_name: "The Salt Line",
              colour: "var(--bcm)",
              kind: "fact",
              op: "add",
              statement:
                "The tide bell has been rung twice in a night, for the first time in nine years.",
              who: "everyone",
              timing: "scene",
              scene_id: "c1-s3"
            })
        }
      ),
      v(
        :world_common_knowledge,
        "A fact proposed as everyone's. Its own state because of the **audience control** it carries, not because its actions differ — *everyone* and *only who was there* are two values of one question, and picking between them isn't the same act as accepting the fact. Accepting means anyone off-screen is told the next time they turn up.",
        %{
          tab: "world",
          world: [
            entry(
              "w9",
              "The tide bell has been rung twice in a night, for the first time in nine years.",
              kind: :discovery,
              reason: "The whole quay heard it.",
              scope: "global"
            )
          ]
        }
      )
    ]
  end
end

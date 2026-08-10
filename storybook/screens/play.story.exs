defmodule Storybook.Screens.Play do
  use PhoenixStorybook.Story, :component

  alias PolyphonyCore.Scene.Cast
  alias PolyphonyWeb.Transcript

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Screens.Play.screen/1

  # Names are display and ids are the routing key, so the screen resolves through a
  # `%Cast{}` exactly the way the running app does. A bare map wouldn't match
  # `render_name/2`, which is the point of using the real struct here.
  defp cast,
    do: %Cast{id_to_name: %{"wren" => "Wren Ashgrove", "ilias" => "Ilias", "sable" => "Sable"}}

  defp world(beat, content),
    do: %{kind: "WorldEventOccurred", payload: %{beat: beat, content: content}}

  defp said(beat, who, content, extra \\ %{}) do
    %{
      kind: "SpeechUttered",
      payload:
        Map.merge(
          %{beat: beat, packet_id: "s-#{beat}-#{who}", character_id: who, content: content},
          extra
        )
    }
  end

  defp thought(beat, who, content) do
    %{
      kind: "ThoughtOccurred",
      payload: %{
        beat: beat,
        packet_id: "t-#{beat}-#{who}",
        character_id: who,
        content: content
      }
    }
  end

  defp scene do
    [
      world(1, "The tide bell rings twice. An arrival nobody logged."),
      said(1, "wren", "Nothing came in tonight."),
      thought(1, "wren", "Which is its own kind of answer."),
      said(2, "ilias", "Then we agree it was nothing.")
    ]
  end

  # The real slot shape (`PolyphonyWeb.Play.Strip.slot/0`): the label is the initials-ish
  # short form the tracker draws, and `you` is what marks the viewer's own slot.
  defp slot(id, name, state, opts \\ []) do
    %{
      id: id,
      name: name,
      label: name |> String.upcase() |> String.slice(0, 5),
      state: state,
      colour: opts[:colour],
      you: opts[:you] || false
    }
  end

  defp base do
    %{
      register: :stage,
      viewer: :omniscient,
      cast: cast(),
      scene_id: "scene-1",
      scene_title: "The Saltmarch customs house",
      campaign_name: "The Salt Line",
      messages: scene(),
      next_beat: 3,
      roster: ["wren", "ilias"],
      strip: %{
        slots: [
          slot("wren", "Wren Ashgrove", :took),
          slot("ilias", "Ilias", :took)
        ],
        sentence: nil,
        tone: nil
      },
      progress: %{phase: :idle, subject: nil, beat: nil},
      writing_in: MapSet.new(),
      branch: nil,
      branching: nil
    }
  end

  defp v(id, description, overrides) do
    # Each variation gets its own id prefix: storybook renders them all on one page, so
    # without it every `#say-input` in the file is the same element as far as the DOM is
    # concerned.
    attrs = base() |> Map.merge(overrides) |> Map.put(:id, to_string(id))
    %Variation{id: id, description: description, attributes: transcript(attrs)}
  end

  # A variation writes `messages:` — the honest fixture, the shape the broadcaster emits —
  # and the screen takes `{dom_id, beat}` pairs, because that is what a `LiveStream`
  # enumerates to. Derived here, once, rather than in fourteen variations: a story that had
  # to hand-build beat trees would be a story about a rendering mechanism.
  defp transcript(attrs) do
    beats =
      attrs
      |> Map.get(:messages, [])
      |> Transcript.beats()
      |> Transcript.with_failures(
        Map.get(attrs, :failures, []),
        Map.get(attrs, :next_beat, 1) - 1
      )

    attrs
    |> Map.delete(:messages)
    # Prefixed by variation: storybook renders all fourteen on one page, so a bare
    # `beat-2` is the same DOM id in every one of them.
    |> Map.put(:beats, Enum.map(beats, &{"#{attrs.id}-beat-#{&1.beat}", &1}))
    |> Map.put(:transcript_empty, beats == [])
  end

  # The connection banners are driven by the classes **LiveView puts on the container**,
  # not by an assign — which is what makes them free of server state, and also what made
  # them impossible to look at. A per-variation template puts the class on an ancestor, so
  # they are reviewable the same way every other state is.
  defp connection(id, class, description) do
    %{v(id, description, %{}) | template: ~s|<div class="#{class}"><.psb-variation/></div>|}
  end

  def variations do
    [
      connection(
        :reconnecting,
        "phx-loading",
        "The socket dropped and is coming back. A scene is a long-lived socket and this is the state a real reader hits on a train, so it promises recovery rather than describing a fault — reconnecting replays the canonical log, so nothing written is at risk. Driven by the class LiveView sets on the container, which is why it needs no server state."
      ),
      connection(
        :disconnected,
        "phx-error",
        "The socket is gone and not currently coming back. Distinct from a **generation** failure, which is a gap in the fiction with a retry on it — this is the transport, and the scene on screen is still true, just no longer live."
      ),
      v(
        :stage,
        "Omniscient play — the working register. Everything is visible, including interiority, and the composer writes as whoever the perspective control names.",
        %{}
      ),
      v(
        :page,
        "The same scene read as Wren. The reading register drops the gutter labels and simply gets bigger; a filtered scene is a *shorter* scene, with no markers where something was hidden — that is a standing decision, not an omission.",
        %{
          register: :page,
          viewer: {:character, "wren"},
          messages: [
            world(1, "The tide bell rings twice. An arrival nobody logged."),
            said(1, "wren", "Nothing came in tonight."),
            thought(1, "wren", "Which is its own kind of answer.")
          ]
        }
      ),
      v(
        :branching,
        "About to take a second run at it. The confirm names the beat, which the divider deliberately does not, then the three things people get wrong: what comes with you, where you end up, and that the original is untouched. No *are you sure* — nothing is destroyed and walking away undoes it, so deletion's grammar would misrepresent the act. The header carries the branch pill because this campaign already has more than one line; its dot is gold here because this is the canonical one.",
        %{
          branch: %{name: "The Salt Line", canon?: true},
          branching: 3,
          messages:
            scene() ++
              [
                said(3, "wren", "Say it was nothing, then. Sign for it."),
                said(4, "ilias", "He signs. The pen takes longer than the sentence did.")
              ],
          next_beat: 5
        }
      ),
      v(
        :empty,
        "A scene nobody has played yet. The state most likely to be wrong and least likely to be seen, because the moment you test the app you have already written a turn into it.",
        %{
          messages: [],
          roster: [],
          strip: %{slots: [], sentence: nil, tone: nil},
          next_beat: 0
        }
      ),
      v(
        :director_writing,
        "The Director is composing the beat. A placeholder rather than an absence: the block draws its rules and skeleton lines so the beat reads as *moving* rather than hung.",
        %{
          progress: %{phase: :director, subject: nil, beat: 3},
          strip: %{
            slots: [slot("wren", "Wren Ashgrove", :wait)],
            sentence: "The Director is setting the scene…",
            tone: "working"
          }
        }
      ),
      v(
        :generating,
        "A cast turn being written. The strip names who, because a tracker that goes quiet while time passes is the thing that reads as broken.",
        %{
          progress: %{phase: :generating, subject: "ilias", beat: 3},
          strip: %{
            slots: [slot("ilias", "Ilias", :now)],
            sentence: "Ilias is writing their turn…",
            tone: "working"
          }
        }
      ),
      v(
        :awaiting_you,
        "The loop has walked to a user-controlled slot and stopped. The composer answers *that* slot at *that* beat — a turn committed free at `next_beat` instead is the multiple-yields-per-beat bug this state exists to prevent.",
        %{
          progress: %{phase: :awaiting_user, subject: "wren", beat: 3},
          speaker: "wren",
          strip: %{
            slots: [slot("wren", "Wren Ashgrove", :now, you: true)],
            sentence: "Waiting for you to write Wren Ashgrove…",
            tone: "waiting"
          }
        }
      ),
      v(
        :failed_turn,
        "A terminal generation failure, rendered in place. The beat carries on and closes around it — a failure is a visible gap, not a stall — and it is scoped per viewer, so a character's read never shows somebody else's error.",
        %{
          failures: [
            %{
              id: "f1",
              beat: 2,
              subject: "sable",
              reason: "empty_response",
              retryable: true
            }
          ]
        }
      ),
      v(
        :auto_running,
        "Full auto. It runs until the Director closes the scene, the room empties, or the fifty-beat cap — the three ends are the whole design, since an auto mode without a stop condition is a way to spend money by accident.",
        %{
          auto: %{status: "running", beats_run: 12, max_beats: 50, ended_reason: nil},
          progress: %{phase: :generating, subject: "wren", beat: 13}
        }
      ),
      v(
        :auto_paused,
        "Paused. The pause is a row in the database checked at the top of every beat, not a message to a process, so it survives the tab that set it.",
        %{
          auto: %{status: "paused", beats_run: 12, max_beats: 50, ended_reason: nil}
        }
      ),
      v(
        :auto_stopped_at_cap,
        "The cap reached. It says which of the three ends it hit, because 'it stopped' and 'it finished' are different things to a reader.",
        %{
          auto: %{
            status: "stopped",
            beats_run: 50,
            max_beats: 50,
            ended_reason: "Reached the beat cap."
          }
        }
      ),
      v(
        :draft_pending,
        "A generated turn waiting to be accepted or discarded. Play has always worked this way and authoring does not — the asymmetry the review-panel issue exists to close.",
        %{
          drafts: [
            %{
              row: %{id: "d1", character_id: "wren", beat: 3},
              packet: %{
                moves: [
                  %{
                    seq: 0,
                    type: :speech,
                    content: "I logged it as nothing.",
                    audibility: "public",
                    addressed_to: []
                  },
                  %{
                    seq: 1,
                    type: :thought,
                    content: "That is what the book will say, anyway.",
                    audibility: nil,
                    addressed_to: []
                  }
                ]
              }
            }
          ]
        }
      ),
      v(
        :who_panel,
        "The who-is-this panel. A reader meeting a name for the first time gets what the scene has actually shown them plus the character's cover — never the sheet, which is the author's.",
        %{
          who: %{
            name: "Sable",
            pronouns: "she/her",
            cover: "A customs clerk who signs for things she never sees.",
            hue: 210
          }
        }
      ),
      v(
        :intros_panel,
        "The Director asks; the GM decides. **One** suggestion, named and reasoned — the GM is being asked to ratify a judgement about the scene, and a queue of them turns that into picking from a roster. *They'll be* is set before they are in the room, because the answer changes what admitting them means and it is much harder to explain afterwards.",
        %{
          panel: :intros,
          intros_view: :panel,
          suggestion: %{
            name: "Sable Quist",
            reason: "Somebody rang that bell",
            colour: "var(--v4)",
            ready?: true
          }
        }
      ),
      v(
        :intros_no_suggestion,
        "The Director has nobody to propose. It says so, and says it will ask when the scene needs someone — the difference between a system with nothing to say and one that has stopped working. Both of the GM's doors stay, which is what makes them load-bearing: on a two-hander that never needs a third voice, this is the only version of the panel anybody sees.",
        %{panel: :intros, intros_view: :panel, suggestion: nil}
      ),
      v(
        :intros_write_new,
        "Writing somebody into the scene, without leaving play. The note at the bottom is the important part and shouldn't be dropped — somebody typing one line into a scene needs to know they are not creating a throwaway. Both actions end in a full character; only the route differs.",
        %{
          panel: :intros,
          intros_view: :write_new,
          new_name: "A harbour constable",
          new_premise:
            "Came down for the noise, knows Wren's father, not on anyone's payroll yet."
        }
      ),
      v(
        :intros_picker,
        "Find someone you've written. **Scoped to this campaign** — characters don't cross campaigns, and what the picker adds over the Director's suggestion is reach *within* one: the walk-ons it would never propose. Tier leads the filters because that is the roster that gets long. Characters already in the scene appear dimmed and inert rather than missing, so nobody hunts for somebody standing in front of them.",
        %{
          panel: :intros,
          intros_view: :picker,
          picker_query: "",
          picker_rows: [
            %{
              id: "sable",
              name: "Sable Quist",
              blurb: "Rings the tide bell for whoever pays her.",
              tier_label: "Recurring",
              colour: "var(--v4)",
              in_scene?: false
            },
            %{
              id: "corrigan",
              name: "Mother Corrigan",
              blurb: "Keeps the ledger nobody asks about.",
              tier_label: "Recurring",
              colour: "var(--v2)",
              in_scene?: false
            },
            %{
              id: "wren",
              name: "Wren Ashgrove",
              blurb: "Keeps the tide ledger, and keeps it honest.",
              tier_label: "Main cast",
              colour: "var(--v1)",
              in_scene?: true
            }
          ]
        }
      ),
      v(
        :intros_picker_empty,
        "No matches, and not a dead end. Somebody who typed *alchemist* and found none wants an alchemist, and the panel already has a door for that — so the offer is to write the thing that was searched for, carrying the query into the name.",
        %{
          panel: :intros,
          intros_view: :picker,
          picker_query: "alchemist",
          picker_rows: []
        }
      ),
      v(
        :intros_picker_confirm,
        "Chosen, not yet admitted. A second step rather than one-click entry from the row: enough to catch *wrong Sable* before she walks in, and the last moment the *they'll be* answer can be given.",
        %{
          panel: :intros,
          intros_view: :picker_confirm,
          picker_chosen: %{
            id: "sable",
            name: "Sable Quist",
            blurb: "Rings the tide bell for whoever pays her, and has never once said who did.",
            tier_label: "Recurring · last seen in scene 1",
            colour: "var(--v4)",
            in_scene?: false
          }
        }
      ),
      v(
        :intros_arc_gate,
        "They're behind, and this is where you catch them up. Casting somebody is casting somebody wherever you do it, so the gate is met here too — with **the same cards** the review screen shows. *Accept all and bring them on* is one tap and carries straight on into the entrance it interrupted; *Not now* leaves them out and their arc where it was.",
        %{
          panel: :intros,
          intros_view: :arc_gate,
          arc_gate: %{
            id: "sable",
            name: "Sable Quist",
            colour: "var(--v4)",
            editing: nil,
            proposals: [
              %{
                id: 951,
                kind: "revision",
                sheet_field: "temperament",
                statement: "Careful in the way of somebody who has been caught once.",
                reason: "She was seen on the quay and said nothing about why.",
                released_topic: nil,
                operation: nil,
                condition_met: nil,
                author: nil,
                line_condition: nil,
                concealed: false,
                scope: nil
              },
              %{
                id: 952,
                kind: "discovery",
                sheet_field: "facts",
                statement: "She has been paid twice for the same night's ringing.",
                reason: "Ilias counted the ledger out loud.",
                released_topic: nil,
                operation: nil,
                condition_met: nil,
                author: nil,
                line_condition: nil,
                concealed: false,
                scope: nil
              }
            ]
          }
        }
      ),
      v(
        :admitted_writing,
        "In the room, sheet still being written. The beat carries on without them. The entrance reads as fiction first — *a man comes up the steps from the water* — and nobody sees a sheet being written, which is why the roster's line and the transcript's line say different things.",
        %{
          panel: :intros,
          intros_view: :panel,
          suggestion: nil,
          admitted: [
            %{id: "bellman", name: "The bellman", colour: "var(--v4)", status: :writing}
          ]
        }
      ),
      v(
        :admitted_failed,
        "In the room, and writing them didn't work. Distinct from `failed_turn`: that is a turn that couldn't be generated inside a working scene, this is a character with no sheet already standing in it. Three genuinely different ways out — and *send them away* is a departure written into the transcript, not an edit to the log, because the entrance already happened and the others saw it.",
        %{
          panel: :intros,
          intros_view: :panel,
          suggestion: nil,
          admitted: [
            %{id: "bellman", name: "The bellman", colour: "var(--v4)", status: :failed}
          ]
        }
      )
    ]
  end
end

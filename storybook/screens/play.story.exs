defmodule Storybook.Screens.Play do
  use PhoenixStorybook.Story, :component

  alias PolyphonyCore.Scene.Cast

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
      writing_in: MapSet.new()
    }
  end

  defp v(id, description, overrides) do
    # Each variation gets its own id prefix: storybook renders them all on one page, so
    # without it every `#say-input` in the file is the same element as far as the DOM is
    # concerned.
    attrs = base() |> Map.merge(overrides) |> Map.put(:id, to_string(id))
    %Variation{id: id, description: description, attributes: attrs}
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
        "The introductions panel, with both lists it can offer. Characters who can walk in, and the walk-ons this story invented and never wrote — a separate list with a separate control, because the honest offer is *write them, then bring them in*.",
        %{
          panel: :intros,
          joinable: [%{id: "sable", name: "Sable"}],
          writable: [%{id: "corrigan", name: "Corrigan"}]
        }
      ),
      v(
        :intros_exhausted,
        "The same panel with nothing left to offer. Worth looking at because an empty panel that says nothing reads as broken.",
        %{
          panel: :intros,
          joinable: [],
          writable: []
        }
      )
    ]
  end
end

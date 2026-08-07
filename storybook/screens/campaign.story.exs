defmodule Storybook.Screens.Campaign do
  use PhoenixStorybook.Story, :component

  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Authoring.WorldBible
  alias PolyphonyCore.Blob
  alias PolyphonyCore.Content.CampaignConfig
  alias Polyphony.LLM.Settings
  alias Polyphony.ReadModels.{BuildRun, LibraryEntry}

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Screens.Campaign.screen/1

  # Cast rows are library rows, and a character's name, blurb, hue and tier all come out
  # of the stored sheet — so the fixtures carry a real encoded payload rather than a map
  # that merely looks like one. Anything less and the story would be exercising a
  # different code path from the app.
  defp character(id, name, opts),
    do: %LibraryEntry{
      id: id,
      kind: "character",
      owner_id: "1",
      visibility: "private",
      payload:
        Blob.encode(%CharacterSheet{
          name: name,
          premise: opts[:premise],
          status: opts[:status] || :full,
          tier: opts[:tier] || :main,
          # Hues are assigned by cast order and have to be stable, so a sheet carries
          # its own — an unhued character takes the neutral base, which is what "no
          # voice" looks like and is not what a cast member is.
          hue: opts[:hue]
        })
    }

  defp campaign_entry(opts \\ []),
    do: %LibraryEntry{
      id: 1,
      kind: "campaign",
      owner_id: "1",
      visibility: opts[:visibility] || "private"
    }

  defp cast,
    do: [
      character(11, "Wren Ashgrove",
        hue: 1,
        premise: "Keeps the tide ledger, and keeps it honest."
      ),
      character(12, "Ilias Vane", hue: 2, premise: "Signs what she logs.", tier: :recurring),
      character(13, "The bell-ringer", hue: 3, tier: :incidental, premise: "Rings it anyway.")
    ]

  defp world,
    do: %{
      "name" => "Saltmarch",
      "setting" => "A drowned county that still collects its tolls.",
      "tone" => "Patient, and a little tired.",
      "rules" => "The tide comes in twice on a bad night.",
      "starting_canon" => "The wall failed twice the year Wren was born."
    }

  defp bible(opts \\ []),
    do: %WorldBible{
      name: "Saltmarch",
      cover: "A drowned county that still collects its tolls.",
      setting:
        Keyword.get(
          opts,
          :setting,
          "Tidal flats, a sea wall, and a customs house nobody has repaired since the second failure."
        ),
      tone: Keyword.get(opts, :tone, "Patient, and a little tired."),
      rules: opts[:rules] || [],
      starting_canon: opts[:canon] || []
    }

  # Storybook does not apply `attr` defaults — a variation's attributes are the whole of
  # the assigns — so every key the screen reads is named once, here.
  defp defaults do
    %{
      current_user: %{id: "u1", username: "wren", role: "user"},
      entry: campaign_entry(),
      payload: %{
        name: "The Salt Line",
        kind: :campaign,
        premise: "A shipment came in that isn't on any manifest.",
        scenes: []
      },
      tab: "settings",
      viewer: :omniscient,
      seen: nil,
      cast: cast(),
      addable: [character(14, "Marek Holt", hue: 4, tier: :recurring)],
      groups: [
        %{id: "g1", name: "The Tidewatch", colour: "hsl(210 40% 55%)", members: 6, secrets: 2}
      ],
      scenes: [],
      bibles: [%LibraryEntry{id: 21, kind: "world_bible", payload: Blob.encode(bible())}],
      bible_id: 21,
      bible_name: "Saltmarch",
      world: world(),
      llm: Settings.from_payload(%{}),
      global_models: %{workhorse: "a-workhorse-model", heavy: "a-heavy-model"},
      content: CampaignConfig.from_payload(%{}),
      quick_build_open: false,
      qb_seeds: [""],
      qb_world: "",
      qb_groups: false,
      qb_suggest: true,
      build: nil,
      scene_cast: nil,
      scene_location: "",
      scene_premise: "",
      scene_suggesting: false,
      generating: false,
      expanding_premise: false,
      writing_in: MapSet.new(),
      published?: false,
      publish_help: false,
      publish_warning: nil,
      pub_spectator: false,
      pub_forkable: false,
      pub_perspectives: []
    }
  end

  defp v(id, description, overrides),
    do: %Variation{
      id: id,
      description: description,
      attributes: defaults() |> Map.merge(overrides) |> Map.put(:id, to_string(id))
    }

  # A campaign with nothing in it yet: no world, no cast, no premise. The amber dots on
  # the tabs are first-run only, so this is the one state that shows them.
  defp first_run,
    do: %{
      payload: %{name: "", kind: :campaign, scenes: []},
      cast: [],
      addable: [],
      groups: [],
      bibles: [],
      bible_id: nil,
      bible_name: nil,
      world: nil,
      seen: nil
    }

  def variations do
    [
      v(
        :settings,
        "What a campaign is allowed to contain, and what writes it. The ceiling is stated in the author's vocabulary rather than the config's — a ceiling, not a target, with each character's own limits still holding underneath it.",
        %{}
      ),
      v(
        :first_run,
        "A campaign that is nothing but a name. Quick Build leads as a **card, not a tab** — it is a one-shot, and a tab for it would be dead weight from the second day. The amber dots mark what hasn't been built; they go the moment anything exists.",
        first_run()
      ),
      v(
        :quick_build,
        "The one-shot, open. A world seed and a concept per character, and two switches that are both off by default because each is another provider call — off-screen relationships, and the groups the world names.",
        Map.merge(first_run(), %{
          quick_build_open: true,
          qb_world: "A rain-drowned harbour city where debts are paid in memories.",
          qb_seeds: [
            "a disgraced harbour-master who sold her own past",
            "the clerk who bought it"
          ]
        })
      ),
      v(
        :building,
        "A build in progress, drawn from the run row rather than from socket state — so it is the same card whether you started it, came back on a phone, or reloaded mid-run. It says the work is on the server, which is what makes leaving safe.",
        %{
          build: %BuildRun{
            status: "running",
            label: "Writing Ilias Vane",
            detail: "3 of 4 characters",
            step: 2,
            total: 5
          }
        }
      ),
      v(
        :build_failed,
        "A build that stopped. It **resumes** rather than restarting, so it costs only what is left — and the button has to be here, because a failed build has already attached its world, which means the campaign is no longer first-run and the card offering Quick Build is gone.",
        %{
          build: %BuildRun{
            status: "failed",
            label: "Writing the cast",
            detail: "The provider refused twice.",
            step: 3,
            total: 5
          }
        }
      ),
      v(
        :world,
        "The attached world, read rather than edited — enough to know what the Director is working from without leaving the campaign. Attaching one **copies** it: a campaign accumulates its own world arc, so two campaigns can't share a bible.",
        %{
          tab: "world",
          seen:
            bible(
              rules: [
                %WorldBible.Entry{statement: "The tide comes in twice on a bad night."},
                %WorldBible.Entry{
                  statement: "The bell is rung by somebody, not something.",
                  concealed: true
                }
              ],
              canon: [
                %WorldBible.Entry{statement: "The wall failed twice the year Wren was born."}
              ]
            )
        }
      ),
      v(
        :world_none,
        "No world, and nowhere in the app used to write one — the picker was the whole tab, so a campaign that skipped Quick Build faced a list it had no way to add to. A campaign can play without one, but the Director has much less to go on.",
        Map.merge(first_run(), %{tab: "world"})
      ),
      v(
        :world_as_character,
        "The same world through one character's eyes. This is the reason the perspective control belongs on a screen that only reviews content: what Wren knows of the world is a question you can answer no other way, and it resolves group membership **live** rather than at writing time.",
        %{
          tab: "world",
          viewer: {:character, "11"},
          seen:
            bible(
              rules: [%WorldBible.Entry{statement: "The tide comes in twice on a bad night."}],
              canon: [
                %WorldBible.Entry{statement: "The wall failed twice the year Wren was born."}
              ]
            )
        }
      ),
      v(
        :cast,
        "The people. Main cast reads as the short list you authored; walk-ons collapse behind a count, because a quick-built campaign arrives with three people you asked for and a dozen the cast introduced.",
        %{tab: "cast"}
      ),
      v(
        :cast_pending,
        "Stubs somebody else's relationships invented. They arrive in batches, so one button fills them all rather than twenty trips through the editor.",
        %{
          tab: "cast",
          cast:
            cast() ++
              [
                character(15, "Her mother", status: :stub, tier: :recurring),
                character(16, "The man from the office", status: :stub, tier: :incidental)
              ]
        }
      ),
      v(
        :cast_empty,
        "Nobody yet. A campaign needs at least one character before a scene can open, so the empty state offers the write rather than explaining the rule.",
        Map.merge(first_run(), %{tab: "cast"})
      ),
      v(
        :publish,
        "What a reader gets. Publishing a head is a **spoiler control, not a reading preference** — it hands over what that character knew while they knew it — so nothing here is ticked by default, and the list is in tier order rather than the accident of cast order.",
        %{pub_spectator: true, pub_perspectives: ["11"], pub_forkable: true}
      ),
      v(
        :publish_gap,
        "A scene nobody published will be able to read. The gap can be the point; it just must not happen by accident.",
        %{
          pub_perspectives: ["11"],
          publish_warning: %{scenes: [%{title: "The quay, after the second bell"}]}
        }
      ),
      v(
        :premise,
        "The pitch, and the title with it. The title used to sit in Settings with the model pickers — but a title isn't configuration, it's the first line of the pitch, written in the same sitting out of the same material.",
        %{tab: "premise"}
      ),
      v(
        :scenes,
        "Setting one. Who's in it is a choice with a cost — the roster is what turn order walks — and everyone ready is the default, so an author who never touches it gets what they always got. The premise here is the **scene's**, not the campaign's; blank falls back.",
        %{
          tab: "scenes",
          scene_location: "The quay, after the second bell",
          scene_premise: "The ledger is due at the office by dawn and only one of them knows it.",
          scenes: ["c1-s1", "c1-s2"],
          payload: %{
            name: "The Salt Line",
            kind: :campaign,
            premise: "A shipment came in that isn't on any manifest.",
            scenes: ["c1-s1", "c1-s2"]
          }
        }
      ),
      v(
        :scenes_write_in,
        "A walk-on the story invented for itself, offered where you pick a cast. `SceneControl` refuses a non-full character, so a chip for one would be a choice that can't be honoured — writing them in puts them straight into the scene.",
        %{
          tab: "scenes",
          cast: cast() ++ [character(15, "The man from the office", status: :stub)],
          writing_in: MapSet.new([15])
        }
      ),
      v(
        :scenes_empty,
        "Nothing has happened yet, on a campaign with a cast ready to make it happen.",
        %{tab: "scenes"}
      )
    ]
  end
end

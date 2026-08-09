defmodule Storybook.Screens.Browse do
  use PhoenixStorybook.Story, :component

  alias PolyphonyCore.Publication

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Screens.Browse.screen/1

  defp pub(perspectives \\ ["wren", "ilias"], opts \\ []),
    do: %Publication{
      perspectives: perspectives,
      forkable: opts[:forkable] || false,
      spectator: opts[:spectator] != false
    }

  defp row(id, name, opts \\ []) do
    %{
      id: id,
      name: name,
      author: opts[:author] || "@ilias",
      blurb: opts[:blurb] || "A customs house that signs for things nobody sees.",
      scenes: opts[:scenes] || 9,
      pub: opts[:pub] || pub(),
      heads: length((opts[:pub] || pub()).perspectives),
      withheld: opts[:withheld] || [],
      copies: opts[:copies] || 0
    }
  end

  defp scene(id, title), do: %{id: id, title: title}

  defp snapshot,
    do: %{
      name: "The Salt Line",
      premise: "A customs house that signs for things nobody sees.",
      scenes: [scene("sc1", "The tide bell"), scene("sc2", "What the ledger says")],
      characters: [%{source_id: "wren"}, %{source_id: "ilias"}],
      publication: pub()
    }

  # ── Reading ──────────────────────────────────────────────────────────────────

  # The reader needs more of a snapshot than the front page does: scene **cast**, which
  # is what decides whether a perspective can show you a scene at all, and pinned
  # **sheets**, which is where the voice colours come from. Sable is published as a
  # perspective and is in neither scene — that is what makes the selector's second
  # group, and `reading_not_present`, real rather than hypothetical.
  defp read_pub, do: pub(["wren", "ilias", "sable"])

  defp read_scene(id, title, cast), do: %{id: id, title: title, cast: cast}

  defp read_snapshot do
    %{
      name: "The Salt Line",
      bible: %{name: "The Salt Line", cover: "A customs house that signs for things nobody sees."},
      scenes: [
        read_scene("sc1", "The tide bell", ["wren", "ilias"]),
        read_scene("sc2", "What the ledger says", ["wren", "ilias"])
      ],
      characters: [
        %{source_id: "wren", sheet: %{name: "Wren Ashgrove", hue: 1}},
        %{source_id: "ilias", sheet: %{name: "Ilias", hue: 2}},
        %{source_id: "sable", sheet: %{name: "Sable", hue: 3}}
      ],
      publication: read_pub()
    }
  end

  defp world(content), do: %{kind: "WorldEventOccurred", payload: %{beat: 1, content: content}}

  defp said(beat, who, content),
    do: %{
      kind: "SpeechUttered",
      payload: %{beat: beat, packet_id: "p-#{beat}-#{who}", character_id: who, content: content}
    }

  defp thought(beat, who, content),
    do: %{
      kind: "ThoughtOccurred",
      payload: %{beat: beat, packet_id: "t-#{beat}-#{who}", character_id: who, content: content}
    }

  # What Wren's projection of the first scene contains. Her own interiority is in it and
  # nobody else's — that filtering is `PolyphonyCore.Visibility`'s, done before these
  # events reach a screen, so the fixture states the result rather than the rule.
  defp read_events do
    [
      world("The tide bell rings twice. An arrival nobody logged."),
      said(1, "wren", "Nothing came in tonight."),
      thought(1, "wren", "Which is its own kind of answer."),
      said(2, "ilias", "Then we agree it was nothing.")
    ]
  end

  defp read(overrides) do
    defaults()
    |> Map.merge(%{
      story: %{id: "s1"},
      row: row("s1", "The Salt Line", pub: read_pub()),
      snapshot: read_snapshot(),
      pub: read_pub(),
      mode: {:character, "wren"},
      names: %{"wren" => "Wren Ashgrove", "ilias" => "Ilias", "sable" => "Sable"},
      scene: read_scene("sc1", "The tide bell", ["wren", "ilias"]),
      events: read_events()
    })
    |> Map.merge(overrides)
  end

  # Storybook does not apply `attr` defaults — a variation's attributes are the whole
  # of the assigns — so every key the screen reads is named here. That is a feature
  # rather than a chore: a state is described completely or not at all.
  defp defaults do
    %{
      current_user: %{id: "u1", username: "wren", role: "user"},
      bookmark: nil,
      tab: "stories",
      stories: [],
      worlds: [],
      story: nil,
      row: nil,
      snapshot: nil,
      pub: nil,
      names: %{},
      mode: nil,
      scene: nil,
      events: [],
      gap: nil,
      gone: nil,
      who: nil,
      reporting: nil
    }
  end

  defp base do
    Map.merge(defaults(), %{
      stories: [
        %{
          lead: row("s1", "The Salt Line", copies: 2),
          forks: [row("s2", "The Salt Line", author: "@sable")]
        },
        %{lead: row("s3", "Nightjar", scenes: 3, pub: pub(["corrigan"])), forks: []}
      ]
    })
  end

  defp front(overrides) do
    defaults()
    |> Map.merge(%{
      story: %{id: "s1"},
      row: row("s1", "The Salt Line"),
      snapshot: snapshot(),
      pub: pub(),
      mode: :limited,
      names: %{"wren" => "Wren Ashgrove", "ilias" => "Ilias"}
    })
    |> Map.merge(overrides)
  end

  defp v(id, description, attrs),
    do: %Variation{
      id: id,
      description: description,
      attributes: Map.put(attrs, :id, to_string(id))
    }

  def variations do
    [
      v(
        :listing,
        "What's been published. Forks are grouped under the story they came from rather than listed beside it — three forks share a title until somebody renames one, and a flat list of those reads as duplicates.",
        base()
      ),
      v(
        :nothing_published,
        "An empty shelf. Reachable on any fresh install and on a quiet week, and it has to say something rather than render as a blank page.",
        %{base() | stories: []}
      ),
      v(
        :front_page,
        "A story's front page. **How you can read it** is the author's content decision — which heads they granted — and it is offered before anything else, because reading a campaign means choosing whose story it is.",
        front(%{})
      ),
      v(
        :start_reading,
        "A reader who has never opened this one. The button says *Start reading* and sends them to the first scene.",
        front(%{mode: :limited, bookmark: nil})
      ),
      v(
        :carry_on,
        "The same page for somebody who got partway. The shelf promises exactly one thing — you can get back to where you were — and this is where it is kept.",
        front(%{mode: :limited, bookmark: %{scene_id: "sc2", perspective: "wren"}})
      ),
      v(
        :bookmark_gone,
        "A bookmark into a scene the author's republish removed. It falls back to the start rather than stranding the reader on a link into nothing — republishing replaces the copy somebody was in the middle of, which is the one place that trade shows.",
        front(%{mode: :limited, bookmark: %{scene_id: "deleted", perspective: "wren"}})
      ),
      v(
        :reading,
        "A scene, read as one of the heads the author published. The play screen with a different bottom bar — same header, same perspective control, same transcript, same beat rules — in the `.page` register, because this isn't an authoring surface. Wren's own interiority is here and nobody else's; the selector's second group names Sable, who is published and wasn't in this scene.",
        read(%{})
      ),
      v(
        :reading_spectator,
        "The same scene read as a spectator: everything said and done, nobody's thoughts. This is the difference the product exists for — one scene, two heads, genuinely different text — and it is a property of the projection rather than a display setting.",
        read(%{
          mode: :spectator,
          events:
            List.delete(read_events(), thought(1, "wren", "Which is its own kind of answer."))
        })
      ),
      v(
        :reading_not_present,
        "Read as somebody who wasn't in this scene. A fact about the reader's **perspective**, so it has a way out — switch heads, or carry on — and the scene is shown rather than skipped, because silently dropping it would make the numbering lie.",
        read(%{mode: {:character, "sable"}, gap: :not_present, events: []})
      ),
      v(
        :not_shared,
        "A scene no granted perspective can reach, opened. A fact about the **publication**, so unlike `reading_not_present` it offers no way out. It stays in the contents too, marked — silently omitting it would make the story look shorter than it is, and the gap is a fact about the publication rather than an error.",
        read(%{
          mode: :limited,
          scene: read_scene("sc2", "What the ledger says", []),
          gap: :not_shared,
          events: []
        })
      ),
      v(
        :reading_who,
        "Who is this, opened from a name in the transcript. A reader meets six names in two pages and had no way to ask about any of them without leaving the story. It shows the **cover** — the field written to be shown — never the sheet.",
        read(%{
          who: %{
            name: "Ilias",
            pronouns: "he/him",
            hue: 2,
            cover: "The customs clerk who signs for what he doesn't look at."
          }
        })
      ),
      v(
        :reading_last_scene,
        "The end of the story. *That's the end of it* rather than a dead Next button — to a reader, running out and being finished are different events and only one of them wants somewhere to go.",
        read(%{scene: read_scene("sc2", "What the ledger says", ["wren", "ilias"])})
      ),
      v(
        :reading_signed_out,
        "Reading never hits a wall; only the actions do. A signed-out visitor gets the whole story, and the line under the pager is where keeping your place, taking a copy and reading as someone in it are said to need an account — once, plainly, at the point it matters.",
        read(%{current_user: nil})
      ),
      v(
        :nobody_shared,
        "Published with no perspectives granted at all. There is no way into it, and saying so is better than a page that looks broken.",
        front(%{
          pub: pub([], spectator: false),
          mode: nil,
          row: row("s1", "The Salt Line", pub: pub([], spectator: false))
        })
      ),
      v(
        :taken_down,
        "The story is gone — unpublished or taken down. A reader arriving on a link they were sent gets an answer rather than a 404.",
        front(%{gone: true})
      ),
      v(
        :reporting,
        "The report form. This screen is where you encounter something another person wrote, which is the whole test for where reporting has to be reachable — and the report targets the frozen snapshot, so a take-down never touches the author's private original.",
        front(%{reporting: %{id: "s1", kind: "campaign"}})
      )
    ]
  end
end

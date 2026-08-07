defmodule Storybook.Screens.Browse do
  use PhoenixStorybook.Story, :component

  alias Polyphony.Core.Publication

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
        :not_shared,
        "A scene no granted perspective can reach. It stays in the contents, **marked** — silently omitting it would make the story look shorter than it is, and the gap is a fact about the publication rather than an error.",
        front(%{
          mode: :limited,
          scene: scene("sc2", "What the ledger says"),
          gap: :not_shared,
          events: []
        })
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

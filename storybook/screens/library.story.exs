defmodule Storybook.Screens.Library do
  use PhoenixStorybook.Story, :component

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Screens.Library.screen/1

  defp campaign(id, name, opts \\ []) do
    %{
      id: id,
      name: name,
      named?: opts[:named?] != false,
      status: opts[:status] || :playing,
      status_label: opts[:status_label] || "Playing",
      published?: opts[:published?] || false,
      world: opts[:world] || "Saltmarch",
      people: opts[:people] || 4,
      scenes: opts[:scenes] || 6,
      premise: opts[:premise] || "A customs house that signs for things nobody sees.",
      pending: opts[:pending] || 0,
      copies: opts[:copies] || []
    }
  end

  defp world(id, name, opts \\ []),
    do: %{
      id: id,
      name: name,
      named?: opts[:named?] != false,
      blurb: Keyword.get(opts, :blurb, "A drowned county that still collects its tolls."),
      visibility: opts[:visibility] || "private",
      started: opts[:started] || 0
    }

  # `%{campaign, campaign_id, people}` — people are grouped by the campaign that cast
  # them, and the walk-on split happens inside the screen via `split_walk_ons/1`.
  defp person(id, name, tier, role \\ nil),
    do: %{
      id: id,
      name: name,
      role: role,
      tier: tier,
      tier_label: tier |> to_string() |> String.capitalize(),
      colour: "hsl(210 40% 55%)"
    }

  defp cast_of(campaign, id, people),
    do: %{campaign: campaign, campaign_id: id, people: people}

  # A group belongs to a campaign the way a character does, so the screen takes them
  # banded by campaign — the shape `LibraryLive.group_rows/2` builds.
  defp band_of(campaign, groups), do: %{campaign: campaign, groups: groups}

  defp group(id, name, members, secrets, colour \\ "var(--v1)"),
    do: %{id: id, name: name, members: members, secrets: secrets, colour: colour}

  defp base do
    %{
      current_user: %{id: "u1", username: "wren", role: "user"},
      entries: [:one],
      tab: "campaigns",
      campaigns: [
        campaign("c1", "The Salt Line"),
        campaign("c2", "Nightjar", status: :finished, status_label: "Finished", pending: 3)
      ],
      worlds: [world("w1", "Saltmarch", started: 2)],
      people: [
        cast_of("The Salt Line", "c1", [
          person("p1", "Wren Ashgrove", :main, "Keeps the tide ledger."),
          person("p2", "Ilias", :recurring, "Signs for what she logs."),
          person("p3", "The harbourmaster", :incidental)
        ])
      ],
      groups: [band_of("The Salt Line", [group("g1", "The Tidewatch", 6, 2)])],
      reading: [],
      archived: [],
      trashed: []
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
        :campaigns,
        "The shelf. A campaign row carries enough to pick up where you left off — where it is in its life, its world and size, and what's waiting for review. That last number is the same one the scene gate will stop you with, so the row doesn't surprise anyone.",
        %{}
      ),
      v(
        :first_run,
        "Nothing written yet. One button and **no** explanation of worlds and characters, because you don't need to know the entity model to start — the campaign flow walks you through it.",
        %{
          entries: [],
          campaigns: [],
          worlds: [],
          people: [],
          groups: [],
          reading: []
        }
      ),
      v(
        :people,
        "The People tab, and the screen's one real idea: the characters you sat down and wrote are held apart from the walk-ons a story invented. A cast list that mixes them reads as clutter, and deleting clutter is how somebody loses a character they meant to keep.",
        %{tab: "people"}
      ),
      v(
        :no_walk_ons,
        "The same tab before any story has invented anybody. The walk-on section collapses rather than showing an empty heading — a heading for a thing you have none of is a question you didn't ask.",
        %{
          tab: "people",
          people: [cast_of("The Salt Line", "c1", [person("p1", "Wren Ashgrove", :main)])]
        }
      ),
      v(
        :worlds,
        "The worlds you've written. Each row carries whether it is private or public, its cover line, and how many campaigns were started from it — starts, not shares, because attaching a world copies it. A world with nothing past its name still gets a row, marked never used.",
        %{
          tab: "worlds",
          worlds: [
            world("w1", "Saltmarch",
              blurb: "A port town that runs on tides and debts.",
              started: 2
            ),
            world("w2", "The Ninth Gate",
              blurb: "Sunless city, nine districts, one way out.",
              visibility: "public",
              started: 1
            ),
            world("w3", "Untitled world", named?: false, blurb: nil)
          ]
        }
      ),
      v(
        :worlds_empty,
        "No worlds yet, with campaigns already on the shelf — a campaign exists before its world is written, so this is not a first-run state. No create button: worlds are written inside a campaign, and the copy says what a world *is* rather than that the tab is empty.",
        %{tab: "worlds", worlds: []}
      ),
      v(
        :groups,
        "The groups you've written, banded by the campaign each belongs to — the band is what tells two crews of the same name apart. A row carries members and secrets, and the secrets are the number that distinguishes them: a group whose facts are all public is a tag rather than a membership.",
        %{
          tab: "groups",
          groups: [
            band_of("The Salt Line", [
              group("g1", "The Tidewatch", 6, 2, "var(--secret)"),
              group("g2", "The harbour office", 3, 0)
            ])
          ]
        }
      ),
      v(
        :groups_empty,
        "No groups yet — the most common state on this tab, and not a to-do: Quick Build's group switch is off by default, so this is what a perfectly healthy library looks like for a long time. The copy makes the case for groups rather than reporting a gap.",
        %{tab: "groups", groups: []}
      ),
      v(
        :searching,
        "Filtering people by name and tier. Search arrives when a library gets long — the design's rule is render everything until structure stops doing the work.",
        %{tab: "people", query: "wren", tier: "main"}
      ),
      v(
        :reading,
        "Somebody else's published campaign, on your shelf. It carries the author and which perspective you were reading in, because a published story is read *as* somebody and picking that back up is the whole point of a bookmark.",
        %{
          tab: "reading",
          reading: [
            %{
              id: "r1",
              name: "The Weight of Water",
              source: %{id: "s1"},
              bookmark: %{scene_id: "sc1", perspective: "wren", finished_at: nil},
              author: "@ilias",
              perspective: "as Wren Ashgrove",
              place: "Scene 4 of 9.",
              state: :reading,
              started: true
            }
          ]
        }
      ),
      v(
        :archive,
        "Filing and the trash, on one tab. Archive is recoverable with one button and no confirmation, because nothing was ever at risk; deleted things wait out a retention window before they are really gone, which is why the two are shown apart.",
        %{
          tab: "shelves",
          archived: [
            %{
              id: "a1",
              kind: "character",
              colour: "var(--b3)",
              name: "An early draft",
              line: "Character · archived in March"
            }
          ],
          trashed: [
            %{
              id: "t1",
              kind: "campaign",
              colour: "var(--b3)",
              name: "A false start",
              line: "Gone for good in 27 days."
            }
          ]
        }
      ),
      v(
        :row_menu_open,
        "A row's overflow menu. Every destructive thing lives in here rather than on the row, so the shelf reads as a list of work instead of a list of ways to lose it.",
        %{menu_for: "c1"}
      )
    ]
  end
end

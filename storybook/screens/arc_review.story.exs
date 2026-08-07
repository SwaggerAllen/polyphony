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
      subject_id: opts[:subject_id]
    }
  end

  defp cast, do: [%{id: "wren", name: "Wren Ashgrove"}, %{id: "ilias", name: "Ilias"}]

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
          )
        ],
        "ilias" => []
      },
      world: [],
      groups: []
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
      )
    ]
  end
end

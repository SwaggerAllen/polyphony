defmodule Storybook.Kit.Audience do
  use PhoenixStorybook.Story, :component

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.AudiencePicker.picker/1

  def template do
    """
    <div class="fr stage dark">
      <.psb-variation/>
    </div>
    """
  end

  defp people do
    [
      {"c1", "Wren Ashgrove", :main, "var(--v1)"},
      {"c2", "Ilias Vane", :main, "var(--v2)"},
      {"c3", "Mother Corrigan", :main, "var(--v3)"},
      {"c4", "Sable Quist", :recurring, "var(--v4)"},
      {"c5", "Aldous Ashgrove", :recurring, "var(--v5)"},
      {"c6", "The bellman", :incidental, "var(--v6)"}
    ]
  end

  def variations do
    [
      %Variation{
        id: :nobody,
        description:
          "The default, and usually the right answer. Most secrets stay empty, so the control costs nothing on the common fact.",
        attributes: %{
          statement: "The tide bell answers to something under the flats, and it is owed.",
          context_label: "Saltmarch",
          audience: %Polyphony.Authoring.Audience{},
          groups: [
            {"g1", "The Tidewatch", {:count, 2}},
            {"g2", "The harbour office", {:count, 3}}
          ],
          people: people(),
          resolved: []
        }
      },
      %Variation{
        id: :via_a_group,
        description:
          "A group is ticked, and the two people in it carry outlined ticks — inherited, and not individually removable. Take the group off instead. That's the price of no exceptions, and it's cheap.",
        attributes: %{
          statement: "The tide bell answers to something under the flats, and it is owed.",
          context_label: "Saltmarch",
          audience: %Polyphony.Authoring.Audience{group_ids: ["g1"], character_ids: ["c3"]},
          groups: [
            {"g1", "The Tidewatch", {:count, 2}},
            {"g2", "The harbour office", {:count, 3}}
          ],
          people: people(),
          resolved: ["c3", "c4", "c6"]
        }
      },
      %Variation{
        id: :the_owner,
        description:
          "A character always knows their own secrets. Locked on, labelled, never a decision — so it sits at the top rather than inviting someone to look for the tick.",
        attributes: %{
          statement: "She's been signing for the Kestrel's cargo since March.",
          context_label: "Wren Ashgrove",
          audience: %Polyphony.Authoring.Audience{character_ids: ["c4"]},
          groups: [],
          people: Enum.reject(people(), &(elem(&1, 0) == "c1")),
          owner: "c1",
          owner_label: "Wren Ashgrove",
          resolved: ["c1", "c4"]
        }
      },
      %Variation{
        id: :empty_group,
        description:
          "Not an error. Empty groups are how you set a trap before anyone walks into it — anyone written from the Tidewatch will know this from the moment they turn up.",
        attributes: %{
          statement: "The tide bell answers to something under the flats.",
          context_label: "Saltmarch",
          audience: %Polyphony.Authoring.Audience{group_ids: ["g1"]},
          groups: [{"g1", "The Tidewatch", {:empty, 0}}],
          people: people(),
          resolved: []
        }
      },
      %Variation{
        id: :no_cast,
        description:
          "Nobody has been written yet, so there's nobody to let in on it. The secret keeps.",
        attributes: %{
          statement: "The tide bell answers to something under the flats.",
          audience: %Polyphony.Authoring.Audience{},
          groups: [],
          people: [],
          resolved: []
        }
      }
    ]
  end
end

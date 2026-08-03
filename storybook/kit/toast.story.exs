defmodule Storybook.Kit.Toast do
  use PhoenixStorybook.Story, :component

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.toast/1

  def template do
    """
    <div class="fr stage dark p-3"><.psb-variation/></div>
    """
  end

  def variations do
    [
      %Variation{
        id: :done,
        description:
          "Name the action that produced it — \"Published\", not \"Success\". Three dots, the same three semantics as everywhere else: ok is done, lamp is now, pencil is a correction.",
        attributes: %{kind: :ok},
        slots: ["Published"]
      },
      %Variation{id: :working, attributes: %{kind: :working}, slots: ["Saving…"]},
      %Variation{
        id: :wrong,
        attributes: %{kind: :error},
        slots: ["Couldn't save — try again"]
      },
      %Variation{
        id: :reversible,
        description: "Anything reversible carries its undo, in the editorial colour.",
        attributes: %{kind: :ok},
        slots: [
          "Moved to walk-ons",
          ~s|<:action><button class="btn btn-pen btn-sm">Undo</button></:action>|
        ]
      }
    ]
  end
end

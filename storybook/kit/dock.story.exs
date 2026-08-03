defmodule Storybook.Kit.Dock do
  use PhoenixStorybook.Story, :component

  # A dock pins itself to the *viewport*, so inside a story container it would escape
  # the frame and sit in the corner of the storybook itself. `position:relative` on the
  # container scopes the fixed positioning to the variation, which is the only way to
  # review it next to anything else.
  def container, do: {:div, style: "width:100%; height:340px; position:relative"}

  def function, do: &PolyphonyWeb.Kit.sheet/1

  def template do
    """
    <div class="fr stage dark" style="height:100%; position:relative">
      <div class="dock" style="position:absolute">
        <.psb-variation/>
      </div>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :panel,
        description:
          "The debug drawer is the only dock today. Only the pinning is a kit primitive — " <>
            "everything inside is ordinary kit (a .sheet, a .row for the head, .pill and " <>
            ".dot for status, .scroller for the list), which is why a floating panel needs " <>
            "three rules rather than a stylesheet of its own.",
        attributes: %{class: "dock-panel flex flex-col"},
        slots: [
          """
          <div class="row px-3 py-2 flex items-center flex-wrap gap-1.5" style="background:var(--b2)">
            <span class="mono text-[12px] font-semibold">Session log</span>
            <span class="pill dim">3</span>
            <span class="pill" style="color:var(--ok);border-color:var(--ok)">connected</span>
            <span class="flex-1"></span>
            <button class="btn btn-sm btn-gh">Copy</button>
            <button class="btn btn-sm btn-gh">✕</button>
          </div>
          <div class="scroller px-3 py-1.5">
            <div class="row flex gap-2 py-1 text-[11.5px] leading-[1.5]">
              <span class="mono dim shrink-0">18:49:00</span>
              <span class="lbl shrink-0 pt-[.15rem]" style="color:var(--bcm)">info</span>
              <span class="mono flex-1 whitespace-pre-wrap" style="overflow-wrap:anywhere;color:var(--secret)">[mail] magic_link &rarr; a***@example.com sent via Polyphony.Notifications.Transport.Email</span>
            </div>
            <div class="row flex gap-2 py-1 text-[11.5px] leading-[1.5]">
              <span class="mono dim shrink-0">18:49:02</span>
              <span class="lbl shrink-0 pt-[.15rem]" style="color:var(--pencil)">error</span>
              <span class="mono flex-1 whitespace-pre-wrap" style="overflow-wrap:anywhere;color:var(--pencil)">[mail] magic_link &rarr; a***@example.com FAILED: &#123;:error, :no_from_address&#125;</span>
            </div>
            <div class="row flex gap-2 py-1 text-[11.5px] leading-[1.5]">
              <span class="mono dim shrink-0">18:49:03</span>
              <span class="lbl shrink-0 pt-[.15rem]" style="color:var(--bcm)">info</span>
              <span class="mono flex-1 whitespace-pre-wrap" style="overflow-wrap:anywhere">GET /login sent 200 in 4ms</span>
            </div>
          </div>
          """
        ]
      }
    ]
  end
end

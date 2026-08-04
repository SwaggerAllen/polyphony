defmodule Storybook.Kit.Overlay do
  use PhoenixStorybook.Story, :component

  # An overlay pins itself to the *viewport*, so inside an ordinary story container it
  # would cover the storybook rather than the variation. A `transform` on an ancestor
  # is the one thing that makes `position:fixed` resolve against that ancestor instead,
  # which is what scopes it to the frame here — `position:relative` alone would not.
  def container, do: {:div, style: "width:100%; height:420px"}

  def function, do: &PolyphonyWeb.Kit.overlay/1

  def template do
    """
    <div class="fr stage dark" style="height:100%; transform:translateZ(0); overflow:hidden">
      <div class="p-4">
        <div class="ttl text-[15px] font-semibold mb-1">The page, still there</div>
        <p class="text-[13px] dim leading-relaxed">
          Dimmed rather than replaced, because the decision is about something on it.
        </p>
      </div>
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :panel,
        description:
          "Bottom-anchored on a phone and centred once there's room. Three ways out — " <>
            "the scrim, Escape, and the control in the head — because a modal with one " <>
            "is a trap. The head and the foot stay put; only `.modal-body` scrolls, so " <>
            "the way out is never the thing you have to scroll to find.",
        attributes: %{label: "Who starts out knowing", on_close: "close"},
        slots: [
          """
          <div class="row px-4 py-3 shrink-0" style="background:var(--b2)">
            <div class="flex items-center justify-between gap-2 mb-1.5">
              <span class="ttl text-[15px] font-semibold">Who starts out knowing</span>
              <button class="btn btn-sm btn-gh shrink-0">Done</button>
            </div>
            <p class="text-[13px] leading-relaxed">The ledger is under the bell.</p>
          </div>
          <div class="modal-body">
            <div class="row px-4 py-2" style="background:var(--b2)">
              <span class="lbl dim">Groups</span>
            </div>
            <div class="row px-4 py-2.5 flex items-center gap-2.5">
              <span class="chk chk-on">✓</span>
              <span class="flex-1 min-w-0">
                <span class="block text-[13px] font-semibold">The Tidewatch</span>
                <span class="block text-[11px] dim">4 people, and anyone new who joins</span>
              </span>
            </div>
            <div class="row px-4 py-2" style="background:var(--b2)">
              <span class="lbl dim">Leads</span>
            </div>
            <div class="row px-4 py-2.5 flex items-center gap-2.5">
              <span class="chk chk-via">✓</span>
              <span class="av" style="background:var(--secret)"></span>
              <span class="text-[13px] flex-1 min-w-0 truncate">Wren</span>
              <span class="text-[11px] dim shrink-0">via a group</span>
            </div>
            <div class="row px-4 py-2.5 flex items-center gap-2.5">
              <span class="chk"></span>
              <span class="av" style="background:var(--bcm)"></span>
              <span class="text-[13px] flex-1 min-w-0 truncate">Bram</span>
            </div>
          </div>
          <div class="px-4 py-3 shrink-0" style="background:var(--b2)">
            <div class="flex items-start gap-2">
              <span class="dot mt-1.5 shrink-0" style="background:var(--secret)"></span>
              <p class="text-[12.5px] leading-relaxed">Right now that's 4 people.</p>
            </div>
          </div>
          """
        ]
      }
    ]
  end
end

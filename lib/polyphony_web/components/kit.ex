defmodule PolyphonyWeb.Kit do
  @moduledoc """
  The design kit as function components.

  `ux/polyphony-kit.css` is the single source of truth for tokens and component
  classes; `mix kit.port` lifts it into `assets/css/kit.css` unchanged. This
  module is the other half of that port — the kit's *markup*, lifted from
  `ux/polyphony-kit.html` and the screen mocks, so a screen builds by calling
  components rather than by re-deriving class strings. The rule from CLAUDE.md
  applies here hardest: **define nothing screen-local that the kit already
  provides**, and if a screen needs a new class it belongs in `ux/` first.

  ## What's a component and what isn't

  The kit's structural idioms are components. Its one-class utilities (`.ttl`,
  `.mono`, `.dim`, `.lbl`) are not — they're written straight into markup exactly
  as the mocks do, because wrapping a font-family in a function buys nothing and
  makes the port harder to read against the design.

  The components here are the ones `ux/README.md` names as worth building once
  (perspective control, status strip, transcript moves, marked list items, the
  info affordance, the nav primitives), plus the controls they sit in.

  ## Frames and registers

  Everything must live inside a `frame/1` — the kit's rules are scoped to the
  `.fr` root, and the register (`:stage` working, `:page` reading) and theme pick
  which token set applies. The register is a property of the surface, not of the
  user: authoring and omniscient play are `:stage`, a character in their own head
  and published reading are `:page`.

  ## Colour

  Four semantics carry meaning and are never re-coloured: **lamp = now**,
  **pencil = correction** (never a primary action), **ok = done**, **secret =
  concealed**. Voice colours come from `PolyphonyWeb.Voice`, assigned by cast
  order, and must be stable for a character across every surface.
  """
  use Phoenix.Component

  alias PolyphonyWeb.Voice

  # ── Frame ──────────────────────────────────────────────────────────────────

  @doc """
  The register root every kit component must be rendered inside.

  `<div class="fr stage dark">` in the mocks. The register is the outer design
  decision (`ux/README.md`): `:stage` for working surfaces — omniscient play and
  all authoring — and `:page` for reading ones, a player in their own character's
  head and published campaigns.
  """
  attr(:register, :atom, default: :stage, values: [:stage, :page])
  attr(:theme, :atom, default: :dark, values: [:dark, :light])
  attr(:class, :string, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def frame(assigns) do
    ~H"""
    <div class={["fr", to_string(@register), to_string(@theme), @class]} {@rest}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  @doc """
  The standard screen header.

  The kit draws this once and says how it reads: *campaign name small, scene
  location as the title, perspective control top right, overflow last*. Every
  screen with a title uses this markup — play, the published reading screen, the
  library, the campaign editor, admin — which is what makes moving between them
  feel like one product rather than several.

  There is deliberately **no persistent global navigation** in this design. A
  screen fills the viewport and carries its own header; going elsewhere is the
  `back` chevron for a drill-down, or the overflow `menu/1` on the right. A
  standing nav bar would cost a row of vertical space on every screen, on a
  product whose main surface is a transcript.
  """
  attr(:title, :string, required: true)
  attr(:eyebrow, :string, default: nil, doc: "the context above the title — a campaign name")
  attr(:subtitle, :string, default: nil, doc: "the meta line under the title — counts, status")
  attr(:back, :string, default: nil, doc: "where the ‹ chevron goes; omitted without one")
  attr(:back_label, :string, default: "Back")

  attr(:back_confirm, :string,
    default: nil,
    doc: "what to ask before leaving — nil on a screen with nothing to lose"
  )

  attr(:class, :string, default: nil)
  slot(:actions, doc: "controls on the right — perspective control first, overflow last")

  def header(assigns) do
    ~H"""
    <div
      class={["row shrink-0 flex items-center justify-between gap-2 px-4 py-3", @class]}
      style="background:var(--b2)"
    >
      <div class="flex items-center gap-2 min-w-0">
        <%!-- The chevron is the way out of a drill-down, so on an editing screen it is
              also the way out of unsaved work. `back_confirm` is nil unless there is
              something to lose, so a clean screen never prompts. --%>
        <.link
          :if={@back}
          navigate={@back}
          class="dim text-[15px] leading-none"
          aria-label={@back_label}
          data-confirm={@back_confirm}
        >
          ‹
        </.link>
        <div class="min-w-0">
          <div :if={@eyebrow} class="lbl dim"><%= @eyebrow %></div>
          <div class={["ttl truncate font-semibold", if(@eyebrow, do: "text-[15px] mt-0.5", else: "text-[17px]")]}>
            <%= @title %>
          </div>
          <div :if={@subtitle} class="lbl dim mt-0.5"><%= @subtitle %></div>
        </div>
      </div>
      <div :if={@actions != []} class="flex items-center gap-1.5 shrink-0">
        <%= render_slot(@actions) %>
      </div>
    </div>
    """
  end

  @doc """
  The nav menu — the `☰` at the end of a header.

  Where everything that isn't this screen lives, since the design has no standing
  navigation. Built on `<details>` so it opens without JavaScript and closes with
  Escape for free; a menu that needs a live connection to open would be the wrong
  thing to put a sign-out link in.

  **A hamburger, not a `⋯`.** They mean different things and this is the one that
  means "the app": `⋯` is the overflow of the thing it sits beside — the row's menu,
  this item's menu — and used for global navigation it reads as being about whatever
  control it happens to be next to. In a header that already carries a viewer picker
  and a status pill, that is most of the time. The extra left margin is the same
  point made in space: the gap says this one isn't part of that group.

  The kit draws the closed affordance (a `.pill`) but not the open state, so the
  panel below is the kit's own sheet-and-rows applied to it rather than a new idea.
  """
  attr(:label, :string, default: "Menu")
  attr(:class, :string, default: nil)

  slot :item, doc: "one destination" do
    attr(:navigate, :string)
    attr(:href, :string)
    attr(:method, :string)
  end

  def menu(assigns) do
    ~H"""
    <details class={["relative ml-2", @class]}>
      <summary class="pill list-none cursor-pointer" aria-label={@label}>☰</summary>
      <nav
        class="sheet absolute right-0 top-full mt-1 z-20 min-w-[11rem] overflow-hidden"
        style="background:var(--b2)"
      >
        <.link
          :for={i <- @item}
          navigate={i[:navigate]}
          href={i[:href]}
          method={i[:method]}
          class="row block px-4 py-2.5 text-[13px]"
        >
          <%= render_slot(i) %>
        </.link>
      </nav>
    </details>
    """
  end

  @doc """
  A toast: something just happened, named by the action that produced it.

  The kit's rule is that a toast names the action ("Published", "Moved to
  walk-ons") rather than announcing success in the abstract, and that anything
  reversible carries its undo. `kind` picks the dot: `:ok` done, `:working` now,
  `:error` a correction — the same three semantics the rest of the kit uses.
  """
  attr(:kind, :atom, default: :ok, values: [:ok, :working, :error])
  attr(:class, :string, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)
  slot(:action, doc: "an undo, or whatever reverses it")

  def toast(assigns) do
    ~H"""
    <div class={["sheet p-3 flex items-center justify-between gap-2", @class]} role="status" {@rest}>
      <span class="flex items-center gap-2 min-w-0">
        <span class="dot" style={"background:#{toast_colour(@kind)}"}></span>
        <span class="text-[13px]"><%= render_slot(@inner_block) %></span>
      </span>
      <%= render_slot(@action) %>
    </div>
    """
  end

  defp toast_colour(:working), do: "var(--lamp)"
  defp toast_colour(:error), do: "var(--pencil)"
  defp toast_colour(:ok), do: "var(--ok)"

  # ── The perspective control ────────────────────────────────────────────────

  @doc """
  The perspective control — the product's spine.

  Identical markup and identical position (top right of the header) on every
  surface with a viewpoint: play as a character, play as omniscient, reading a
  published campaign, its contents list, and preview on the world bible and
  character sheet. `ux/README.md` calls its drift into three treatments the worst
  consistency failure of the design pass, so it exists here and nowhere else.

  `colour` is the viewpoint's hue: a character's voice colour, `var(--bc)` for
  omniscient, `var(--lamp)` for limited omniscient, `var(--bcm)` for a spectator.
  Pass `:rest` to make it live (`phx-click`, `href` via `tag`).
  """
  attr(:label, :string, required: true)
  attr(:colour, :string, default: "var(--bc)")
  attr(:caret, :boolean, default: true, doc: "show ▾ — off when it isn't switchable")
  attr(:tag, :string, default: "span", doc: "span, button or a — a control when it acts")
  attr(:class, :string, default: nil)
  attr(:rest, :global)

  def viewas(assigns) do
    ~H"""
    <.dynamic_tag tag_name={@tag} class={["viewas", @class]} style={Voice.var("--vc", @colour)} {@rest}>
      <i></i><%= @label %><%= if @caret, do: " ▾" %>
    </.dynamic_tag>
    """
  end

  @doc """
  The perspective control as a **switchable menu** — the same pill, wrapped round a
  `<select>`.

  Three screens had grown their own `<select class="viewas appearance-none">`, which
  is the drift `ux/README.md` names as the design pass's worst consistency failure,
  and it cost them the chevron: `appearance:none` strips the platform's own, and a
  bare select can't carry the `▾` that `viewas/1` draws as text. So the mark lives
  out here beside the control, and the select inside it is stripped to nothing.

  The `<form>` and its `phx-change` stay at the call site — each screen names a
  different event — and options are the inner block, because one of them groups.
  """
  attr(:id, :string, required: true)
  attr(:label, :string, required: true, doc: "the screen-reader label — Viewing as, Reading as")
  attr(:colour, :string, default: "var(--bc)")
  attr(:class, :string, default: nil)
  attr(:rest, :global, include: ~w(name form))
  slot(:inner_block, required: true, doc: "the <option>s")

  def viewas_select(assigns) do
    ~H"""
    <span class={["viewas", @class]} style={Voice.var("--vc", @colour)}>
      <i></i>
      <label for={@id} class="sr-only"><%= @label %></label>
      <select id={@id} class="viewas-select" {@rest}><%= render_slot(@inner_block) %></select>
      <span aria-hidden="true">▾</span>
    </span>
    """
  end

  # ── Controls ───────────────────────────────────────────────────────────────

  @doc """
  A button.

  `kind` maps to the kit's five treatments. `:pen` is the editorial layer —
  reroll, edit, delete, branch — and per the kit it is *never* a primary action;
  `:red` is destruction; `:off` reads as unavailable.
  """
  attr(:kind, :atom, default: :ghost, values: [:primary, :ghost, :pen, :red, :off])
  attr(:size, :atom, default: :md, values: [:md, :sm])
  attr(:class, :string, default: nil)
  attr(:rest, :global, include: ~w(disabled form name value type phx-click phx-value-id href))
  slot(:inner_block, required: true)

  def btn(assigns) do
    ~H"""
    <button class={["btn", btn_kind(@kind), @size == :sm && "btn-sm", @class]} {@rest}>
      <%= render_slot(@inner_block) %>
    </button>
    """
  end

  defp btn_kind(:primary), do: "btn-pri"
  defp btn_kind(:ghost), do: "btn-gh"
  defp btn_kind(:pen), do: "btn-pen"
  defp btn_kind(:red), do: "btn-red"
  defp btn_kind(:off), do: "btn-off"

  @doc """
  A status pill.

  Status, never an action — the kit's rule is that if it does something on tap
  it's a button. `colour` tints border and text together.
  """
  attr(:colour, :string, default: nil, doc: "nil for neutral; else a token like var(--ok)")
  attr(:class, :string, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def pill(assigns) do
    ~H"""
    <span
      class={["pill", is_nil(@colour) && "dim", @class]}
      style={@colour && "border-color:#{@colour};color:#{@colour}"}
      {@rest}
    >
      <%= render_slot(@inner_block) %>
    </span>
    """
  end

  @doc """
  A small coloured dot. Carries a semantic colour, never decoration.

  `live` makes it breathe — for something happening *right now*, not merely
  coloured as now. The kit reserves motion for that the way it reserves lamp for
  it: one moving thing on screen, so it means one thing.
  """
  attr(:colour, :string, required: true)
  attr(:live, :boolean, default: false)
  attr(:class, :string, default: nil)

  def dot(assigns) do
    ~H"""
    <span class={["dot", @live && "dot-live", @class]} style={"background:#{@colour}"}></span>
    """
  end

  @doc """
  The one boolean pattern.

  Same geometry everywhere, coloured by what it means — `var(--lamp)` for "always
  in mind", `var(--secret)` for secret. Label on the left, control right-aligned;
  that layout is the caller's, this is just the control.
  """
  attr(:on, :boolean, default: false)
  attr(:colour, :string, default: "var(--lamp)")
  attr(:class, :string, default: nil)
  attr(:rest, :global)

  def sw(assigns) do
    ~H"""
    <span class={["sw", @on && "sw-on", @class]} style={Voice.var("--sc", @colour)} {@rest}>
      <i></i>
    </span>
    """
  end

  @doc """
  A checkbox tick.

  `:via` is the kit's outlined tick: inherited from a group and therefore *not*
  individually removable — take the group off instead.
  """
  attr(:state, :atom, default: :off, values: [:off, :on, :via])
  attr(:class, :string, default: nil)
  attr(:rest, :global)

  def chk(assigns) do
    ~H"""
    <span class={["chk", chk_state(@state), @class]} {@rest}>
      <%= if @state != :off, do: "✓" %>
    </span>
    """
  end

  defp chk_state(:on), do: "chk-on"
  defp chk_state(:via), do: "chk-via"
  defp chk_state(:off), do: nil

  @doc "A segmented control. One option carries `on: true`."
  attr(:class, :string, default: nil)

  slot :option, required: true do
    attr(:on, :boolean)
    attr(:rest, :any)
  end

  def seg(assigns) do
    ~H"""
    <div class={["seg", @class]}>
      <div :for={o <- @option} class={if o[:on], do: "seg-on", else: "dim"} {Map.get(o, :rest, %{})}>
        <%= render_slot(o) %>
      </div>
    </div>
    """
  end

  @doc "A progress bar. `fraction` is 0.0–1.0; anything outside is clamped."
  attr(:fraction, :float, required: true)

  attr(:colour, :string,
    default: nil,
    doc: "nil for the kit's lamp; a token when it means something else"
  )

  attr(:class, :string, default: nil)

  def bar(assigns) do
    assigns = assign(assigns, :pct, assigns.fraction |> max(0.0) |> min(1.0) |> Kernel.*(100))

    ~H"""
    <div class={["bar", @class]}>
      <i style={bar_style(@pct, @colour)}></i>
    </div>
    """
  end

  defp bar_style(pct, nil), do: "width:#{:erlang.float_to_binary(pct, decimals: 1)}%"

  defp bar_style(pct, colour),
    do: bar_style(pct, nil) <> ";background:#{colour}"

  @doc """
  The info affordance.

  Sits beside a section header, never inside a menu — one drawer per section,
  covering the concepts in it, not one popover per setting. The kit's test for
  whether a label needs one: does it mean something different here than a
  first-time reader would assume?
  """
  attr(:label, :string, required: true, doc: "accessible name — what the drawer explains")
  attr(:rest, :global)

  def info(assigns) do
    ~H"""
    <button type="button" class="info" aria-label={"About #{@label}"} {@rest}>i</button>
    """
  end

  # ── Surfaces ───────────────────────────────────────────────────────────────

  @doc "A bordered card. The kit's one container."
  attr(:class, :string, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def sheet(assigns) do
    ~H"""
    <div class={["sheet", @class]} {@rest}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  @doc "A ruled row inside a sheet."
  attr(:class, :string, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def row(assigns) do
    ~H"""
    <div class={["row", @class]} {@rest}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  @doc """
  A panel over the page — the kit's modal surface (§11).

  The sibling of `.dock`, and deliberately its opposite: a dock is *pinned and
  ignorable*, something you keep working alongside; this is the decision you take
  about one item, and while it is open it is the only thing you can act on.

  Reach for it whenever a panel is opened *from* a control rather than being part
  of the page. Rendered inline instead, a panel lands wherever it happens to sit in
  the document — on a long authoring screen that is far below the button that
  opened it, so it reads as nothing having happened, its close control is
  off-screen, and the page's own buttons still look live while the panel is what
  you are actually editing.

  Three ways out, because a modal with one is a trap: the scrim, `Escape`, and
  whatever the caller puts in the panel's own header. All three push `on_close` to
  the host LiveView.

  The body scrolls, the head and foot don't — put the head and any foot outside a
  `.modal-body` so the way out is never the thing you have to scroll to find.
  """
  attr(:label, :string, required: true, doc: "accessible name for the dialog")
  attr(:on_close, :string, required: true, doc: "event pushed by the scrim and by Escape")
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  def overlay(assigns) do
    ~H"""
    <div class="scrim" aria-hidden="true" phx-click={@on_close}></div>
    <div
      class="overlay"
      role="dialog"
      aria-modal="true"
      aria-label={@label}
      phx-window-keyup={@on_close}
      phx-key="Escape"
    >
      <.sheet class={Enum.join(Enum.reject(["modal", @class], &is_nil/1), " ")}>
        <%= render_slot(@inner_block) %>
      </.sheet>
    </div>
    """
  end

  # ── Navigation ─────────────────────────────────────────────────────────────

  @doc """
  Tabs for a sectioned screen (campaign, library, browse, admin).

  `todo: true` puts the kit's amber dot on a tab — it means *unbuilt*, and is only
  used on a campaign's first run.
  """
  attr(:class, :string, default: nil)

  slot :tab, required: true do
    attr(:on, :boolean)
    attr(:todo, :boolean)
    attr(:patch, :string)
    attr(:navigate, :string)
  end

  def tabs(assigns) do
    ~H"""
    <div class={["tabs", @class]} role="tablist">
      <.link
        :for={t <- @tab}
        patch={t[:patch]}
        navigate={t[:navigate]}
        role="tab"
        aria-selected={to_string(!!t[:on])}
        class={["tab", t[:on] && "tab-on", t[:todo] && "tab-todo"]}
      >
        <%= render_slot(t) %>
      </.link>
    </div>
    """
  end

  @doc """
  A jump bar for a long form (character sheet, world bible).

  Sits outside the vertical scroller so it stays put and can't blow out the
  width. `scrub: true` switches to the scene scrubber's spacing — same primitive,
  one stop per closed scene, because arc is extracted at scene close and that's
  the only meaningful resolution.
  """
  attr(:scrub, :boolean, default: false)
  attr(:class, :string, default: nil)

  slot :stop, required: true do
    attr(:on, :boolean)
    attr(:href, :string)
    attr(:rest, :any)
  end

  def jump(assigns) do
    ~H"""
    <nav class={[if(@scrub, do: "scrub", else: "jump"), @class]}>
      <span :for={s <- @stop} class={s[:on] && "on"} {Map.get(s, :rest, %{})}>
        <%= render_slot(s) %>
      </span>
    </nav>
    """
  end

  # ── Transcript ─────────────────────────────────────────────────────────────

  @doc """
  A beat divider.

  Sticky within the transcript and plain by design — it records that a beat
  opened and never changes afterwards, so it carries no state and no navigation.
  """
  attr(:beat, :integer, required: true)
  attr(:class, :string, default: nil)

  def beat_rule(assigns) do
    ~H"""
    <div class={["beat-rule", @class]}>
      <span class="ttl text-[14px] font-semibold">Beat <%= @beat %></span>
    </div>
    """
  end

  @doc """
  Director narration — the one place serif does body work.

  Rules above and below and a hanging dash in the working register; in the
  reading register the dash and the attribution drop away and the line simply
  gets bigger.
  """
  attr(:register, :atom, default: :stage, values: [:stage, :page])
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  def world_move(assigns) do
    ~H"""
    <div class={["m-world", @class]}>
      <div :if={@register == :stage} class="flex gap-3">
        <span class="mono text-[13px] dim">—</span>
        <div class="ttl text-[16px] leading-relaxed font-medium"><%= render_slot(@inner_block) %></div>
      </div>
      <div :if={@register == :stage} class="lbl dim mt-1.5 pl-6">The Director</div>
      <div :if={@register == :page} class="ttl text-[18px] leading-[1.55] font-medium">
        <%= render_slot(@inner_block) %>
      </div>
    </div>
    """
  end

  @doc """
  Interior monologue.

  A voice-coloured rule and a faint tint of the same hue. Never italics: the kit
  drops slant as a semantic entirely, because italics measurably impair reading
  for dyslexic readers and read weakly at small sizes anyway.

  `note` is the kit's attribution line — "Thought · only Wren". It says who can
  see this, which is the visibility guarantee made legible.
  """
  attr(:colour, :string, required: true)
  attr(:note, :string, default: nil)
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  def thought(assigns) do
    ~H"""
    <div class={["m-thought", @class]} style={Voice.var("--vc", @colour)}>
      <div class="text-[15px] leading-relaxed"><%= render_slot(@inner_block) %></div>
      <div :if={@note} class="lbl mt-1" style={"color:#{@colour}"}><%= @note %></div>
    </div>
    """
  end

  @doc """
  A generation that failed, rendered where it happened.

  The kit puts failures in the transcript at the beat they occurred rather than
  in a banner, so the gap in the fiction is visible in place. `detail` says what
  happens next — the copy rule is that an error names the consequence, not the
  rule it broke.
  """
  attr(:title, :string, required: true)
  attr(:detail, :string, default: nil)
  attr(:class, :string, default: nil)
  attr(:rest, :global)
  slot(:inner_block)

  def fail_move(assigns) do
    ~H"""
    <div class={["m-fail", @class]} {@rest}>
      <div class="text-[14px] font-semibold mb-1"><%= @title %></div>
      <p :if={@detail} class="text-[13px] leading-relaxed dim"><%= @detail %></p>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  # ── Status strip ───────────────────────────────────────────────────────────

  @doc """
  The status strip: a slot per cast member, then one sentence.

  Above the composer in both registers. No beat number — the transcript rule owns
  that — and no navigation. Slots flex, so names become initials around six.

  The strip is filtered exactly like the transcript: a viewer only gets slots for
  people they know are there, so the caller passes an already-projected cast.
  `tone` colours the sentence — `var(--lamp)` when it's the viewer's turn,
  `var(--pencil)` when something failed, nil for the ordinary dim line.
  """
  attr(:sentence, :string, default: nil)
  attr(:tone, :string, default: nil)
  attr(:class, :string, default: nil)

  slot :slot_item, required: true do
    attr(:label, :string)
    attr(:state, :atom)
    attr(:colour, :string)
    attr(:you, :boolean)
    attr(:patch, :string, doc: "the perspective this person is — makes the slot a link")
  end

  slot(:aside, doc: "trailing control on the sentence line — e.g. jump-to-failure")

  def strip(assigns) do
    ~H"""
    <div class={["strip", @class]}>
      <div class="slots">
        <%!-- A slot is a person, and tapping a person should put you behind their
              eyes — the perspective control is the product's spine, and the strip is
              already showing you who is in the room. `patch` is optional so the strip
              still renders where there is no perspective to switch to. --%>
        <.slot_chip :for={s <- @slot_item} s={s} />
      </div>
      <div :if={@sentence} class="flex items-center justify-between gap-2 mt-1.5">
        <span class={["text-[13px]", is_nil(@tone) && "dim"]} style={@tone && "color:#{@tone}"}>
          <%= @sentence %>
        </span>
        <%= render_slot(@aside) %>
      </div>
    </div>
    """
  end

  # One loop, two tags. Two `:for`s — links then divs — would have reordered the
  # strip the moment one person was reachable and another wasn't, and the strip is
  # turn order.
  #
  # A patch rather than a navigate: a slot is a **perspective**, and switching
  # perspective is the same screen looking at the same scene, which is the one thing
  # a remount would throw away.
  attr(:s, :map, required: true)

  defp slot_chip(assigns) do
    ~H"""
    <.link
      :if={@s[:patch]}
      patch={@s[:patch]}
      class={["slot", slot_state(@s[:state]), @s[:you] && "slot-you"]}
      style={@s[:colour] && Voice.var("--sc", @s[:colour])}
    >
      <%= @s[:label] %>
    </.link>
    <div
      :if={is_nil(@s[:patch])}
      class={["slot", slot_state(@s[:state]), @s[:you] && "slot-you"]}
      style={@s[:colour] && Voice.var("--sc", @s[:colour])}
    >
      <%= @s[:label] %>
    </div>
    """
  end

  defp slot_state(:took), do: "slot-took"
  defp slot_state(:now), do: "slot-now"
  defp slot_state(:pass), do: "slot-pass"
  defp slot_state(:fail), do: "slot-fail"
  defp slot_state(_), do: "slot-wait"

  # ── Marked list items ──────────────────────────────────────────────────────

  @doc """
  A list item carrying a state, as a left rule and a tint.

  Only one thing can own the left border, so secrecy takes it — visibility has
  consequences — and "always in mind" is a chip instead (`chip_core/1`), letting
  the two compose. The variants are the kit's: `:secret` concealed, `:core`
  always in mind, `:prop` proposed, `:canon` accepted, `:drop` dropped,
  `:bound` what they won't do, `:compel` what they can't stop, `:urgent`,
  `:arch` archived, `:was` superseded, `:plain` for an unmarked row.
  """
  attr(:mark, :atom,
    default: :plain,
    values: [:plain, :secret, :core, :prop, :canon, :drop, :bound, :compel, :urgent, :arch, :was]
  )

  attr(:class, :string, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def marked(assigns) do
    ~H"""
    <div class={[@mark != :plain && to_string(@mark), @class]} {@rest}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  @doc ~S"""
  The "always in mind" chip.

  A chip rather than a left rule precisely so it can compose with `marked/1` — a
  fact can be both secret and always in mind.
  """
  attr(:label, :string, default: "Always in mind")

  def chip_core(assigns) do
    ~H"""
    <span class="chip-core">
      <span class="dot" style="background:var(--lamp);width:5px;height:5px"></span><%= @label %>
    </span>
    """
  end

  @doc """
  A line saying something is happening right now.

  Lamp, because the kit reserves that colour for *now* — the live turn, the current
  beat, an unsaved draft. Deliberately a sentence and a dot rather than a spinner:
  the copy can say *what* is being waited on, which a spinner can't.
  """
  attr(:label, :string, required: true)
  attr(:class, :string, default: nil)

  def waiting_line(assigns) do
    ~H"""
    <div class={["flex items-center gap-2 py-1.5", @class]} role="status">
      <.dot colour="var(--lamp)" live />
      <span class="text-[13px]" style="color:var(--lamp)"><%= @label %></span>
    </div>
    """
  end

  @doc """
  A loading placeholder line. `width` is a CSS length.

  It sweeps: the waits here are seconds of a model writing, and a row of static
  grey bars reads as a layout bug rather than as work in progress.
  """
  attr(:width, :string, default: "100%")
  attr(:class, :string, default: nil)

  def skel(assigns) do
    ~H"""
    <div class={["skel", @class]} style={"width:#{@width}"}></div>
    """
  end

  @doc """
  Text that is being written right now, drawn where it will land.

  A few skeleton lines of uneven length, so the shape reads as prose rather than
  as a table. `lines` is a list of CSS widths — the caller varies them, because
  the same three widths repeated down a screen is its own kind of wrong.

  Reach for this instead of putting a spinner somewhere else on the page: the
  place the answer will appear is the only place the waiting means anything.
  """
  attr(:lines, :list, default: ["100%", "92%", "64%"])
  attr(:class, :string, default: nil)
  attr(:label, :string, default: nil, doc: "accessible name — what is being written")

  def skel_lines(assigns) do
    ~H"""
    <div class={["flex flex-col gap-1.5", @class]} role="status" aria-label={@label}>
      <.skel :for={w <- @lines} width={w} />
    </div>
    """
  end

  @doc """
  A turn being written, in the transcript, at the place it will appear.

  The same voice-coloured rule as `thought/1`, because that is what it is about to
  become — the placeholder and the line that replaces it are the same shape in the
  same colour, so the transcript doesn't jump when the words arrive.

  `note` is the kit's attribution line, and it does the same work here as it does
  on a finished move: it says whose turn this is while there is nothing else to go
  on. A spinner in a status bar can't say that.
  """
  attr(:colour, :string, required: true)
  attr(:note, :string, default: nil)
  attr(:lines, :list, default: ["100%", "88%", "55%"])
  attr(:class, :string, default: nil)

  def writing(assigns) do
    ~H"""
    <div
      class={["m-writing", @class]}
      style={Voice.var("--vc", @colour)}
      role="status"
      aria-label={@note}
    >
      <.skel_lines lines={@lines} />
      <div :if={@note} class="lbl mt-2 flex items-center gap-1.5" style={"color:#{@colour}"}>
        <.dot colour={@colour} live /><%= @note %>
      </div>
    </div>
    """
  end

  # ── Absence ────────────────────────────────────────────────────────────────

  @doc """
  An empty state.

  The kit's shape, and the copy rule with it: a Spectral headline in the
  fiction's voice ("Nobody is on the quay yet."), a plain line of explanation,
  one action. Never "No items found."
  """
  attr(:headline, :string, required: true)
  attr(:class, :string, default: nil)
  slot(:inner_block, doc: "the plain line of explanation")
  slot(:action, doc: "exactly one")

  def empty(assigns) do
    ~H"""
    <div class={["px-4 py-8 text-center", @class]}>
      <div class="ttl text-[16px] mb-1.5 font-medium"><%= @headline %></div>
      <p :if={@inner_block != []} class="text-[13px] leading-relaxed dim mb-4">
        <%= render_slot(@inner_block) %>
      </p>
      <%= render_slot(@action) %>
    </div>
    """
  end
end

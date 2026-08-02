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

  @doc "A small coloured dot. Carries a semantic colour, never decoration."
  attr(:colour, :string, required: true)
  attr(:class, :string, default: nil)

  def dot(assigns) do
    ~H"""
    <span class={["dot", @class]} style={"background:#{@colour}"}></span>
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
  attr(:class, :string, default: nil)

  def bar(assigns) do
    assigns = assign(assigns, :pct, assigns.fraction |> max(0.0) |> min(1.0) |> Kernel.*(100))

    ~H"""
    <div class={["bar", @class]}>
      <i style={"width:#{:erlang.float_to_binary(@pct, decimals: 1)}%"}></i>
    </div>
    """
  end

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
  slot(:inner_block)

  def fail_move(assigns) do
    ~H"""
    <div class={["m-fail", @class]}>
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
  end

  slot(:aside, doc: "trailing control on the sentence line — e.g. jump-to-failure")

  def strip(assigns) do
    ~H"""
    <div class={["strip", @class]}>
      <div class="slots">
        <div
          :for={s <- @slot_item}
          class={["slot", slot_state(s[:state]), s[:you] && "slot-you"]}
          style={s[:colour] && Voice.var("--sc", s[:colour])}
        >
          <%= s[:label] %>
        </div>
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

  @doc "A loading placeholder line. `width` is a CSS length."
  attr(:width, :string, default: "100%")

  def skel(assigns) do
    ~H"""
    <div class="skel" style={"width:#{@width}"}></div>
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

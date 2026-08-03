defmodule PolyphonyWeb.AudiencePicker do
  @moduledoc """
  *Who starts out knowing this?* — ported from `ux/polyphony-audience-picker.html`.

  One component, one question, on every surface that carries a secret: a world-bible
  entry, a character's fact, and locations the day they exist. Building it once is
  why those surfaces cost nothing, and **two copies is how the two drift apart** — so
  this is the only implementation, and both editors call it with a different header.

  ## What it draws, and why in that order

  **Groups first**, because that's the answer that scales: a group is named rather
  than expanded, so its membership moves and a walk-on written into it later arrives
  already knowing. People follow, **grouped by cast tier**, because forty-one
  characters is normal once walk-ons autogenerate and a flat list stops being
  readable long before that.

  Three tick states, and the middle one is the design's whole argument for additive
  audiences:

    * **solid** — named directly; tap to remove.
    * **outlined** (`:via`) — inherited from a group, and **not individually
      removable**. Take the group off instead. That is the price of *no exceptions*,
      and it is cheap: the alternative doubles the mental model to buy a rare case.
    * **empty** — not in on it.

  The character a fact is *about* is locked on and labelled *it's theirs*: a character
  always knows their own secrets, so it is never a decision.

  ## The resolved line

  The footer says who this means **right now**, and it is the honesty check rather
  than decoration — a group's membership will change, so a count taken at authoring
  time would quietly become a lie. It is computed by `Audience.resolve/2`, the same
  function the context assembler asks, so the number shown is the number of people who
  will actually be told.
  """
  use Phoenix.Component

  alias Polyphony.Authoring.{Audience, CharacterSheet}
  alias PolyphonyWeb.{Kit, Voice}

  @doc """
  The picker.

  `audience` is the current `%Audience{}`. `groups` and `people` are `[{id, label,
  note}]` and `[{id, label, tier, colour}]`. `owner` is the character the secret is
  about, or nil. `resolved` is the id list `Audience.resolve/2` returned.

  Events go to the host LiveView: `toggle_audience` with `kind` (`group`/`character`)
  and `id`, and `close_audience`.
  """
  attr(:statement, :string, required: true)
  attr(:context_label, :string, default: nil, doc: "where the secret lives — *Saltmarch*")
  attr(:audience, :any, required: true)
  attr(:groups, :list, default: [])
  attr(:people, :list, default: [])
  attr(:owner, :string, default: nil)
  attr(:owner_label, :string, default: nil)
  attr(:resolved, :list, default: [])
  attr(:class, :string, default: nil)

  def picker(assigns) do
    assigns =
      assigns
      |> assign(:named, MapSet.new(Audience.named(assigns.audience)))
      |> assign(:reached, MapSet.new(assigns.resolved))
      |> assign(:group_ids, MapSet.new((assigns.audience || Audience.empty()).group_ids))
      |> assign(:tiers, tiers_present(assigns.people))

    ~H"""
    <Kit.sheet class={Enum.join(["mx-4 mb-4", @class || ""], " ")}>
      <Kit.row class="px-4 py-3" style="background:var(--b2)">
        <div class="flex items-center justify-between gap-2 mb-1.5">
          <span class="ttl text-[15px] font-semibold">Who starts out knowing</span>
          <button
            type="button"
            class="dim text-[17px] leading-none shrink-0"
            phx-click="close_audience"
            aria-label="Close"
          >
            ×
          </button>
        </div>
        <p class="text-[13px] leading-relaxed"><%= @statement %></p>
        <div class="flex items-center gap-1.5 mt-2">
          <Kit.dot colour="var(--secret)" />
          <span class="lbl" style="color:var(--secret)">
            Secret<%= if @context_label, do: " · #{@context_label}" %>
          </span>
        </div>
      </Kit.row>

      <%!-- The owner, locked on. Drawn first because it's the one row that isn't a
            choice, and burying it would invite someone to look for the tick. --%>
      <Kit.row :if={@owner} class="px-4 py-2.5 flex items-center gap-2.5">
        <Kit.chk state={:via} />
        <span class="av" style="background:var(--secret)"></span>
        <span class="text-[13px] font-semibold flex-1 min-w-0 truncate"><%= @owner_label %></span>
        <span class="text-[11px] dim shrink-0">it's theirs</span>
      </Kit.row>

      <%!-- Groups first: the answer that scales, and the one that keeps working when
            somebody new is written months from now. --%>
      <div :if={@groups != []}>
        <Kit.row class="px-4 py-2" style="background:var(--b2)">
          <span class="lbl dim">Groups</span>
        </Kit.row>
        <button
          :for={{id, label, note} <- @groups}
          type="button"
          class="row w-full px-4 py-2.5 flex items-center gap-2.5 text-left"
          phx-click="toggle_audience"
          phx-value-kind="group"
          phx-value-id={id}
          aria-pressed={to_string(MapSet.member?(@group_ids, to_string(id)))}
        >
          <Kit.chk state={if(MapSet.member?(@group_ids, to_string(id)), do: :on, else: :off)} />
          <span class="flex-1 min-w-0">
            <span class="block text-[13px] font-semibold"><%= label %></span>
            <span class={["block text-[11px]", note_tone(note)]}><%= note_text(note) %></span>
          </span>
        </button>
      </div>

      <%!-- People, by tier. Forty-one characters is normal once walk-ons
            autogenerate; a flat list stops being readable well before that. --%>
      <div :for={{tier, label} <- @tiers}>
        <Kit.row class="px-4 py-2" style="background:var(--b2)">
          <span class="lbl dim"><%= label %></span>
        </Kit.row>
        <button
          :for={{id, name, _t, colour} <- for(p <- @people, elem(p, 2) == tier, do: p)}
          type="button"
          class="row w-full px-4 py-2.5 flex items-center gap-2.5 text-left"
          disabled={inherited?(id, @named, @reached)}
          phx-click="toggle_audience"
          phx-value-kind="character"
          phx-value-id={id}
          aria-pressed={to_string(MapSet.member?(@reached, to_string(id)))}
        >
          <Kit.chk state={tick(id, @named, @reached)} />
          <span class="av" style={"background:#{tick_colour(id, @reached, colour)}"}></span>
          <span class="text-[13px] flex-1 min-w-0 truncate"><%= name %></span>
          <span :if={inherited?(id, @named, @reached)} class="text-[11px] dim shrink-0">
            via a group
          </span>
        </button>
      </div>

      <Kit.empty :if={@groups == [] and @people == []} headline="There's nobody to let in on it.">
        Nobody has been written into this campaign yet. The secret keeps — you can come
        back to this.
      </Kit.empty>

      <%!-- The honesty check: who this means *right now*, because a group's
            membership will change and a count frozen at authoring time is a lie. --%>
      <div :if={@groups != [] or @people != []} class="px-4 py-3" style="background:var(--b2)">
        <div class="flex items-start gap-2">
          <Kit.dot colour="var(--secret)" class="mt-1.5 shrink-0" />
          <p class="text-[12.5px] leading-relaxed"><%= resolved_line(@resolved) %></p>
        </div>
        <p :if={@group_ids != MapSet.new()} class="text-[11px] leading-relaxed dim mt-1.5 pl-3.5">
          Anyone written into <%= group_phrase(@groups, @group_ids) %> later will know it too.
        </p>
      </div>
    </Kit.sheet>
    """
  end

  @doc """
  The audience line on a secret item — *Secret · the Tidewatch, +1*.

  Part of the item rather than behind the picker, so the count is readable without
  opening anything. Nothing renders at all until the item is marked secret; that's the
  caller's `:if`, since only it knows.
  """
  attr(:audience, :any, required: true)
  attr(:labels, :map, default: %{}, doc: "id => display name, for groups and characters alike")
  attr(:class, :string, default: nil)

  def line(assigns) do
    assigns = assign(assigns, :text, Audience.summary(assigns.audience, &assigns.labels[&1]))

    ~H"""
    <span class={["flex items-center gap-1.5", @class]}>
      <Kit.dot colour="var(--secret)" />
      <span class="lbl" style="color:var(--secret)">Secret · <%= @text %></span>
    </span>
    """
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  # Solid when named directly, outlined when only a group put them there.
  defp tick(id, named, reached) do
    id = to_string(id)

    cond do
      MapSet.member?(named, id) -> :on
      MapSet.member?(reached, id) -> :via
      true -> :off
    end
  end

  defp inherited?(id, named, reached) do
    id = to_string(id)
    MapSet.member?(reached, id) and not MapSet.member?(named, id)
  end

  # Someone in on it takes the secret colour, so the picker scans as "who's lit up".
  defp tick_colour(id, reached, colour) do
    if MapSet.member?(reached, to_string(id)), do: "var(--secret)", else: colour
  end

  defp tiers_present(people) do
    present = MapSet.new(people, &elem(&1, 2))

    for tier <- CharacterSheet.tiers(),
        MapSet.member?(present, tier),
        do: {tier, CharacterSheet.tier_label(tier)}
  end

  # An empty group is not an error — it's how you set a trap before anyone walks into
  # it — so it says so in the lamp rather than reading as a mistake.
  defp note_text({:empty, _}), do: "Nobody's in it yet"
  defp note_text({:count, 1}), do: "1 person, and anyone new who joins"
  defp note_text({:count, n}), do: "#{n} people, and anyone new who joins"
  defp note_text(text) when is_binary(text), do: text
  defp note_text(_), do: ""

  defp note_tone({:empty, _}), do: "text-[var(--lamp)]"
  defp note_tone(_), do: "dim"

  defp resolved_line([]),
    do: "Right now that's nobody. Everyone finds this out in play, if they ever do."

  defp resolved_line([_one]), do: "Right now that's 1 person."
  defp resolved_line(ids), do: "Right now that's #{length(ids)} people."

  defp group_phrase(groups, ids) do
    case for({id, label, _n} <- groups, MapSet.member?(ids, to_string(id)), do: label) do
      [] -> "a group"
      [one] -> one
      many -> Enum.join(many, " or ")
    end
  end

  @doc """
  A person row's voice colour, so somebody is the same hue here as everywhere else.
  """
  @spec colour(CharacterSheet.t() | any()) :: String.t()
  def colour(%CharacterSheet{} = sheet), do: Voice.of_sheet(sheet)
  def colour(_), do: Voice.neutral()
end

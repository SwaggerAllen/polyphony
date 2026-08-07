defmodule PolyphonyWeb.Transcript do
  @moduledoc """
  The transcript: a stream of committed moves, rendered as prose.

  Shared by the play screen and the published reading view, which is the point —
  *the reading view is the play screen with a different bottom bar* (§03,
  `ux/polyphony-browse.html`): same header, same perspective control, same
  transcript, same beat rules, and only the composer replaced by scene navigation.
  A second implementation of prose rendering is how the two drift, and the one a
  reader sees is the one nobody is looking at.

  **Nothing here decides who sees what.** `PolyphonyCore.Visibility` already did that
  before a message reached this module; every function below is display only.

  ## Two registers, same structure

  `.stage` (authoring) puts a gutter label beside each move so the author can see
  the machinery; `.page` (reading) lets them read as prose. They tell move types
  apart the same way, at different densities. Neither uses italics — the kit drops
  slant as a semantic outright, because it measurably impairs reading.

  ## Ids in, names out

  Every payload names its character by **id** (§5.2). `PolyphonyCore.Scene.Cast`
  resolves them at this edge and nowhere else; nothing that routes ever sees a name.
  """
  use Phoenix.Component

  alias PolyphonyCore.Scene.Cast
  alias PolyphonyWeb.{Kit, Voice}

  @doc """
  Group a flat message stream into **beats, each holding its blocks**.

  A character's turn is one committed packet and all its moves; everything else — a
  world beat, an entrance — is a plain block with no attribution, because it is
  nobody's turn. Blocks then group into the beat they happened in.

  ## Why a tree rather than a flat list

  This used to return a flat list of blocks, each stamped with an `eff_beat` copied
  down from the last turn, and each consumer then walked that list a second time
  deciding where a beat divider opened. Both of those were the same workaround: a flat
  list has nowhere to hang a divider, so the beat had to be duplicated onto every block
  and re-derived by looking at neighbours.

  In a tree the position *is* the beat. A block with no beat of its own belongs to the
  beat it arrived in — an append target rather than an inherited field — and the divider
  is the beat's own header, so there is nothing to mark and nothing to walk. Two derived
  fields and two walks disappear, one of them duplicated across both consumers.

  It also fixes the divider's stickiness for free. `.beat-rule` is `position: sticky`,
  which holds only while its containing block is on screen — nested in the *first block*
  of a beat it unstuck the moment that one turn scrolled past. Nested in the beat, it
  stays for as long as the beat does, which is what a sticky heading is for.

  And it is the shape a LiveView stream needs: a beat is a bounded DOM unit (cast size
  × moves per turn) that can be re-inserted under a stable id when one of its moves
  lands, where a message is a fragment of a block and a whole transcript is unbounded.

  Beat `0` is everything before the first beat opened — scene framing — and renders no
  divider.
  """
  @type beat :: %{beat: non_neg_integer(), blocks: [map()], failures: [map()]}

  @spec beats([map()]) :: [beat()]
  def beats(messages), do: messages |> turn_blocks() |> group_by_beat()

  defp group_by_beat(blocks) do
    blocks
    |> Enum.reduce([], fn block, acc ->
      beat = block.beat || open_beat(acc)

      case acc do
        [%{beat: ^beat} = head | rest] -> [%{head | blocks: head.blocks ++ [block]} | rest]
        _ -> [%{beat: beat, blocks: [block], failures: []} | acc]
      end
    end)
    |> Enum.reverse()
  end

  # The beat currently being filled. Nothing yet means scene framing, which is beat 0 —
  # the same floor the old `eff_beat` inheritance started from.
  defp open_beat([%{beat: beat} | _]), do: beat
  defp open_beat([]), do: 0

  @doc """
  File each failure into the beat it happened in, after that beat's turns.

  A failure without a beat is a scene-close operation (arc extraction, summarization),
  emitted at the scene's current beat — so it defaults to `current_beat` and lands with
  the latest action rather than at the top.

  A beat in which *every* turn failed has no blocks and so no container of its own; it
  gets one here, which means it now draws its divider. That is a change, and the right
  one: the beat happened, and a row of failures under no heading reads as though they
  belong to the beat above.
  """
  @spec with_failures([beat()], [map()], non_neg_integer()) :: [beat()]
  def with_failures(beats, [], _current_beat), do: beats

  def with_failures(beats, failures, current_beat) do
    by_beat = Enum.group_by(failures, &(&1.beat || current_beat))

    beats
    |> Enum.map(&%{&1 | failures: Map.get(by_beat, &1.beat, [])})
    |> add_missing_beats(by_beat)
    |> Enum.sort_by(& &1.beat)
  end

  defp add_missing_beats(beats, by_beat) do
    held = MapSet.new(beats, & &1.beat)

    beats ++
      for {beat, failures} <- by_beat,
          not MapSet.member?(held, beat),
          do: %{beat: beat, blocks: [], failures: failures}
  end

  @doc """
  A read-only transcript — the published reading view, and any surface that shows
  the story without offering to change it.

  Beat rules are the beat container's own heading rather than a flag on whichever block
  happened to come first — see `beats/1` for why that stopped being a walk.
  """
  attr(:events, :list, required: true, doc: "projected events, in order")
  attr(:register, :atom, default: :page, values: [:stage, :page])
  attr(:names, :map, default: %{}, doc: "character id → display name")
  attr(:voices, :map, default: %{}, doc: "character id → voice colour")
  attr(:empty, :string, default: "Nothing happened here.")
  attr(:on_name, :string, default: "who", doc: "event pushed when a name is tapped")

  def transcript(assigns) do
    assigns =
      assigns
      |> assign(:cast, Cast.from_names(assigns.names))
      |> assign(:beats, assigns.events |> Enum.map(&to_message/1) |> beats())

    ~H"""
    <div class="transcript">
      <%= for beat <- @beats do %>
        <div class="beat">
          <Kit.beat_rule :if={beat.beat > 0} beat={beat.beat} />

          <%= for b <- beat.blocks do %>
        <div class="turn-block">
          <div :if={b.type == :event} class="py-1">
            <div :for={m <- b.msgs}><%= render_move(m, @cast, @register, @voices) %></div>
          </div>

          <div :if={b.type == :turn} class="mb-5">
            <%!-- The name is the way in to who this is. A `button` rather than a link:
                  the answer opens over the page, so following it never costs you your
                  place in the story. --%>
            <button
              type="button"
              class={[
                "ttl font-semibold mb-1.5 block text-left",
                @register == :stage && "text-[14px]",
                @register == :page && "text-[12.5px] tracking-[.06em]"
              ]}
              style={"color:#{Voice.of(@voices, b.character)}"}
              phx-click={@on_name}
              phx-value-id={b.character}
              aria-label={"About #{Cast.render_name(@cast, b.character)}"}
            >
              <%= block_name(@cast, b.character, @register) %>
            </button>
            <div :for={m <- ordered_moves(b.msgs)}>
              <%= render_move(m, @cast, @register, @voices) %>
            </div>
          </div>
        </div>
          <% end %>
        </div>
      <% end %>

      <p :if={@beats == []} class="text-[13px] leading-relaxed dim py-6 text-center">
        <%= @empty %>
      </p>
    </div>
    """
  end

  defp block_name(cast, id, :page), do: cast |> Cast.render_name(id) |> String.upcase()
  defp block_name(cast, id, _register), do: Cast.render_name(cast, id)

  @doc """
  Who is this — the **public** read of a character, opened from their name.

  A transcript names people and shows nothing about them, which is fine on the fourth
  scene and useless on the first: a reader meets six names in two pages and has no way
  to ask who any of them are without leaving the story.

  It shows the **cover** and nothing else from the sheet, and that is the whole design
  rather than a first cut. The cover already *is* this thing — the codebase says so in
  five places, *"the only part strangers see"* — and it is written from everything
  including the secrets under instruction to give none of them away (§2.12), with a
  leaked draft refused rather than shown. Premise, backstory and facts are the author's
  working material: some of them are concealed per-item, and a panel that had to filter
  them would be a second implementation of a guarantee that already has one.

  So there is no viewer parameter. The same card is correct for the author, for a
  character, and for a stranger reading a published campaign — which is why it can live
  here and be called from both screens.
  """
  attr(:name, :string, required: true)
  attr(:colour, :string, default: "var(--bc)")
  attr(:pronouns, :string, default: nil)
  attr(:cover, :string, default: nil)
  attr(:on_close, :string, required: true)

  def who(assigns) do
    ~H"""
    <Kit.overlay label={"About #{@name}"} on_close={@on_close}>
      <Kit.row class="px-4 py-3 flex items-start gap-3" style="background:var(--b2)">
        <span class="av shrink-0" style={"background:#{@colour}"}></span>
        <div class="min-w-0 flex-1">
          <div class="ttl text-[17px] font-semibold truncate"><%= @name %></div>
          <div :if={filled(@pronouns)} class="lbl dim mt-0.5"><%= @pronouns %></div>
        </div>
        <button
          type="button"
          class="dim text-[17px] leading-none"
          phx-click={@on_close}
          aria-label={"Close #{@name}"}
        >
          ×
        </button>
      </Kit.row>

      <div class="modal-body">
        <div :if={filled(@cover)} class="px-4 py-3">
          <p class="text-[14px] leading-relaxed"><%= @cover %></p>
        </div>

        <%!-- An honest absence rather than an empty panel. Nothing is being withheld —
              nobody has written the part a stranger reads. --%>
        <div :if={not filled(@cover)} class="px-4 py-4">
          <p class="text-[13px] leading-relaxed dim">
            Nothing written about them yet — this is the part a stranger sees, and it's
            still blank.
          </p>
        </div>
      </div>
    </Kit.overlay>
    """
  end

  defp filled(text), do: is_binary(text) and String.trim(text) != ""

  @doc """
  Turn a domain event into the `%{kind:, payload:}` shape the movers render.

  The broadcaster already speaks this shape, so the live tail and a replay from the
  store render through exactly the same clauses.
  """
  @spec to_message(struct() | map()) :: map()
  def to_message(%_{} = event) do
    %{
      kind: event.__struct__ |> Module.split() |> List.last(),
      payload: event |> Map.from_struct() |> Map.new(fn {k, v} -> {k, v} end)
    }
  end

  def to_message(%{} = message), do: message

  @doc """
  Speech, in quotes.

  The mocks quote every spoken line in both registers (`ux/polyphony-play.html` §01 and
  §05) and the port dropped it. In the working register the loss was invisible — a
  `Speech` label in the gutter says which move this is. In the **reading** register
  there is no label, and speech and action rendered as the same paragraph at the same
  size: a page of prose with no way to tell what was said from what was done, which is
  the one distinction fiction has always drawn typographically.

  Curly, because this is prose — straight quotes read as code, and the kit sets
  Spectral against them. Content that already arrives quoted is not quoted twice, and a
  straight-quoted line is normalised rather than left to sit differently beside the
  others: the model's punctuation habits are not a thing a reader should be able to
  see.
  """
  @spec said(term()) :: String.t()
  def said(content) do
    case String.trim(to_string(content || "")) do
      "" -> ""
      text -> text |> unwrap() |> wrap()
    end
  end

  # Only a *matched* pair, and only at the ends. `He said "no" and left` is a line with
  # a quote in it, not a quoted line.
  defp unwrap(text) do
    cond do
      wrapped?(text, "\u201C", "\u201D") -> slice_ends(text)
      wrapped?(text, "\"", "\"") -> slice_ends(text)
      true -> text
    end
  end

  defp wrapped?(text, open, close) do
    String.length(text) > 1 and String.starts_with?(text, open) and
      String.ends_with?(text, close)
  end

  defp slice_ends(text), do: text |> String.slice(1..-2//1) |> String.trim()

  defp wrap(""), do: ""
  defp wrap(text), do: "\u201C" <> text <> "\u201D"

  defp turn_blocks(messages) do
    messages
    |> Enum.reduce([], fn m, acc ->
      payload = m[:payload] || %{}
      pid = payload[:packet_id]

      case acc do
        [%{type: :turn, packet_id: ^pid} = head | rest] when not is_nil(pid) ->
          [%{head | msgs: head.msgs ++ [m]} | rest]

        _ when is_nil(pid) ->
          [
            %{type: :event, packet_id: nil, character: nil, beat: payload[:beat], msgs: [m]}
            | acc
          ]

        _ ->
          [
            %{
              type: :turn,
              packet_id: pid,
              character: payload[:character_id] || payload[:speaker_id],
              beat: payload[:beat],
              msgs: [m]
            }
            | acc
          ]
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  A turn's moves in reading order.

  Demeanor is how they *are* through the turn, not something they do in it, so it
  leads — which is also the order the mock draws. Everything else keeps the order the
  packet declared.
  """
  @spec ordered_moves([map()]) :: [map()]
  def ordered_moves(msgs) do
    {demeanor, rest} = Enum.split_with(msgs, &(&1[:kind] == "DemeanorReported"))
    demeanor ++ rest
  end

  @doc """
  Render one message as a transcript line, in the viewer's register.

  Display only — `PolyphonyCore.Visibility` already decided who sees what before the
  message reached here.
  """
  #
  # Every payload names its character by **id** (§5.2), so each of these renders that
  # id through the scene cast. Display only — nothing here decides who sees what;
  # `Visibility` already did that before the message reached this view.
  #
  # The two registers tell move types apart the same way, structurally, but at
  # different densities: `.stage` puts a gutter label beside each move so the author
  # can see the machinery, `.page` lets them read as prose. Neither uses italics —
  # the kit drops slant as a semantic outright.
  def render_move(%{kind: "SpeechUttered", payload: p}, cast, register, _voices) do
    assigns = %{
      content: said(p[:content]),
      whisper: to_string(p[:audibility]) == "private",
      to: p[:addressed_to] |> List.wrap() |> Enum.map_join(", ", &Cast.render_name(cast, &1)),
      register: register
    }

    ~H"""
    <div class={["move speech", @whisper && "whisper"]}>
      <div :if={@register == :stage} class="flex gap-2.5">
        <span class="lbl dim pt-1 w-14 shrink-0"><%= if @whisper, do: "Whisper", else: "Speech" %></span>
        <span class="text-[15px] leading-relaxed"><%= @content %></span>
      </div>
      <p :if={@register == :page} class="text-[17px] leading-[1.75] mt-2.5"><%= @content %></p>
      <%!-- The kit's own spec for this move: *a coloured marker line under the speech*
            (`ux/polyphony-kit.html` §03, "no italic carries meaning"). Under **this
            line**, not on the turn — a whisper is one move, and a turn that contains
            one still has actions and speech everybody heard. `Visibility` has always
            been per-event; this is the rendering catching up.

            Drawn whether or not the addressees resolve to names. It used to render
            nothing when they didn't, which is the one direction that must never
            happen: a private line reading as a public one. --%>
      <div :if={@whisper} class="flex items-center gap-1.5 mt-1">
        <span class="dot" style="background:var(--pencil)"></span>
        <span class="lbl" style="color:var(--pencil)">
          <%= if @to == "", do: "Whisper", else: "Whisper → #{@to}" %>
        </span>
      </div>
    </div>
    """
  end

  def render_move(%{kind: "ThoughtOccurred", payload: p}, _cast, _register, voices) do
    # An interior move is structurally invisible to everyone else, so the note is a
    # true statement about the log rather than a warning about a setting.
    id = p[:character_id]
    assigns = %{content: p[:content], colour: Voice.of(voices, to_string(id))}

    ~H"""
    <Kit.thought colour={@colour} note="Thought · not shared" class="mt-2.5">
      <%= @content %>
    </Kit.thought>
    """
  end

  def render_move(%{kind: "ActionTaken", payload: p}, _cast, register, _voices) do
    # No actor prefix: the design attributes a turn once, at the top of its block, so
    # prepending the name here would say it twice — and the model already writes
    # actions in the third person naming whoever is acting.
    assigns = %{text: String.trim(to_string(p[:content])), register: register}

    ~H"""
    <div class="move action">
      <div :if={@register == :stage} class="flex gap-2.5">
        <span class="lbl dim pt-1 w-14 shrink-0">Action</span>
        <span class="text-[15px] leading-relaxed"><%= @text %></span>
      </div>
      <p :if={@register == :page} class="text-[17px] leading-[1.75]"><%= @text %></p>
    </div>
    """
  end

  def render_move(%{kind: "DemeanorReported", payload: p}, cast, register, _voices) do
    case String.trim(to_string(p[:demeanor] || "")) do
      "" ->
        # Nothing to report — render nothing rather than "X seems ."
        assigns = %{}
        ~H||

      demeanor ->
        assigns = %{
          demeanor: demeanor,
          who: Cast.render_name(cast, p[:character_id]),
          register: register
        }

        ~H"""
        <div class="move demeanor">
          <div :if={@register == :stage} class="flex gap-2.5">
            <span class="lbl dim pt-1 w-14 shrink-0">Demeanor</span>
            <span class="text-[14px] leading-relaxed dim"><%= @demeanor %></span>
          </div>
          <%!-- In the reading register demeanor folds into the prose rather than
                standing apart as a field. --%>
          <p :if={@register == :page} class="text-[17px] leading-[1.75] dim"><%= @demeanor %></p>
        </div>
        """
    end
  end

  def render_move(%{kind: "WorldEventOccurred", payload: p}, _cast, register, _voices) do
    assigns = %{content: p[:content], register: register}

    ~H"""
    <Kit.world_move register={@register} class="my-4"><%= @content %></Kit.world_move>
    """
  end

  def render_move(%{kind: kind, payload: p}, cast, _register, voices)
      when kind in ["CharacterEntered", "CharacterExited"] do
    # An entrance reads as fiction first: a coloured dot and a plain line, not a
    # system notice. Nobody sees the sheet behind it.
    id = to_string(p[:character_id])

    assigns = %{
      who: Cast.render_name(cast, id),
      colour: Voice.of(voices, id),
      verb: if(kind == "CharacterEntered", do: "is here", else: "has gone")
    }

    ~H"""
    <div class="flex items-center gap-2 py-1">
      <Kit.dot colour={@colour} />
      <span class="text-[13px] dim"><%= @who %> <%= @verb %>.</span>
    </div>
    """
  end

  def render_move(_other, _cast, _register, _voices) do
    assigns = %{}
    ~H||
  end
end

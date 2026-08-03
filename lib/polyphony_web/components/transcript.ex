defmodule PolyphonyWeb.Transcript do
  @moduledoc """
  The transcript: a stream of committed moves, rendered as prose.

  Shared by the play screen and the published reading view, which is the point —
  *the reading view is the play screen with a different bottom bar* (§03,
  `ux/polyphony-browse.html`): same header, same perspective control, same
  transcript, same beat rules, and only the composer replaced by scene navigation.
  A second implementation of prose rendering is how the two drift, and the one a
  reader sees is the one nobody is looking at.

  **Nothing here decides who sees what.** `Polyphony.Visibility` already did that
  before a message reached this module; every function below is display only.

  ## Two registers, same structure

  `.stage` (authoring) puts a gutter label beside each move so the author can see
  the machinery; `.page` (reading) lets them read as prose. They tell move types
  apart the same way, at different densities. Neither uses italics — the kit drops
  slant as a semantic outright, because it measurably impairs reading.

  ## Ids in, names out

  Every payload names its character by **id** (§5.2). `Polyphony.Scene.Cast`
  resolves them at this edge and nowhere else; nothing that routes ever sees a name.
  """
  use Phoenix.Component

  alias Polyphony.Scene.Cast
  alias PolyphonyWeb.{Kit, Voice}

  @doc """
  Group a flat message stream into blocks and mark where each beat opens.

  A character's turn is one committed packet and all its moves; everything else — a
  world beat, an entrance — is a plain block with no attribution, because it is
  nobody's turn.
  """
  @spec blocks([map()]) :: [map()]
  def blocks(messages), do: messages |> turn_blocks() |> mark_block_beats()

  # A block with no beat of its own inherits the last turn's, so it keeps its place.
  defp mark_block_beats(blocks) do
    {marked, _} =
      Enum.map_reduce(blocks, 0, fn b, last ->
        eff = b.beat || last
        {Map.put(b, :eff_beat, eff), eff}
      end)

    marked
  end

  @doc """
  A read-only transcript — the published reading view, and any surface that shows
  the story without offering to change it.

  Beat rules are decided by walking the blocks and noticing where the beat changes,
  never by each block guessing whether it's first, which is how the same rule ends
  up drawn three times.
  """
  attr(:events, :list, required: true, doc: "projected events, in order")
  attr(:register, :atom, default: :page, values: [:stage, :page])
  attr(:names, :map, default: %{}, doc: "character id → display name")
  attr(:voices, :map, default: %{}, doc: "character id → voice colour")
  attr(:empty, :string, default: "Nothing happened here.")

  def transcript(assigns) do
    assigns =
      assigns
      |> assign(:cast, Cast.from_names(assigns.names))
      |> assign(:blocks, assigns.events |> Enum.map(&to_message/1) |> blocks())

    ~H"""
    <div class="transcript">
      <%= for {b, rule} <- with_beat_rules(@blocks) do %>
        <div class="turn-block">
          <Kit.beat_rule :if={rule} beat={rule} />

          <div :if={b.type == :event} class="py-1">
            <div :for={m <- b.msgs}><%= render_move(m, @cast, @register, @voices) %></div>
          </div>

          <div :if={b.type == :turn} class="mb-5">
            <div
              class={[
                "ttl font-semibold mb-1.5",
                @register == :stage && "text-[14px]",
                @register == :page && "text-[12.5px] tracking-[.06em]"
              ]}
              style={"color:#{Voice.of(@voices, b.character)}"}
            >
              <%= block_name(@cast, b.character, @register) %>
            </div>
            <div :for={m <- ordered_moves(b.msgs)}>
              <%= render_move(m, @cast, @register, @voices) %>
            </div>
          </div>
        </div>
      <% end %>

      <p :if={@blocks == []} class="text-[13px] leading-relaxed dim py-6 text-center">
        <%= @empty %>
      </p>
    </div>
    """
  end

  defp block_name(cast, id, :page), do: cast |> Cast.render_name(id) |> String.upcase()
  defp block_name(cast, id, _register), do: Cast.render_name(cast, id)

  # Pair each block with the beat it opens, or nil.
  defp with_beat_rules(blocks) do
    {pairs, _} =
      Enum.map_reduce(blocks, nil, fn b, previous ->
        beat = b.eff_beat

        if is_integer(beat) and beat > 0 and beat != previous,
          do: {{b, beat}, beat},
          else: {{b, nil}, previous}
      end)

    pairs
  end

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

  Display only — `Polyphony.Visibility` already decided who sees what before the
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
      content: p[:content],
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
      <div :if={@whisper and @to != ""} class="lbl mt-1" style="color:var(--pencil)">
        Whisper · only <%= @to %>
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

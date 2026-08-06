defmodule PolyphonyWeb.Screens.Play do
  @moduledoc """
  The play screen, as markup — ported from `ux/polyphony-play.html`.

  The largest screen in the app and the one with the most states that a running app
  will not sit still in: the Director writing, a slot waiting on you, a draft pending
  acceptance, a turn that failed, auto running and auto paused, the socket dropping.
  Those are the states worth reviewing and the ones you could never reliably catch by
  opening the real thing, which is the whole argument for this module existing —
  see `PolyphonyWeb.Screens`.

  **Two registers.** Omniscient play is `stage` (working) and character play is `page`
  (reading); the register is set on `Kit.frame/1` and everything below keys off the
  tokens it sets. The same transcript is a different object in each.

  ## What it may and may not do

  It renders from assigns. The one domain call it makes is
  `Polyphony.Scene.Cast.render_name/2`, which is a `Map.get` over a struct already in
  assigns — `character_id` is the routing key everywhere and a name is display, resolved
  at the edges, and this is an edge. Anything that needs a *read* happens in
  `PolyphonyWeb.PlayLive` and arrives as an assign; the character picker used to resolve
  its own names through the library and that was a bug of exactly this kind.

  The presentation helpers live here rather than in the LiveView because they are the
  same kind of thing as the markup — `slot_view/2`, `transcript_items/1`,
  `progress_label/2` and friends turn domain values into what the screen says. A few are
  public because the LiveView reads them too.
  """
  use PolyphonyWeb, :html

  alias Polyphony.Scene.Cast
  alias PolyphonyWeb.{Kit, Layouts, Transcript, TurnEdit, Voice}

  # Who the beat loop is generating right now, if anyone — the strip's live slot.
  def generating_now(%{phase: :generating, subject: s}) when is_binary(s) and s != "", do: s
  def generating_now(_), do: nil

  # A compact HH:MM:SS (UTC) label for a timeline entry.
  def at_label(ms) when is_integer(ms) and ms > 0,
    do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S")

  def at_label(_), do: "—"

  # A character's control mode, defaulting to autonomous (matches the beat walk).
  defp control_of(modes, character), do: Map.get(modes, character) || "autonomous"

  # ── Names (§5.2) ──────────────────────────────────────────────────────────────
  #
  # The single edge between the id-keyed log and the name-keyed fiction. Every
  # human-facing string on this page goes through here; nothing that routes does.

  # Tapping a slot puts you behind that person's eyes — the same move the perspective
  # picker makes, so it goes the same way: a patch on `?as=`, which `handle_params/3`
  # already resolves. Only for someone the scene actually knows, since a slot can carry
  # a name the log mentioned and the cast has never held, and never for the perspective
  # you are already in.
  defp slot_view(%{id: id}, %Cast{} = cast, scene_id, viewer) when is_binary(id) do
    if Map.has_key?(cast.id_to_name, id) and viewer != {:character, id},
      do: ~p"/play/#{scene_id}?#{[as: id]}"
  end

  defp slot_view(_slot, _cast, _scene_id, _viewer), do: nil

  def name_of(%{assigns: %{cast: cast}}, id), do: Cast.render_name(cast, id)
  def name_of(%Cast{} = cast, id), do: Cast.render_name(cast, id)
  def name_of(_socket, id), do: to_string(id)

  # Group the flat message stream into blocks: a character's turn (one committed
  # packet, all its moves) carries edit/reroll/delete affordances; everything else
  # (world events, entrances) is a plain block.
  # The transcript as an ordered list of `{:block, block}` and `{:fail, failure}` items,
  # each failure placed at the beat it occurred (after that beat's turns) rather than in a
  # standalone pane — so a transient error and its Retry sit where they happened and vanish
  # when retried. Event blocks (no beat of their own) inherit the last turn's beat so they
  # keep their place.
  #
  # A failure without a beat is a scene-close operation (arc extraction, summarization);
  # those are emitted at the scene's current beat, so they default to `current_beat` and
  # land with the latest action rather than at the top. A character viewer only ever gets
  # their own turn failures (§1.7), which always carry a beat, so they sort in place.
  defp transcript_items(messages, failures, current_beat) do
    # Blocking and beat rules live in `PolyphonyWeb.Transcript`, shared with the
    # published reading view — the reading view *is* this screen with a different
    # bottom bar, and a second implementation of prose rendering is how the two drift.
    blocks = Transcript.blocks(messages)
    items = Enum.map(blocks, &{:block, &1}) ++ Enum.map(failures, &{:fail, &1})

    items
    |> Enum.sort_by(fn
      {:block, b} -> {b.eff_beat, 0}
      {:fail, f} -> {f.beat || current_beat, 1}
    end)
    |> mark_beat_rules()
  end

  # A beat rule opens a beat exactly once, so it's decided by walking the *sorted*
  # items — which is why this stays here rather than in the shared module: play
  # interleaves failures with turns, and a rule must open above whichever came first.
  defp mark_beat_rules(items) do
    {marked, _} =
      Enum.map_reduce(items, nil, fn
        {:block, b} = item, previous ->
          beat = b.eff_beat

          if is_integer(beat) and beat > 0 and beat != previous do
            {{:block, Map.put(b, :beat_rule, beat)}, beat}
          else
            {item, previous}
          end

        item, previous ->
          {item, previous}
      end)

    marked
  end

  # The editable text of a turn: the whole turn — thoughts, speech, actions, and
  # demeanor — serialized one move per line (see `TurnEdit`), not just its spoken lines.
  defp turn_text(block, cast),
    do: TurnEdit.serialize(block.msgs, &Cast.render_name(cast, &1))

  # The draft's own moves, put through the same serializer the transcript editor uses —
  # so a draft reads, and edits, exactly like the turn it is about to become.
  defp draft_text(draft, cast),
    do:
      draft
      |> draft_moves(draft.row.character_id)
      |> TurnEdit.serialize(&Cast.render_name(cast, &1))

  # ── Beat-loop progress ─────────────────────────────────────────────────────────

  def idle, do: %{phase: :idle, subject: nil, beat: nil}

  # The beat loop has walked to a `user_controlled` slot and stopped there (§A1). Until
  # this was read, the composer always did a *free* `CommitPacket` at `next_beat`: the
  # walk stayed paused forever, and speaking as a character the Director also drives
  # produced two turns for one slot.
  def awaiting(%{phase: :awaiting_user, subject: c, beat: b})
      when is_binary(c) and c != "" and is_integer(b),
      do: {c, b}

  def awaiting(_progress), do: nil

  # Is the composer's current speaker the one the walk is waiting on? Takes the render
  # assigns, not the socket — inside `~H` those are the bare map.
  defp your_slot?(%{progress: progress, speaker: speaker}) when is_binary(speaker) do
    match?({^speaker, _beat}, awaiting(progress))
  end

  defp your_slot?(_assigns), do: false

  # "Busy" for the sake of blocking input: a beat is actively running (the Director is
  # deciding, or a character is generating). `:awaiting_user` is *not* busy — that's the
  # user's own slot — and `:idle` means the loop has settled.
  def beat_busy?(%{phase: phase}), do: phase in [:director, :generating]
  def beat_busy?(_), do: false

  # The broadcaster announces a subject by character id (§5.2); the player reads a name.
  defp progress_label(%{phase: :director}, _cast), do: "The director is setting the scene…"

  defp progress_label(%{phase: :generating, subject: c}, cast) when is_binary(c) and c != "",
    do: "#{Cast.render_name(cast, c)} is writing their turn…"

  defp progress_label(%{phase: :generating}, _cast), do: "A character is writing their turn…"

  defp progress_label(%{phase: :awaiting_user, subject: c}, cast) when is_binary(c) and c != "",
    do: "Waiting for you to write #{Cast.render_name(cast, c)}…"

  defp progress_label(_, _cast), do: "Working…"

  # The two things the loop can be doing, each drawn as the move it is about to become:
  # the Director's is `m-world`'s rules-above-and-below, a character's is the
  # voice-coloured rule they will speak inside. Getting this wrong — one generic
  # placeholder for both — would make the transcript reflow the moment the real move
  # arrived, which is the jump the placeholder exists to prevent.
  attr(:progress, :map, required: true)
  attr(:cast, :any, required: true)
  attr(:voices, :map, required: true)

  defp writing_move(%{progress: %{phase: :director}} = assigns) do
    ~H"""
    <Kit.world_move class="my-3">
      <Kit.skel_lines lines={["96%", "72%"]} label="The Director is setting the scene" />
    </Kit.world_move>
    """
  end

  defp writing_move(assigns) do
    assigns =
      assign(assigns,
        subject: generating_now(assigns.progress),
        label: progress_label(assigns.progress, assigns.cast)
      )

    ~H"""
    <Kit.writing
      class="my-3"
      colour={Voice.of(@voices, @subject)}
      note={@label}
      lines={["100%", "88%", "55%"]}
    />
    """
  end

  # Auto: one control that says what it will do next.
  #
  # Three states, three verbs, and never two of them at once — a bar carrying Auto,
  # Pause *and* Resume asks the author which of three things is currently true, which is
  # the question the control is supposed to answer.
  attr(:auto, :any, required: true)
  attr(:progress, :map, required: true)

  defp auto_control(%{auto: %{status: "running"}} = assigns) do
    ~H"""
    <Kit.btn kind={:ghost} type="button" phx-click="pause_auto">Pause</Kit.btn>
    """
  end

  defp auto_control(%{auto: %{status: "paused"}} = assigns) do
    ~H"""
    <Kit.btn kind={:ghost} type="button" phx-click="resume_auto">Resume</Kit.btn>
    """
  end

  defp auto_control(assigns) do
    ~H"""
    <Kit.btn
      kind={:ghost}
      type="button"
      phx-click="start_auto"
      disabled={beat_busy?(@progress)}
      title="Let the scene run itself until the Director ends it, everyone leaves, or it hits the beat limit"
    >
      Auto
    </Kit.btn>
    """
  end

  defp auto_line(%{status: "running"} = run),
    do: "Running itself — beat #{run.beats_run} of #{run.max_beats}."

  defp auto_line(%{status: "paused"} = run),
    do: "Paused at beat #{run.beats_run} of #{run.max_beats}."

  defp auto_line(%{status: "done"} = run),
    do: "#{run.ended_reason || "Stopped."} #{run.beats_run} beats."

  defp auto_line(_), do: ""

  defp auto_colour(%{status: "running"}), do: "var(--lamp)"
  defp auto_colour(%{status: "paused"}), do: "var(--bcm)"
  defp auto_colour(_), do: "var(--ok)"

  # A short, human reason for a failure line — the model's reason if any, else the kind.
  def failure_reason(%{reason: r}) when is_binary(r) and r != "", do: r
  def failure_reason(%{kind: k}) when is_binary(k) and k != "", do: String.replace(k, "_", " ")
  def failure_reason(_), do: "generation failed"

  # ── Render ─────────────────────────────────────────────────────────────────────
  #
  # Ported from `ux/polyphony-play.html`. The register is the outer decision: a
  # character viewer gets `.page` (reading — wide measure, prose, machinery at the
  # edges) and the omniscient author gets `.stage` (working — gutter labels and the
  # editorial layer). Same components, same tokens, different density.
  #
  # The stage register has **no composer**, by design: to write a character you
  # become them. The GM's bottom bar is Narrate / Introductions / Continue instead,
  # and the strip's sentence is the way across — it names who is waiting to be
  # written.

  # "" -> "say-input"; "auto" -> "auto-say-input". Keeps the app's DOM byte-identical.
  defp eid("", name), do: name
  defp eid(nil, name), do: name
  defp eid(prefix, name), do: "#{prefix}-#{name}"

  attr(:id, :string,
    default: "",
    doc: """
    A prefix for every element id in this screen. Empty in the app, where the screen
    renders once and the ids are what tests and JS hooks target. Storybook renders
    every variation on one page, so each one passes a distinct prefix — without it
    the variations collide and a label points at another variation's input.
    """
  )

  attr(:register, :atom,
    required: true,
    doc: ":stage for omniscient play, :page for a character read"
  )

  attr(:viewer, :any, required: true, doc: ":omniscient | {:character, character_id}")

  attr(:cast, :any,
    required: true,
    doc: "%Polyphony.Scene.Cast{} — the id↔name map, for display only"
  )

  attr(:scene_title, :string, required: true, doc: "the authored location; never generated")
  attr(:campaign_name, :string, default: "")
  attr(:scene_id, :string, required: true)
  attr(:current_user, :map, default: nil)

  attr(:messages, :list, default: [], doc: "canonical moves, %{kind:, payload:}")
  attr(:failures, :list, default: [], doc: "per-viewer failed turns, rendered in place")

  attr(:strip, :map,
    required: true,
    doc: "%{slots:, sentence:, tone:} — see PolyphonyWeb.Play.Strip"
  )

  attr(:progress, :map,
    required: true,
    doc: "%{phase:, subject:, beat:} — idle/director/generating/awaiting_user"
  )

  attr(:next_beat, :integer, default: 0)

  attr(:roster, :list, default: [], doc: "character ids present at this beat")
  attr(:voices, :map, default: %{})
  attr(:control_modes, :map, default: %{})
  attr(:speaker, :any, default: nil)
  attr(:who, :any, default: nil)

  attr(:composing, :boolean, default: false)
  attr(:editing, :any, default: nil)
  attr(:drafts, :list, default: [])
  attr(:editing_draft, :any, default: nil)
  attr(:narrating, :boolean, default: false)
  attr(:narrating_draft, :string, default: "")
  attr(:drafting_narration, :boolean, default: false)

  attr(:panel, :any, default: nil, doc: "which side panel is open, or nil")
  attr(:introductions, :list, default: [])

  attr(:joinable, :list,
    default: [],
    doc: "%{id, name} — names resolved in the LiveView, not here"
  )

  attr(:writable, :list, default: [], doc: "%{id, name} — walk-ons not written yet")
  attr(:writing_in, :any, default: nil, doc: "MapSet of ids currently being written in")

  attr(:auto, :any, default: nil, doc: "%AutoRun{} or nil — full auto mode")
  attr(:debug_events, :boolean, default: false)
  attr(:debug_trace, :boolean, default: false)
  attr(:debug_feed, :list, default: [])
  attr(:debug_feed_text, :string, default: "")

  def screen(assigns) do
    ~H"""
    <Kit.frame
      register={@register}
      class="flex flex-col min-h-0"
      style="height:100dvh"
    >
      <%!-- The kit's standard header: context small, the scene's location as the
            title, perspective control top right, overflow last. --%>
      <Kit.header title={@scene_title} eyebrow={@campaign_name}>
        <:actions>
          <form id={eid(@id, "viewer-form")} phx-change="view_as">
            <Kit.viewas_select
              id={eid(@id, "viewer-select")}
              label="Viewing as"
              name="as"
              colour={viewer_colour(@viewer, @voices)}
            >
              <option value="" selected={@viewer == :omniscient}>Omniscient</option>
              <option :for={c <- @roster} value={c} selected={@viewer == {:character, c}}><%= name_of(@cast, c) %></option>
            </Kit.viewas_select>
          </form>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <%!-- Connection. Silent when healthy: a permanent "everything is fine" light is
            noise and trains people to stop reading the one place that matters. These
            are driven by the classes LiveView puts on the container, so they need no
            server state — and because reconnecting replays the canonical scene, the
            copy can promise recovery. --%>
      <div
        class="hidden [.phx-loading_&]:flex items-center gap-2 px-4 py-2 row"
        style="background:color-mix(in srgb,var(--lamp) 12%,transparent)"
      >
        <Kit.dot colour="var(--lamp)" />
        <span class="text-[12.5px]">Reconnecting — you won't lose the scene.</span>
      </div>
      <div
        class="hidden [.phx-error_&]:flex items-center gap-2 px-4 py-2 row"
        style="background:color-mix(in srgb,var(--pencil) 12%,transparent)"
      >
        <Kit.dot colour="var(--pencil)" />
        <span class="text-[12.5px]">No connection. The scene will catch up when you're back.</span>
      </div>

      <div :if={@viewer == :omniscient and (@debug_events or @debug_trace)} class="px-4">
        <div class="dbg-head dim flex items-center gap-2 py-2">
          <span>Debug timeline — <%= length(@debug_feed) %> entries</span>
          <Kit.btn
            id={eid(@id, "scene-debug-copy-btn")}
            kind={:ghost}
            size={:sm}
            type="button"
            phx-hook="CopyText"
            data-copy-target={eid(@id, "scene-debug-copy")}
          >
            Copy
          </Kit.btn>
        </div>
        <pre id={eid(@id, "scene-debug-copy")} hidden><%= @debug_feed_text %></pre>
      </div>

      <%!-- Only the transcript scrolls: the header, the strip and the bottom bar hold
            their places, which is what makes the strip "always visible". The kit's
            `.scroller` is a panel height (520px) and would fight that, so the fill is
            done with utilities and the transcript keeps its own scrollbar. --%>
      <div id={eid(@id, "transcript")} class="flex-1 min-h-0 overflow-y-auto px-4" phx-hook="Autoscroll">
        <%= if @viewer == :omniscient and (@debug_events or @debug_trace) do %>
          <div id={eid(@id, "debug-timeline")}>
            <div :for={entry <- @debug_feed} class={"dbg-entry dbg-#{entry.kind}"}>
              <%= render_debug_entry(entry) %>
            </div>
          </div>
        <% else %>
          <%= for {item, i} <- Enum.with_index(transcript_items(@messages, @failures, max(@next_beat - 1, 0))) do %>
            <%= case item do %>
              <% {:block, block} -> %>
                <.turn_block
                  id={eid(@id, "blk-#{i}")}
                  block={block}
                  register={@register}
                  cast={@cast}
                  voices={@voices}
                  beat_rule={block[:beat_rule]}
                  editable={@viewer == :omniscient and block.type == :turn}
                  editing={@editing}
                  control={control_of(@control_modes, block.character)}
                />
              <% {:fail, f} -> %>
                <Kit.fail_move
                  id={eid(@id, "fail-#{i}")}
                  class="my-3"
                  title={"#{if f.subject, do: name_of(@cast, f.subject), else: "A turn"} didn't generate"}
                  detail={failure_reason(f)}
                >
                  <div :if={f.retryable} class="flex flex-wrap gap-0.5 mt-1.5 -ml-1">
                    <Kit.btn kind={:pen} phx-click="retry_failure" phx-value-id={f.id}>Retry</Kit.btn>
                  </div>
                </Kit.fail_move>
            <% end %>
          <% end %>
          <Kit.empty
            :if={@messages == [] and @failures == [] and not beat_busy?(@progress)}
            headline={empty_headline(@viewer)}
          >
            Nothing has happened here yet.
          </Kit.empty>

          <%!-- The turn being written, where it will land. The strip's waiting line
                says *that* something is happening; this says who, and puts it at the
                bottom of the transcript the reader is already looking at — which is
                also where the words will appear, so nothing jumps when they do.

                A first beat used to be the worst case: an empty scene, an empty-state
                headline saying nothing has happened here yet, and the only sign of
                life a sentence in a bar below the fold. --%>
          <.writing_move
            :if={beat_busy?(@progress)}
            progress={@progress}
            cast={@cast}
            voices={@voices}
          />
        <% end %>
      </div>

      <Transcript.who
        :if={@who}
        name={@who.name || "Someone"}
        pronouns={@who.pronouns}
        cover={@who.cover}
        colour={Voice.of_sheet(@who)}
        on_close="close_who"
      />

      <Kit.strip sentence={@strip.sentence} tone={@strip.tone}>
        <:slot_item
          :for={s <- @strip.slots}
          label={s.label}
          state={s.state}
          colour={s.colour}
          you={s.you}
          patch={slot_view(s, @cast, @scene_id, @viewer)}
        />
      </Kit.strip>

      <%!-- The bottom bar. A player writes; the GM directs. --%>
      <div
        class="say-bar shrink-0 px-4 py-3"
        style="background:var(--b2);border-top:1px solid var(--rule)"
      >
        <Kit.waiting_line :if={beat_busy?(@progress)} label={progress_label(@progress, @cast)} />

        <.draft_card
          :for={d <- @drafts}
          draft={d}
          cast={@cast}
          voices={@voices}
          register={@register}
          editing={@editing_draft == d.row.id}
        />

        <%!-- The walk has stopped on this character and is holding the beat open for
              them (§A1). Said out loud, because otherwise the only difference between
              "your slot is waiting" and "you are speaking out of turn" is which one
              produces a double turn later. --%>
        <div
          :if={your_slot?(assigns)}
          class="flex items-center gap-2 mb-2 px-3 py-2 rounded-lg"
          style="background:color-mix(in srgb,var(--lamp) 12%,transparent)"
        >
          <Kit.dot colour="var(--lamp)" />
          <span class="text-[12.5px] flex-1">The scene is waiting on your turn.</span>
          <Kit.btn size={:sm} kind={:ghost} type="button" phx-click="pass_turn">Pass</Kit.btn>
        </div>

        <form :if={@speaker} id={eid(@id, "say-form")} phx-submit="say">
          <div class="flex items-center gap-1.5 mb-2 flex-wrap">
            <span class="lbl dim">Say it as</span>
            <span class="pill" style={"border-color:#{Voice.of(@voices, @speaker)};color:#{Voice.of(@voices, @speaker)}"}>
              <%= name_of(@cast, @speaker) %>
            </span>
            <span class="lbl dim">· whisper with (whisper to NAME: …)</span>
          </div>
          <label for={eid(@id, "say-input")} class="sr-only">What does <%= name_of(@cast, @speaker) %> do?</label>
          <textarea
            id={eid(@id, "say-input")}
            name="text"
            rows="1"
            class="field say-input px-3.5 py-3 text-[15px] w-full"
            phx-hook="ComposerInput"
            phx-update="ignore"
            autocomplete="off"
            placeholder={"What does #{name_of(@cast, @speaker)} do?"}
          ></textarea>
          <div class="flex items-center justify-between mt-2.5 gap-2">
            <div class="flex items-center gap-1.5">
              <Kit.btn
                kind={:ghost}
                type="button"
                data-composer-expand="true"
                disabled={@composing or beat_busy?(@progress)}
                title="Draft or expand this turn for you — you can edit it before sending"
              >
                <%= if @composing, do: "✦ …", else: "✦ Expand" %>
              </Kit.btn>
              <%!-- The field grows to about five lines and then scrolls; past that
                    the transcript it answers has gone off the top. For a turn that is
                    genuinely long, this hands the whole screen over instead. Plain JS
                    like the rest of the composer — a class on <body>, so a re-render
                    can't drop it.

                    One button, labelled for the state it is in. Full screen covers the
                    scene you are answering, and on a phone there is no Escape key to
                    get back to it, so the way out has to be visible and say so. --%>
              <Kit.btn
                kind={:ghost}
                type="button"
                id={eid(@id, "composer-fullscreen")}
                aria-pressed="false"
                title="Write with the whole screen"
              >
                <span class="say-enter">⤢ Full screen</span>
                <span class="say-exit">⤡ Close full screen</span>
              </Kit.btn>
            </div>
            <Kit.btn kind={:primary} type="submit" disabled={beat_busy?(@progress)}>
              Take the turn
            </Kit.btn>
          </div>
        </form>

        <%!-- The GM has no composer: to write a character you become them, which the
              strip's sentence says out loud. Narrate is the one thing only the GM can
              write, because it isn't anybody's turn. --%>
        <div :if={is_nil(@speaker)}>
          <form
            :if={@narrating}
            id={eid(@id, "narrate-form")}
            phx-submit="narrate"
            phx-change="sync_narrate"
            class="mb-2"
          >
            <label for={eid(@id, "narrate-input")} class="lbl dim">What happens</label>

            <%!-- Drawn where the words will land, like every other wait. The textarea
                  is replaced rather than sat beside: an empty box is what nothing
                  happening looks like, and there is nothing here to lose. --%>
            <Kit.skel_lines
              :if={@drafting_narration}
              class="mt-1.5"
              lines={["100%", "72%"]}
              label="Drafting what happens"
            />
            <textarea
              :if={not @drafting_narration}
              id={eid(@id, "narrate-input")}
              name="text"
              rows="2"
              class="field say-input px-3.5 py-3 text-[15px] w-full mt-1.5"
              autocomplete="off"
              phx-debounce="200"
              placeholder="The tide bell rings twice…"
            ><%= @narrating_draft %></textarea>

            <div class="flex items-center justify-between gap-2 mt-2">
              <%!-- The one move that is entirely the author's was the only one on this
                    bar with no ✦. It takes what is typed and sharpens it, or writes one
                    from nothing — the same two behaviours ✦ has everywhere else. --%>
              <Kit.btn
                kind={:ghost}
                type="button"
                phx-click="expand_narrate"
                disabled={@drafting_narration}
                title="Draft what happens — you can edit it before narrating"
              >
                <%= if @drafting_narration, do: "✦ …", else: "✦ Expand" %>
              </Kit.btn>
              <div class="flex gap-1.5">
                <Kit.btn kind={:ghost} type="button" phx-click="cancel_narrate">Cancel</Kit.btn>
                <Kit.btn kind={:primary} type="submit" disabled={@drafting_narration}>
                  Narrate it
                </Kit.btn>
              </div>
            </div>
          </form>

          <div class="flex items-center justify-between gap-2">
            <div class="flex gap-2">
              <Kit.btn :if={not @narrating} kind={:ghost} type="button" phx-click="narrate_open">
                Narrate
              </Kit.btn>
              <Kit.btn kind={:ghost} type="button" phx-click="toggle_cast">
                Cast <span class="dim"><%= length(@roster) %></span>
              </Kit.btn>
              <Kit.btn :if={@introductions != []} kind={:ghost} type="button" phx-click="toggle_intros">
                Introductions <span class="dim"><%= length(@introductions) %></span>
              </Kit.btn>
            </div>
            <div class="flex gap-1.5">
              <.auto_control auto={@auto} progress={@progress} />
              <Kit.btn kind={:primary} type="button" phx-click="continue" disabled={beat_busy?(@progress)}>
                Continue
              </Kit.btn>
            </div>
          </div>

          <%!-- Where an auto run says how far it has got, and what stopped it. A run
                that ends with nothing said is indistinguishable from one that is still
                thinking, and the difference is minutes of waiting. --%>
          <div :if={@auto} class="flex items-center gap-2 mt-2">
            <Kit.dot colour={auto_colour(@auto)} live={@auto.status == "running"} />
            <span class="text-[12px] dim flex-1"><%= auto_line(@auto) %></span>
            <Kit.btn :if={@auto.status == "done"} kind={:pen} type="button" phx-click="clear_auto">
              Dismiss
            </Kit.btn>
          </div>
        </div>
      </div>

      <%!-- Author panels: the cast's control modes, and the Director's pending
            introductions. Both are GM tooling — a player never sees either. --%>
      <div :if={@panel == :cast and @viewer == :omniscient} class="row px-4 py-3">
        <div class="lbl dim mb-2">Who drives each character</div>
        <div :for={c <- @roster} class="flex items-center justify-between gap-2 py-1.5">
          <span class="text-[13px] font-semibold" style={"color:#{Voice.of(@voices, c)}"}>
            <%= name_of(@cast, c) %>
          </span>
          <form id={eid(@id, "control-#{c}")} phx-change="set_control">
            <input type="hidden" name="character" value={c} />
            <label for={"control-select-#{c}"} class="sr-only">Control mode</label>
            <select id={eid(@id, "control-select-#{c}")} name="control" class="field px-2 py-1 text-[12px]">
              <option value="autonomous" selected={control_of(@control_modes, c) == "autonomous"}>
                Automated
              </option>
              <option value="assisted" selected={control_of(@control_modes, c) == "assisted"}>
                Draft &amp; approve
              </option>
              <option value="user_controlled" selected={control_of(@control_modes, c) == "user_controlled"}>
                I write their turns
              </option>
            </select>
          </form>
        </div>
        <%!-- Bring somebody else in. A scene opens with the cast the author picked for
              it, so the rest of the campaign has to be reachable from here or the only
              way to add a latecomer is to start the scene again. `admit/3` is the same
              path an accepted introduction takes — enter, seed their context, and note
              them in the Director's brief — so a character walked in by hand and one
              the Director asked for arrive identically. --%>
        <div :if={@joinable != []} class="mt-3">
          <form id={eid(@id, "scene-add-cast")} phx-submit="add_to_scene" class="flex gap-1.5">
            <label for={eid(@id, "scene-add-select")} class="sr-only">Bring someone into the scene</label>
            <select id={eid(@id, "scene-add-select")} name="id" class="field px-2 py-1 text-[12px] flex-1 min-w-0">
              <option :for={c <- @joinable} value={c.id}><%= c.name %></option>
            </select>
            <Kit.btn kind={:ghost} size={:sm} type="submit">Bring in</Kit.btn>
          </form>
          <p class="text-[11px] leading-relaxed dim mt-1.5">
            They enter at this beat, knowing only what the scene has shown since.
          </p>
        </div>

        <%!-- The walk-ons this story invented and never wrote. `SceneControl` refuses
              a non-`:full` character, so they cannot be options in the picker above —
              the honest offer is *write them, then bring them in*, which is one press
              and the same `play.intro` an accepted Director introduction takes. Without
              this, a side character a scene actually calls for was unreachable from
              play: the only route was leaving the scene for the campaign's cast tab. --%>
        <div :if={@writable != []} class="mt-3">
          <div class="lbl dim mb-1.5">Not written yet</div>
          <div class="flex flex-col gap-1.5">
            <div :for={c <- @writable} class="flex items-center justify-between gap-2">
              <span class="text-[12.5px] min-w-0 truncate"><%= c.name %></span>
              <Kit.btn
                size={:sm}
                type="button"
                phx-click="write_in"
                phx-value-id={c.id}
                disabled={MapSet.member?(@writing_in, c.id)}
                class="shrink-0"
              >
                <%= if MapSet.member?(@writing_in, c.id), do: "✦ …", else: "✦ Write them in" %>
              </Kit.btn>
            </div>
          </div>
          <p class="text-[11px] leading-relaxed dim mt-1.5">
            They're written from their role and this world, then walk in at this beat.
          </p>
        </div>

        <p
          :if={@joinable == [] and @writable == [] and @roster != []}
          class="text-[11px] leading-relaxed dim mt-3"
        >
          Everyone this campaign has written is already here.
        </p>

        <Kit.btn kind={:ghost} size={:sm} type="button" phx-click="find_mentions" class="mt-2">
          Find mentioned characters
        </Kit.btn>
      </div>

      <div :if={@panel == :intros and @introductions != []} class="row px-4 py-3">
        <div class="lbl dim mb-2">The Director suggests</div>
        <div :for={i <- @introductions} class="flex items-center gap-2.5 py-1.5">
          <div class="min-w-0 flex-1">
            <div class="text-[13px] font-semibold"><%= i.name %></div>
            <div :if={i.reason not in [nil, ""]} class="text-[11px] dim"><%= i.reason %></div>
          </div>
          <Kit.btn
            :if={i.resolution.status == :ready}
            kind={:primary}
            size={:sm}
            phx-click="intro_admit"
            phx-value-name={i.name}
          >
            Admit
          </Kit.btn>
          <Kit.btn
            :if={i.resolution.status != :ready}
            kind={:primary}
            size={:sm}
            phx-click="intro_generate"
            phx-value-name={i.name}
          >
            ✦ Write &amp; admit
          </Kit.btn>
          <Kit.btn kind={:pen} size={:sm} phx-click="intro_edit" phx-value-name={i.name}>Edit</Kit.btn>
          <Kit.btn kind={:pen} size={:sm} phx-click="intro_dismiss" phx-value-name={i.name}>
            Not now
          </Kit.btn>
        </div>
      </div>
    </Kit.frame>
    """
  end

  # ── Transcript blocks ─────────────────────────────────────────────────────────

  attr(:id, :string, required: true, doc: "already namespaced by the screen prefix")
  attr(:block, :map, required: true)
  attr(:register, :atom, required: true)
  attr(:cast, :any, required: true)
  attr(:voices, :map, required: true)
  attr(:beat_rule, :any, default: nil)
  attr(:editable, :boolean, default: false)
  attr(:editing, :string, default: nil)
  attr(:control, :string, default: nil)

  defp turn_block(assigns) do
    assigns =
      assigns
      |> assign(:colour, Voice.of(assigns.voices, assigns.block.character))
      |> assign(:name, name_of(assigns.cast, assigns.block.character))

    ~H"""
    <div id={@id} class="turn-block">
      <Kit.beat_rule :if={@beat_rule} beat={@beat_rule} />

      <%!-- An event with no packet — a world beat, an entrance — is nobody's turn,
            so it carries no attribution and no editorial controls. --%>
      <div :if={@block.type == :event} class="py-1">
        <div :for={m <- @block.msgs}><%= Transcript.render_move(m, @cast, @register, @voices) %></div>
      </div>

      <div
        :if={@block.type == :turn}
        class={["mb-4", @register == :stage && "pl-3"]}
        style={@register == :stage && "box-shadow:inset 2px 0 0 #{@colour}"}
      >
        <div class="flex items-center gap-2 mb-1.5 flex-wrap">
          <%!-- The name is the way in to who this is — the same control the reading
                screen has, so a character somebody meets mid-scene can be asked about
                without leaving the scene. --%>
          <button
            type="button"
            class={["ttl font-semibold text-left", @register == :stage && "text-[14px]", @register == :page && "text-[13px] tracking-[.06em]"]}
            style={"color:#{@colour}"}
            phx-click="who"
            phx-value-id={@block.character}
            aria-label={"About #{@name}"}
          >
            <%= if @register == :page, do: String.upcase(@name), else: @name %>
          </button>
          <Kit.pill :if={@register == :stage and @control} class="dim">
            <%= control_label(@control) %>
          </Kit.pill>
        </div>

        <div :for={m <- Transcript.ordered_moves(@block.msgs)}>
          <%= Transcript.render_move(m, @cast, @register, @voices) %>
        </div>

        <div :if={@editable and @editing != @block.packet_id} class="turn-controls flex flex-wrap gap-0.5 mt-2 -ml-1">
          <Kit.btn kind={:pen} phx-click="reroll_turn" phx-value-beat={@block.beat} phx-value-character={@block.character}>
            Reroll
          </Kit.btn>
          <Kit.btn kind={:pen} phx-click="edit_turn" phx-value-packet={@block.packet_id}>Edit</Kit.btn>
          <Kit.btn
            kind={:pen}
            phx-click="delete_turn"
            phx-value-beat={@block.beat}
            phx-value-character={@block.character}
            phx-value-packet={@block.packet_id}
            data-confirm="Remove this turn?"
          >
            Delete
          </Kit.btn>
        </div>

        <form
          :if={@editable and @editing == @block.packet_id}
          id={"edit-#{@block.packet_id}"}
          phx-submit="save_edit"
          class="turn-edit mt-2"
        >
          <input type="hidden" name="beat" value={@block.beat} />
          <input type="hidden" name="character" value={@block.character} />
          <input type="hidden" name="packet" value={@block.packet_id} />
          <label for={"edit-text-#{@block.packet_id}"} class="sr-only">Edit this turn</label>
          <textarea
            id={"edit-text-#{@block.packet_id}"}
            name="text"
            rows="3"
            class="field say-input px-3 py-2 text-[14px] w-full"
          ><%= turn_text(@block, @cast) %></textarea>
          <%!-- The question `Edit.edit/6` has always asked and nothing ever put to
                anybody. Serial generation means a changed line may have changed what
                *later* turns conditioned on, and only the author knows whether it did:
                a typo didn't, a reversal did. Answering "it changed what happened"
                forks at this beat, so the original timeline survives intact and the
                stale tail is discarded on the branch rather than left standing under a
                turn that no longer says what it said. --%>
          <div class="mt-2">
            <label class="flex items-start gap-2 cursor-pointer">
              <input
                type="checkbox"
                name="invalidates"
                value="true"
                aria-label="This changes what happened"
                class="sr-only peer"
              />
              <Kit.chk class="mt-0.5" />
              <span class="text-[12px] leading-relaxed">
                This changes what happened
                <span class="dim block">
                  Branches the scene here, keeping the original — anything written after
                  this turn was written on top of it.
                </span>
              </span>
            </label>
          </div>

          <div class="flex gap-1.5 mt-1.5">
            <Kit.btn kind={:primary} size={:sm} type="submit">Save</Kit.btn>
            <Kit.btn kind={:ghost} size={:sm} type="button" phx-click="cancel_edit">Cancel</Kit.btn>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # A turn that was generated and is waiting to be taken (§A2). Rendered through the
  # *same* `render_move/4` the transcript uses, so what is approved reads exactly as
  # it will read once committed — a second renderer here would drift, and the whole
  # point of approving is seeing the thing itself.
  attr(:draft, :map, required: true)
  attr(:cast, :any, required: true)
  attr(:voices, :map, required: true)
  attr(:register, :atom, required: true)
  attr(:editing, :boolean, default: false)

  defp draft_card(assigns) do
    assigns =
      assigns
      |> assign(:colour, Voice.of(assigns.voices, assigns.draft.row.character_id))
      |> assign(:name, name_of(assigns.cast, assigns.draft.row.character_id))

    ~H"""
    <Kit.sheet class="mb-3" style={"border-color:#{@colour}"}>
      <Kit.row class="px-3.5 py-2 flex items-center gap-2 flex-wrap" style="background:var(--b2)">
        <span class="ttl text-[14px] font-semibold" style={"color:#{@colour}"}><%= @name %></span>
        <Kit.pill class="dim">Waiting on you</Kit.pill>
        <span class="flex-1"></span>
        <span class="lbl dim">beat <%= @draft.row.beat %></span>
      </Kit.row>

      <div :if={not @editing} class="px-3.5 py-2.5">
        <div :for={m <- draft_moves(@draft, @draft.row.character_id)}>
          <%= Transcript.render_move(m, @cast, @register, @voices) %>
        </div>
      </div>

      <%!-- A turn that is nearly right is the ordinary case, and the whole argument for
            approving one instead of letting it commit. Same editor format as the
            transcript's, so correcting a draft and correcting a committed turn are the
            same skill. --%>
      <form
        :if={@editing}
        id={"draft-edit-#{@draft.row.id}"}
        phx-submit="save_draft_edit"
        class="px-3.5 py-2.5"
      >
        <%!-- `draft_id`, not `id`: LiveView reserves that name for the form's own DOM
              id and warns that the value would be remapped underneath us. --%>
        <input type="hidden" name="draft_id" value={@draft.row.id} />
        <label for={"draft-text-#{@draft.row.id}"} class="sr-only">Edit this turn</label>
        <textarea
          id={"draft-text-#{@draft.row.id}"}
          name="text"
          rows="4"
          class="field say-input px-3 py-2 text-[14px] w-full"
        ><%= draft_text(@draft, @cast) %></textarea>
        <div class="flex gap-1.5 mt-1.5">
          <Kit.btn kind={:primary} size={:sm} type="submit">Save</Kit.btn>
          <Kit.btn kind={:ghost} size={:sm} type="button" phx-click="cancel_draft_edit">
            Cancel
          </Kit.btn>
        </div>
      </form>

      <Kit.row :if={not @editing} class="px-3.5 py-2.5 flex items-center gap-1.5 flex-wrap">
        <Kit.btn kind={:primary} size={:sm} type="button"
                 phx-click="accept_draft" phx-value-id={@draft.row.id}>
          Take it
        </Kit.btn>
        <Kit.btn kind={:ghost} size={:sm} type="button"
                 phx-click="edit_draft" phx-value-id={@draft.row.id}>
          Edit first
        </Kit.btn>
        <%!-- Discarding is a **pass**, not a deletion — the slot gives up its turn and
              the beat walks on, which is what the backend does with it. Saying
              "discard" alone would read as "try again". --%>
        <Kit.btn kind={:pen} size={:sm} type="button"
                 phx-click="discard_draft" phx-value-id={@draft.row.id}>
          Discard — they pass
        </Kit.btn>
      </Kit.row>
    </Kit.sheet>
    """
  end

  # A draft holds `TurnPacket.Move` structs; the transcript renders committed *events*.
  # Mapping one onto the other is what lets both go through a single renderer.
  defp draft_moves(%{packet: %{moves: moves}}, character_id) do
    moves
    |> Enum.sort_by(& &1.seq)
    |> Enum.map(fn m ->
      case m.type do
        :speech ->
          %{
            kind: "SpeechUttered",
            payload: %{
              content: m.content,
              audibility: m.audibility,
              addressed_to: m.addressed_to
            }
          }

        :thought ->
          %{kind: "ThoughtOccurred", payload: %{content: m.content, character_id: character_id}}

        _ ->
          %{kind: "ActionTaken", payload: %{content: m.content}}
      end
    end)
  end

  defp draft_moves(_draft, _character_id), do: []

  defp control_label("assisted"), do: "Draft & approve"
  defp control_label("user_controlled"), do: "Yours"
  defp control_label(_), do: "Automated"

  defp empty_headline(:omniscient), do: "Nobody has moved yet."
  defp empty_headline(_), do: "Nothing has happened yet."

  # The viewpoint's hue: a character's voice, or the register's plain foreground for
  # the omniscient author (per the kit's perspective-control spec).
  defp viewer_colour(:omniscient, _voices), do: Voice.neutral()
  defp viewer_colour({:character, id}, voices), do: Voice.of(voices, id)

  # One debug-timeline entry, stacked (never a horizontal table — unreadable on mobile):
  # a wrapping meta line, then the detail below it. Entries are separated by a rule via
  # `.dbg-entry`'s bottom border.
  defp render_debug_entry(%{kind: :event} = assigns) do
    ~H"""
    <div class="dbg-meta">
      <span class="dbg-time"><%= at_label(@at_ms) %></span>
      <span class="dbg-tag ev">event</span>
      <span class="faint">#<%= @seq %> · b<%= @beat %></span>
      <strong><%= @label %></strong>
    </div>
    <pre class="dbg-detail"><%= @detail %></pre>
    """
  end

  defp render_debug_entry(%{kind: :trace} = assigns) do
    ~H"""
    <details>
      <summary>
        <span class="dbg-time"><%= at_label(@at_ms) %></span>
        <span class={"dbg-tag llm #{if @is_error, do: "err"}"}>LLM</span>
        <strong><%= @subject %></strong>
        <span class="faint"><%= @model %> · <%= @outcome %></span>
      </summary>
      <div class="dbg-kv faint">params: <%= @params %></div>
      <div class="dbg-label">request</div>
      <pre class="dbg-detail"><%= @request %></pre>
      <div class="dbg-label">response</div>
      <pre class="dbg-detail"><%= @response %></pre>
    </details>
    """
  end

  defp render_debug_entry(%{kind: :error} = assigns) do
    ~H"""
    <div class="dbg-meta">
      <span class="dbg-time"><%= at_label(@at_ms) %></span>
      <span class="dbg-tag err">error</span>
      <strong><%= @subject %></strong>
      <span :if={@beat} class="faint">b<%= @beat %></span>
    </div>
    <div class="dbg-detail err"><%= @detail %></div>
    """
  end
end

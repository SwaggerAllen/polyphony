defmodule PolyphonyWeb.Screens.ArcReview do
  @moduledoc """
  Arc review, as markup.

  The gate between scenes: what a scene decided about the people in it, proposed rather
  than applied. Accepting is a deliberate act and refusing one is how you write the
  person who didn't go along with it — the review is a feature of the fiction, not a
  safety rail.

  A group change fans out into one proposal against the template and one per current
  member, and the screen **collapses that fan-out into a single card** — a group of
  twelve would otherwise flood the queue from a change nobody made twelve times.

  ## The action sets (STR-62)

  Which set a card gets is a claim about what has already happened. *True / Not yet*
  for a line that gave **in play** — she already acted, so refusing keeps it
  scene-local rather than un-playing it, and there is nothing to edit. *True / Edit /
  No* for everything else, including a release the Director proposes past its written
  condition (shown struck through and marked unmet) and a world fact however wide its
  audience: **who knows is an audience, not an action**, so narrowing one is the
  control on the card rather than a way of refusing it.

  ## Authoring (STR-62)

  The author can propose too — same card, same accept-or-refuse, same place in the
  history. The *add an entry* row sits last in the list of proposals wherever they
  are shown, and the form opens in place beneath them.

  ## The card is shared

  `proposal_card/1` is public because reviewing happens **in every place you cast
  somebody**: this screen, a cast row on scene setup, and the intros panel in play.
  `:events` prefixes its actions for a host that already owns an `edit` of its own.
  """
  use PolyphonyWeb, :html

  alias Polyphony.Authoring.ArcEntry
  alias PolyphonyWeb.{Kit, Layouts, Voice}

  # "" in the app; a distinct prefix per storybook variation, which all render together.
  defp eid("", name), do: name
  defp eid(nil, name), do: name
  defp eid(prefix, name), do: "#{prefix}-#{name}"

  attr(:id, :string, default: "", doc: "prefix for every element id — see eid/2")
  attr(:campaign_id, :string, required: true)
  attr(:campaign_name, :string, default: "")
  attr(:cast, :any, required: true, doc: "%Cast{} — names are display, ids are the key")
  attr(:groups, :list, default: [])
  attr(:world, :list, default: [], doc: "world-arc proposals; global facts reach everywhere")
  attr(:per_character, :any, default: %{}, doc: "character_id => their pending proposals")
  attr(:tab, :any, default: nil)
  attr(:drawer, :any, default: nil)
  attr(:editing, :any, default: nil, doc: "the proposal being corrected before it is taken")

  attr(:authoring, :any,
    default: nil,
    doc: "the authoring form's whole state, built by the LiveView — nil when closed"
  )

  attr(:current_user, :map, default: nil)

  def screen(assigns) do
    ~H"""
    <Kit.frame class="flex flex-col min-h-[100dvh]">
      <Kit.header
        title="What play made of them"
        eyebrow={@campaign_name}
        subtitle={pending_line(assigns)}
        back={~p"/campaigns/#{@campaign_id}"}
        back_label="Back to the campaign"
      >
        <:actions>
          <Kit.info label="arc review" phx-click="drawer" />
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <%!-- A tab per subject: reviewing is per-person work, and a flat list makes you
            re-orient on every card. A tab with nothing pending still shows, at zero,
            so its absence never reads as "not extracted yet". --%>
      <Kit.tabs :if={@cast != []}>
        <:tab
          :for={c <- @cast}
          patch={~p"/arc/#{@campaign_id}?#{[tab: c.id]}"}
          on={@tab == c.id}
        >
          <%= c.name %> <span class="dim"><%= length(@per_character[c.id] || []) %></span>
        </:tab>
        <:tab patch={~p"/arc/#{@campaign_id}?#{[tab: "world"]}"} on={@tab == "world"}>
          <%= @campaign_name %> <span class="dim"><%= length(@world) %></span>
        </:tab>
      </Kit.tabs>

      <div class="flex-1 min-h-0 overflow-y-auto">
        <.drawer :if={@drawer} />

        <Kit.sheet class="m-4">
          <.proposal_card
            :for={e <- visible(assigns)}
            entry={e}
            was={was(e, subject_sheet(assigns))}
            editing={@editing}
            world={@tab == "world"}
          />

          <div
            :if={visible(assigns) != []}
            class="px-4 py-3 flex items-center justify-between gap-2"
            style="background:var(--b2)"
          >
            <span class="text-[12.5px] dim"><%= subject_name(assigns) %>, all at once</span>
            <Kit.btn
              size={:sm}
              type="button"
              phx-click="accept_all"
              phx-value-subject={subject_id(assigns)}
            >
              Accept all <%= length(visible(assigns)) %>
            </Kit.btn>
          </div>

          <%!-- Last in the list wherever proposals are shown: the extraction proposes
                what the scene concluded, never what it missed, and the person best
                placed to notice a miss is the one reading the things it caught. It
                opens **in place**, under the proposals — the form is where you tapped
                rather than somewhere the list used to be. --%>
          <div :if={is_nil(@authoring)} class="row px-4 py-2.5">
            <button
              type="button"
              class="field px-3 py-2 text-[13px] dim w-full text-left"
              phx-click="authoring_open"
            >
              <%= if @tab == "world",
                do: "✦ Something else changed about the world…",
                else: "✦ Something else changed about #{subject_name(assigns)}…" %>
            </button>
          </div>

          <.authoring_form :if={@authoring} id={@id} authoring={@authoring} />
        </Kit.sheet>

        <Kit.empty
          :if={is_nil(@authoring) and visible(assigns) == [] and @groups == []}
          headline={empty_headline(assigns)}
          class="m-4"
        >
          When a scene closes, whatever it changed about your people and your world turns
          up here first.
        </Kit.empty>

        <.group_card :for={g <- @groups} group={g} cast={@cast} editing={@editing} />
      </div>
    </Kit.frame>
    """
  end

  # ── Components ────────────────────────────────────────────────────────────────

  @doc """
  One proposal: what it would change, what it changes it *from*, and what in the
  scene caused it. The last part is what the design says makes accepting quick.

  Public because it is the same card in every place proposals are reviewed — this
  screen, and a cast row's expansion on the campaign screen (STR-62). Expanding a
  row shows the real cards, not summaries of them.
  """
  attr(:entry, :map, required: true)
  attr(:was, :string, default: nil)
  attr(:editing, :any, default: nil)
  attr(:world, :boolean, default: false)

  attr(:events, :string,
    default: "",
    doc:
      "prefix for the card's events — a host that already owns an `edit`/`cancel_edit` " <>
        "of its own names them apart rather than the card renaming its own actions"
  )

  def proposal_card(assigns) do
    ~H"""
    <div class="row px-4 py-3">
      <div class="flex items-center justify-between gap-2 mb-2">
        <span class="lbl dim"><%= heading(@entry) %></span>
        <span class="flex items-center gap-1.5">
          <%!-- Who says so. An authored card carries its author where an extracted
                one carries the engine, and is otherwise identical. --%>
          <Kit.pill :if={present?(author_of(@entry))} colour="var(--lamp)">
            <%= author_of(@entry) %>
          </Kit.pill>
          <Kit.pill :if={@world and scope_of(@entry) == "local"} colour="var(--lamp)">
            Known here first
          </Kit.pill>
        </span>
      </div>

      <%!-- What it changes *from*, struck through. Only a revision has one — a
            discovery adds rather than supersedes, and struck-through text there would
            be a lie about what's happening. --%>
      <p :if={@was} class="text-[12.5px] leading-relaxed dim was mb-2"><%= @was %></p>

      <form :if={@editing == @entry.id} id={"edit-#{@entry.id}"} phx-submit={@events <> "save_edit"}>
        <input type="hidden" name="entry_id" value={@entry.id} />
        <label for={"stmt-#{@entry.id}"} class="sr-only">The change</label>
        <textarea
          id={"stmt-#{@entry.id}"}
          name="statement"
          rows="3"
          class="field px-3 py-2.5 text-[13.5px] leading-relaxed w-full"
        ><%= @entry.statement %></textarea>
        <div :if={@world} class="mt-2">
          <label for={"scope-#{@entry.id}"} class="lbl dim">How far it reaches</label>
          <select
            id={"scope-#{@entry.id}"}
            name="scope"
            class="field px-3 py-2 text-[13px] w-full mt-1.5"
          >
            <option value="global" selected={scope_of(@entry) != "local"}>Everywhere</option>
            <option value="local" selected={scope_of(@entry) == "local"}>Where it happened</option>
          </select>
        </div>
        <div class="flex gap-1.5 mt-2">
          <Kit.btn kind={:primary} size={:sm} type="submit">Save it</Kit.btn>
          <Kit.btn size={:sm} type="button" phx-click={@events <> "cancel_edit"}>Cancel</Kit.btn>
        </div>
      </form>

      <div :if={@editing != @entry.id}>
        <%!-- The Director proposing past a written condition shows that condition,
              struck through and marked unmet — the author needs to see their own rule
              being gone past rather than silently reinterpreted. --%>
        <div :if={past_condition?(@entry)} class="mb-2">
          <div class="lbl dim mb-1">Until · not met</div>
          <p class="text-[12px] leading-relaxed dim was"><%= line_condition_of(@entry) %></p>
        </div>

        <%!-- On a release the line that gave leads and the after-state follows, because
              *what broke* is the decision and *what she's like now* is its consequence. --%>
        <Kit.marked mark={:prop} class="mb-2.5">
          <p :if={present?(released_topic_of(@entry))} class="text-[14px] leading-relaxed mb-1">
            <%= released_topic_of(@entry) %> — it broke.
          </p>
          <p class={[
            "leading-relaxed",
            if(present?(released_topic_of(@entry)), do: "text-[12.5px] dim", else: "text-[14px]")
          ]}>
            <%= @entry.statement %>
          </p>
        </Kit.marked>

        <div :if={present?(@entry.reason)}>
          <div class="lbl dim mb-1">Because</div>
          <p class="text-[12.5px] leading-relaxed dim mb-2.5"><%= @entry.reason %></p>
        </div>

        <%!-- A world fact also has to say who comes to know it — the audience picker
              doing the same job it does on a secret. Proposed as everyone's, accepting
              means anyone off-screen is told the next time they turn up. --%>
        <%!-- Who knows is an **audience**, not an action. Common knowledge is one of
              its values rather than a refusal that means it — so narrowing is the same
              control on the card that the authoring form uses, and the card keeps the
              ordinary actions. --%>
        <div
          :if={@world}
          class="mb-2.5 pt-2.5"
          style="border-top:1px solid var(--rule)"
        >
          <div class="lbl dim mb-1.5">Who knows</div>
          <Kit.seg>
            <:option
              on={concealed?(@entry)}
              rest={%{
                "phx-click" => @events <> "set_audience",
                "phx-value-id" => @entry.id,
                "phx-value-who" => "there"
              }}
            >
              Only who was there
            </:option>
            <:option
              on={not concealed?(@entry)}
              rest={%{
                "phx-click" => @events <> "set_audience",
                "phx-value-id" => @entry.id,
                "phx-value-who" => "everyone"
              }}
            >
              Everyone
            </:option>
          </Kit.seg>
          <p :if={common_knowledge?(@entry, @world)} class="text-[11px] leading-relaxed dim mt-1.5">
            Common knowledge. Anyone off-screen is told this the next time they turn up, and
            reacts to it on the page rather than arriving already used to it.
          </p>
        </div>

        <%!-- Two action sets, and which one a card gets is a claim about what has
              already happened. True / Not yet for a line that gave in play — you cannot
              un-play it, so there is nothing to edit. True / Edit / No for everything
              else, world facts included: narrowing a world fact's audience is the
              control above, so refusing one still means refusing it. --%>
        <div class="flex flex-wrap gap-1.5">
          <Kit.btn
            kind={:primary}
            size={:sm}
            type="button"
            phx-click={@events <> "accept"}
            phx-value-id={@entry.id}
          >
            True
          </Kit.btn>
          <%= if action_set(@entry) == :not_yet do %>
            <Kit.btn size={:sm} type="button" phx-click={@events <> "reject"} phx-value-id={@entry.id}>
              Not yet
            </Kit.btn>
          <% else %>
            <Kit.btn size={:sm} type="button" phx-click={@events <> "edit"} phx-value-id={@entry.id}>
              Edit
            </Kit.btn>
            <Kit.btn size={:sm} type="button" phx-click={@events <> "reject"} phx-value-id={@entry.id}>
              No
            </Kit.btn>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # A group's fan-out, collapsed. One card, one fast path, expandable when it matters
  # — a group of twelve would otherwise flood the queue.
  attr(:group, :map, required: true)
  attr(:cast, :list, required: true)
  attr(:editing, :any, default: nil)

  defp group_card(assigns) do
    ~H"""
    <Kit.sheet class="m-4">
      <Kit.row class="px-4 py-3" style="background:var(--b2)">
        <div class="flex items-center gap-2.5">
          <span class="av" style="background:var(--secret)"></span>
          <div class="min-w-0 flex-1">
            <div class="ttl text-[15px] font-semibold"><%= @group.name %></div>
            <div class="lbl dim"><%= fan_out_line(@group.counts) %></div>
          </div>
        </div>
      </Kit.row>

      <.proposal_card :for={e <- @group.pending.group} entry={e} editing={@editing} />

      <%!-- Expanded, per member. This is where dissent lives: accept the group's
            change, refuse one person's, and you've written the one who didn't go along
            with it — a story beat you'd otherwise have to author by hand. --%>
      <details :if={@group.pending.members != []}>
        <summary class="row px-4 py-2.5 flex items-center justify-between gap-2 cursor-pointer list-none">
          <span class="text-[12.5px] dim">Everyone in it changed too</span>
          <span class="dim text-[14px]">⌄</span>
        </summary>
        <div :for={{member_id, rows} <- @group.pending.members}>
          <Kit.row class="px-4 py-2 flex items-center gap-2.5" style="background:var(--b2)">
            <span class="av" style={"background:#{member_colour(@cast, member_id)}"}></span>
            <span class="text-[13px] font-semibold flex-1 min-w-0 truncate">
              <%= member_name(@cast, member_id) %>
            </span>
          </Kit.row>
          <.proposal_card :for={e <- rows} entry={e} editing={@editing} />
        </div>
      </details>

      <div class="px-4 py-3" style="background:var(--b2)">
        <Kit.btn
          kind={:primary}
          type="button"
          class="w-full justify-center"
          phx-click="accept_group"
          phx-value-id={@group.id}
        >
          True for all <%= @group.counts.group + @group.counts.members %>
        </Kit.btn>
      </div>
    </Kit.sheet>
    """
  end

  # ── Authoring (STR-62) ────────────────────────────────────────────────────────
  #
  # One form whose shape follows what is being changed — one value, a list, a line,
  # a direction, or the world. The LiveView owns every value in `@authoring`; the
  # markup only says what each shape looks like, which is how the storybook can show
  # all of them without a socket.

  attr(:id, :string, default: "")
  attr(:authoring, :map, required: true)

  defp authoring_form(assigns) do
    ~H"""
    <div class="row">
      <form id={eid(@id, "authoring")} phx-change="authoring_change" phx-submit="authoring_propose">
        <div class="px-4 py-3 flex items-center gap-2" style="background:var(--b2)">
          <span class="av" style={"background:#{@authoring.colour}"}></span>
          <span class="text-[13px] font-semibold flex-1 min-w-0 truncate">
            <%= @authoring.subject_name %>
          </span>
          <%!-- What changes: the same switchable pill the perspective control uses. --%>
          <Kit.viewas_select
            id={eid(@id, "authoring-kind")}
            label="What changes"
            name="kind"
            colour="var(--bcm)"
          >
            <option
              :for={{value, label} <- kinds(@authoring)}
              value={value}
              selected={@authoring.kind == value}
            >
              <%= label %>
            </option>
          </Kit.viewas_select>
          <button type="button" class="dim text-[17px] leading-none" phx-click="authoring_cancel">
            <span class="sr-only">Close</span>×
          </button>
        </div>

        <div class="px-4 py-3">
          <%!-- Which one has to be answerable before what about it, so list shapes
                lead with an operation. A line has four rather than three: satisfied
                is its own operation, because the consequence was written in advance
                and this only asks whether the condition was met. --%>
          <Kit.seg :if={ops(@authoring) != []} class="mb-2.5">
            <:option
              :for={op <- ops(@authoring)}
              on={@authoring.op == op}
              rest={op_rest(op, @authoring)}
            >
              <%= op_label(op) %>
            </:option>
          </Kit.seg>

          <.authoring_body id={@id} authoring={@authoring} />

          <div :if={show_because?(@authoring)}>
            <div class="lbl dim mb-1">Because <span class="dim">· optional</span></div>
            <label for={eid(@id, "authoring-because")} class="sr-only">Because</label>
            <input
              id={eid(@id, "authoring-because")}
              type="text"
              name="because"
              value={@authoring.because}
              placeholder="Leave empty if you just decided it"
              class="field px-3 py-2 text-[12.5px] w-full mb-3"
            />
          </div>

          <div :if={show_timing?(@authoring)}>
            <div class="lbl dim mb-1.5">When it became true</div>
            <Kit.seg class="mb-3">
              <:option
                :for={{value, label} <- timings()}
                on={@authoring.timing == value}
                rest={%{"phx-click" => "authoring_timing", "phx-value-timing" => value}}
              >
                <%= label %>
              </:option>
            </Kit.seg>
            <div :if={@authoring.timing == "scene"} class="mb-3">
              <label for={eid(@id, "authoring-scene")} class="sr-only">Which scene</label>
              <select id={eid(@id, "authoring-scene")} name="scene_id" class="field px-3 py-2 text-[13px] w-full">
                <option
                  :for={s <- @authoring.scenes}
                  value={s.id}
                  selected={@authoring.scene_id == s.id}
                >
                  <%= s.label %>
                </option>
              </select>
            </div>
          </div>

          <Kit.btn
            kind={:primary}
            type="submit"
            class="w-full justify-center"
            disabled={not proposable?(@authoring)}
          >
            Propose it
          </Kit.btn>
          <p class="text-[11px] leading-relaxed dim mt-2">
            A proposal against the sheet like any other — it joins the pending list and is
            accepted or refused there. A sheet has one way to change.
          </p>
        </div>
      </form>
    </div>
    """
  end

  # The per-shape middle of the form.
  attr(:id, :string, default: "")
  attr(:authoring, :map, required: true)

  defp authoring_body(%{authoring: %{kind: kind}} = assigns)
       when kind in ["refusal", "compulsion"] do
    ~H"""
    <div>
      <.authoring_picker
        :if={@authoring.op in ["change", "satisfied", "remove"]}
        id={@id}
        authoring={@authoring}
      />

      <div :if={@authoring.op == "satisfied"}>
        <%!-- Satisfaction shows the condition and the consequence already written for
              it, and asks only whether the condition was met. The consequence is
              editable if the moment wants something else, but it is not invented here. --%>
        <div :if={present?(@authoring.until)} class="mb-2">
          <div class="lbl dim mb-1">Until</div>
          <p class="text-[12.5px] leading-relaxed dim"><%= @authoring.until %></p>
        </div>
        <Kit.marked mark={:prop} class="mb-2.5">
          <label for={eid(@id, "authoring-consequence")} class="sr-only">And then</label>
          <textarea
            id={eid(@id, "authoring-consequence")}
            name="statement"
            rows="2"
            class="field px-3 py-2 text-[13px] leading-relaxed w-full"
            placeholder="What she does now"
          ><%= @authoring.statement %></textarea>
          <p class="text-[11.5px] leading-relaxed dim mt-1">
            Written when the line was created. Edit it if the moment wants something else.
          </p>
        </Kit.marked>
      </div>

      <div
        :if={@authoring.op in ["add", "change"]}
        class={["pl-3 mb-2.5", line_rule(@authoring.kind)]}
      >
        <label for={eid(@id, "authoring-line")} class="sr-only">The line</label>
        <input
          id={eid(@id, "authoring-line")}
          type="text"
          name="statement"
          value={@authoring.statement}
          placeholder={
            if @authoring.kind == "compulsion",
              do: "Can't stop covering for her father.",
              else: "Won't say who signed for the shipment."
          }
          class="field px-3 py-2 text-[13px] w-full mb-2"
        />
        <Kit.seg class="mb-2">
          <:option on={@authoring.never} rest={%{"phx-click" => "authoring_never", "phx-value-never" => "true"}}>
            Never
          </:option>
          <:option
            on={not @authoring.never}
            rest={%{"phx-click" => "authoring_never", "phx-value-never" => "false"}}
          >
            Not until…
          </:option>
        </Kit.seg>
        <div :if={not @authoring.never}>
          <div class="lbl dim mb-1">Until</div>
          <label for={eid(@id, "authoring-until")} class="sr-only">Until</label>
          <input
            id={eid(@id, "authoring-until")}
            type="text"
            name="until"
            value={@authoring.until}
            class="field px-3 py-2 text-[12.5px] w-full mb-2"
          />
          <div class="lbl dim mb-1">And then</div>
          <label for={eid(@id, "authoring-and-then")} class="sr-only">And then</label>
          <input
            id={eid(@id, "authoring-and-then")}
            type="text"
            name="and_then"
            value={@authoring.and_then}
            class="field px-3 py-2 text-[12.5px] w-full mb-1"
          />
          <p class="text-[11px] leading-relaxed dim mb-2">
            Written now, and she is not told it until it happens — a character who knows
            how she will break is not holding a line, she is waiting.
          </p>
        </div>
      </div>

      <p :if={@authoring.op == "remove" and @authoring.picked} class="text-[12px] leading-relaxed dim mb-3">
        It stops being part of who she is from here. It stays in her history — scenes that
        were written while she held it don't change.
      </p>
    </div>
    """
  end

  defp authoring_body(%{authoring: %{kind: "relationship"}} = assigns) do
    ~H"""
    <div>
      <div :if={@authoring.op == "add"}>
        <div class="lbl dim mb-1">Who does she know?</div>
        <label for={eid(@id, "authoring-target")} class="sr-only">Who</label>
        <input
          id={eid(@id, "authoring-target")}
          type="text"
          name="target"
          value={@authoring.target}
          class="field px-3 py-2 text-[13px] w-full mb-1"
        />
        <p :if={not @authoring.target_known and present?(@authoring.target)} class="text-[11.5px] dim mb-2.5">
          Nobody by that name yet — they'd join as a walk-on.
        </p>
        <div class="lbl dim mb-1">How does she regard him?</div>
        <label for={eid(@id, "authoring-regard")} class="sr-only">The regard</label>
        <input
          id={eid(@id, "authoring-regard")}
          type="text"
          name="statement"
          value={@authoring.statement}
          class="field px-3 py-2 text-[13px] w-full mb-3"
        />
      </div>

      <div :if={@authoring.op in ["change", "remove"]}>
        <%!-- Directions, not people: four rows for two people. Changing what she
              thinks of him must not touch what he thinks of her, and a picker listing
              names invites exactly that. --%>
        <.authoring_picker id={@id} authoring={@authoring} />
        <div :if={@authoring.op == "change" and @authoring.picked}>
          <div :if={present?(@authoring.was)} class="mb-2">
            <div class="lbl dim mb-1">Now</div>
            <p class="text-[12.5px] leading-relaxed dim was"><%= @authoring.was %></p>
          </div>
          <label for={eid(@id, "authoring-regard-change")} class="sr-only">The regard</label>
          <input
            id={eid(@id, "authoring-regard-change")}
            type="text"
            name="statement"
            value={@authoring.statement}
            class="field px-3 py-2 text-[13px] w-full mb-3"
          />
        </div>
        <p :if={@authoring.op == "remove" and @authoring.picked} class="text-[12px] leading-relaxed dim mb-3">
          She stops regarding him any particular way. What he thinks of her is untouched,
          and stays on his sheet.
        </p>
      </div>
    </div>
    """
  end

  defp authoring_body(%{authoring: %{world: true}} = assigns) do
    ~H"""
    <div>
      <.authoring_picker :if={@authoring.op in ["change", "remove"]} id={@id} authoring={@authoring} />

      <div :if={present?(@authoring.was) and @authoring.op == "change"} class="mb-2">
        <div class="lbl dim mb-1">Now</div>
        <p class="text-[12.5px] leading-relaxed dim was"><%= @authoring.was %></p>
      </div>

      <div :if={@authoring.op in ["add", "change"]} class={[@authoring.who != "everyone" && "secret pl-3", "mb-2.5"]}>
        <label for={eid(@id, "authoring-world-statement")} class="sr-only">The entry</label>
        <textarea
          id={eid(@id, "authoring-world-statement")}
          name="statement"
          rows="2"
          class="field px-3 py-2 text-[13px] leading-relaxed w-full"
          placeholder={
            if @authoring.kind == "rule",
              do: "Anyone on the quay when the bell rings twice knows what it means.",
              else: "The tide bell has been rung twice in a night."
          }
        ><%= @authoring.statement %></textarea>
      </div>

      <%!-- Every world entry carries who knows — the audience picker doing the job it
            does on a secret. The default is everyone, so narrowing is what marks it. --%>
      <div class="lbl dim mb-1">Who knows</div>
      <Kit.seg class="mb-2.5">
        <:option
          on={@authoring.who == "there"}
          rest={%{"phx-click" => "authoring_who", "phx-value-who" => "there"}}
        >
          Everyone there
        </:option>
        <:option
          on={@authoring.who == "everyone"}
          rest={%{"phx-click" => "authoring_who", "phx-value-who" => "everyone"}}
        >
          Everyone
        </:option>
        <:option
          on={@authoring.who == "pick"}
          rest={%{"phx-click" => "authoring_who", "phx-value-who" => "pick"}}
        >
          Pick…
        </:option>
      </Kit.seg>
      <p :if={@authoring.who == "everyone"} class="text-[11.5px] leading-relaxed dim mb-3">
        Common knowledge. Anyone off-screen is told this the next time they turn up, and
        reacts to it on the page rather than arriving already used to it.
      </p>
      <p :if={@authoring.who != "everyone"} class="text-[11.5px] leading-relaxed dim mb-3">
        Named to fewer than everyone — how a world keeps a secret.
      </p>
    </div>
    """
  end

  # The simple case (one value, like temperament or cover) and the list case (facts).
  defp authoring_body(assigns) do
    ~H"""
    <div>
      <.authoring_picker
        :if={@authoring.kind == "fact" and @authoring.op in ["change", "remove"]}
        id={@id}
        authoring={@authoring}
      />

      <%!-- The current value, struck through: most authored entries are revisions
            rather than replacements, and editing something you can't see is how you
            overwrite it by accident. --%>
      <div :if={present?(@authoring.was) and @authoring.op != "remove"} class="mb-2">
        <div class="lbl dim mb-1">Now</div>
        <p class="text-[12.5px] leading-relaxed dim was"><%= @authoring.was %></p>
      </div>

      <div :if={@authoring.op != "remove"}>
        <label for={eid(@id, "authoring-statement")} class="sr-only">The change</label>
        <textarea
          id={eid(@id, "authoring-statement")}
          name="statement"
          rows="2"
          class="field px-3 py-2 text-[13px] leading-relaxed w-full mb-2.5"
        ><%= @authoring.statement %></textarea>
      </div>

      <p :if={@authoring.op == "remove" and @authoring.picked} class="text-[12px] leading-relaxed dim mb-3">
        It stops being true from here. It stays in her history — scenes that were written
        while it was true don't change.
      </p>

      <%!-- A fact carries always-in-mind and an audience, and the two are orthogonal:
            she can have a secret she never thinks about. --%>
      <div :if={@authoring.kind == "fact" and @authoring.op in ["add", "change"]}>
        <div class="flex items-center gap-2 mb-2">
          <div class="min-w-0 flex-1 text-[12.5px]">Always in mind</div>
          <button type="button" phx-click="authoring_core" aria-pressed={to_string(@authoring.core)}>
            <span class="sr-only">Always in mind</span>
            <Kit.sw on={@authoring.core} colour="var(--lamp)" />
          </button>
        </div>
        <div class="flex items-center gap-2 mb-3">
          <div class="min-w-0 flex-1 text-[12.5px]">Who else knows</div>
          <Kit.pill colour={if(@authoring.audience_secret, do: "var(--secret)", else: nil)}>
            <%= @authoring.audience_label %> ▾
          </Kit.pill>
        </div>
      </div>
    </div>
    """
  end

  # Which one, before what about it: the list an operation picks from. Facts, lines
  # (with their left rules), or relationship directions.
  attr(:id, :string, default: "")
  attr(:authoring, :map, required: true)

  defp authoring_picker(assigns) do
    ~H"""
    <div class="mb-2.5">
      <div class="lbl dim mb-1"><%= @authoring.picker_label %></div>
      <div class="sheet" style="border:1px solid var(--rule);border-radius:8px;overflow:hidden">
        <button
          :for={item <- @authoring.items}
          type="button"
          class={[
            "row w-full px-3 py-2 text-[12.5px] text-left block",
            item.key != @authoring.picked && "dim",
            item[:rule] == :bound && "bound pl-3",
            item[:rule] == :compel && "compel pl-3"
          ]}
          style={item.key == @authoring.picked && "background:var(--b3)"}
          phx-click="authoring_pick"
          phx-value-key={item.key}
        >
          <span :if={item[:prefix]} class="dim"><%= item.prefix %></span>
          <%= item.label %>
          <span :if={item[:sublabel]} class="lbl dim block mt-1"><%= item.sublabel %></span>
        </button>
      </div>
    </div>
    """
  end

  defp drawer(assigns) do
    ~H"""
    <Kit.info_drawer title="About this" on_close="drawer">
      <:intro>
        A scene closed and the engine worked out what it changed. Nothing here is true
        until you say so, and nothing is lost if you leave it.
      </:intro>
      <:part colour="var(--lamp)" name="Why it holds up a new scene">
        Generation works from the sheet. An unreviewed change is a gap between who
        someone is on paper and who they've become — let it run and the Director is
        writing someone who stopped existing two scenes ago. Only the cast you're about
        to use has to be current.
      </:part>
      <:part colour="var(--ok)" name="Accept all is the fast path">
        It's meant to be used. The gate exists to keep things consistent, not to make
        you read carefully — one tap still leaves you with sheets that match your story.
      </:part>
    </Kit.info_drawer>
    """
  end

  # ── Render helpers ────────────────────────────────────────────────────────────

  defp visible(%{tab: "world", world: world}), do: world
  defp visible(%{tab: tab, per_character: per}), do: Map.get(per, tab, [])

  defp subject_id(%{tab: "world", campaign_id: id}), do: id
  defp subject_id(%{tab: tab}), do: tab

  defp subject_sheet(%{tab: "world"}), do: nil

  defp subject_sheet(%{tab: tab, cast: cast}) do
    case Enum.find(cast, &(&1.id == tab)) do
      %{sheet: sheet} -> sheet
      _ -> nil
    end
  end

  defp subject_name(%{tab: "world", campaign_name: name}), do: name

  defp subject_name(%{tab: tab, cast: cast}) do
    case Enum.find(cast, &(&1.id == tab)) do
      %{name: name} -> name
      _ -> "This subject"
    end
  end

  defp pending_line(assigns) do
    total =
      length(assigns.world) +
        (assigns.per_character |> Map.values() |> Enum.map(&length/1) |> Enum.sum())

    case total do
      0 -> "Nothing waiting"
      1 -> "1 change waiting"
      n -> "#{n} changes waiting"
    end
  end

  defp empty_headline(%{tab: "world"}), do: "The world is as you left it."
  defp empty_headline(assigns), do: "#{subject_name(assigns)} is up to date."

  defp fan_out_line(%{group: g, members: m}),
    do: "#{change_word(g)} to the group · #{m} to its people"

  defp change_word(1), do: "1 change"
  defp change_word(n), do: "#{n} changes"

  defp heading(entry) do
    ArcEntry.label(%ArcEntry{
      kind: safe_kind(entry.kind),
      sheet_field: entry.sheet_field,
      statement: entry.statement,
      operation: safe_op(get(entry, :operation)),
      condition_met: get(entry, :condition_met)
    })
  end

  # ── The action sets ───────────────────────────────────────────────────────────

  # Which one a card gets is a claim about what has already happened. A line that
  # gave in play cannot be un-played, so refusing it means *not yet* — scene-local
  # rather than never having occurred, and there is nothing to edit. Everything else
  # — including a release the Director proposes past its written condition, and a
  # world fact proposed as common knowledge — takes the ordinary True / Edit / No.
  defp action_set(entry) do
    if safe_kind(entry.kind) == :release and not past_condition?(entry),
      do: :not_yet,
      else: :ordinary
  end

  defp past_condition?(entry),
    do: safe_kind(entry.kind) == :release and get(entry, :condition_met) == false

  defp concealed?(entry), do: get(entry, :concealed) == true
  defp common_knowledge?(entry, world), do: world and not concealed?(entry)

  defp author_of(entry), do: get(entry, :author)
  defp scope_of(entry), do: get(entry, :scope)
  defp released_topic_of(entry), do: get(entry, :released_topic)
  defp line_condition_of(entry), do: get(entry, :line_condition)

  defp get(entry, key), do: Map.get(entry, key)

  defp safe_op(nil), do: nil
  defp safe_op(op) when is_atom(op), do: op

  defp safe_op(op) when is_binary(op) do
    case op do
      "add" -> :add
      "change" -> :change
      "remove" -> :remove
      "satisfied" -> :satisfied
      _ -> nil
    end
  end

  # ── Authoring helpers ─────────────────────────────────────────────────────────

  # What changes: a world has a fact or a rule and nothing else — no temperament,
  # no cover, no lines to hold.
  defp kinds(%{world: true}), do: [{"fact", "A fact"}, {"rule", "A rule"}]

  defp kinds(_),
    do: [
      {"fact", "A fact"},
      {"temperament", "Temperament"},
      {"cover", "Cover"},
      {"refusal", "A refusal"},
      {"compulsion", "A compulsion"},
      {"relationship", "A relationship"}
    ]

  # A single value has no operation to pick; a list leads with one; a line has four
  # rather than three, because satisfaction is its own operation.
  defp ops(%{world: true}), do: ["add", "change", "remove"]

  defp ops(%{kind: kind}) when kind in ["refusal", "compulsion"],
    do: ["add", "change", "satisfied", "remove"]

  defp ops(%{kind: kind}) when kind in ["fact", "relationship"], do: ["add", "change", "remove"]
  defp ops(_), do: []

  defp op_label("add"), do: "Add"
  defp op_label("change"), do: "Change"
  defp op_label("satisfied"), do: "Satisfied"
  defp op_label("remove"), do: "Remove"

  # A never has no condition, so satisfying it is offered and disabled rather than
  # absent — an operation that disappears reads as a bug.
  defp op_rest("satisfied", %{satisfied_disabled: true}), do: %{"style" => "opacity:.35"}
  defp op_rest(op, _authoring), do: %{"phx-click" => "authoring_op", "phx-value-op" => op}

  defp timings, do: [{"always", "Always true"}, {"scene", "In a scene"}, {"now", "Just now"}]

  # A world entry gets a Because like anything else. The mocks left it off both world
  # frames, which the author confirmed was an oversight rather than an argument —
  # *what in the story made this true* is the same question whoever the subject is.
  defp show_because?(%{op: "remove", picked: picked}), do: not is_nil(picked)
  defp show_because?(_), do: true

  defp show_timing?(%{world: true, kind: "fact", op: op}), do: op in ["add", "change"]
  defp show_timing?(%{world: true}), do: false
  defp show_timing?(%{kind: kind}) when kind in ["temperament", "cover"], do: true

  defp show_timing?(%{kind: kind, op: op}) when kind in ["refusal", "compulsion"],
    do: op in ["add", "change"]

  defp show_timing?(_), do: false

  defp line_rule("refusal"), do: "bound"
  defp line_rule("compulsion"), do: "compel"
  defp line_rule(_), do: nil

  defp proposable?(%{op: "remove", picked: picked}), do: not is_nil(picked)

  defp proposable?(%{op: "satisfied", picked: picked} = a),
    do: not is_nil(picked) and present?(a.statement)

  defp proposable?(%{op: "change", picked: picked, kind: kind} = a)
       when kind not in ["temperament", "cover"],
       do: not is_nil(picked) and present?(a.statement)

  defp proposable?(%{kind: "relationship", target: target} = a),
    do: present?(target) and present?(a.statement)

  defp proposable?(a), do: present?(a.statement)

  defp safe_kind("release"), do: :release
  defp safe_kind("revision"), do: :revision
  defp safe_kind(_), do: :discovery

  # What a revision replaces, read off the sheet it would replace it on.
  defp was(%{kind: "revision", sheet_field: field}, sheet)
       when is_binary(field) and field != "" and is_map(sheet) do
    case Map.get(sheet, safe_field(field)) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp was(_entry, _sheet), do: nil

  defp safe_field(field), do: String.to_existing_atom(field)

  defp member_name(cast, id) do
    case Enum.find(cast, &(&1.id == to_string(id))) do
      %{name: name} -> name
      _ -> "Someone"
    end
  end

  defp member_colour(cast, id) do
    case Enum.find(cast, &(&1.id == to_string(id))) do
      %{sheet: sheet} -> Voice.of_sheet(sheet)
      _ -> Voice.neutral()
    end
  end

  defp present?(v), do: is_binary(v) and String.trim(v) != ""
end

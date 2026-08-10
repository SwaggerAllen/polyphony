defmodule PolyphonyWeb.Screens.Browse do
  @moduledoc """
  Browse, as markup — published campaigns, and reading one.

  A published campaign is a **frozen copy**, so what a reader sees never changes under
  them while the author keeps writing. Which perspectives are on offer is the author's
  content decision, and a scene no granted perspective can reach still appears in the
  contents, marked — silently omitting it would make the story look shorter than it is.

  The report path lives here because this is where you encounter something another
  person wrote, which is the whole test for where reporting has to be reachable.
  """
  use PolyphonyWeb, :html

  alias PolyphonyCore.Publication
  alias Polyphony.Authoring.WorldBible
  alias Polyphony.Moderation.Report
  alias Polyphony.Reading.Session
  alias PolyphonyWeb.{Kit, Layouts, Transcript, Voice}

  # A prefix for every element id in this screen, the same contract `Screens.Play` states
  # in an `attr`: empty in the app, where the screen renders once, and distinct per
  # variation in the storybook, which renders all of them on one page. Seven variations
  # now draw the reader, so without this the perspective control's id repeats seven times
  # and a label points at another variation's select.
  defp eid("", name), do: name
  defp eid(nil, name), do: name
  defp eid(prefix, name), do: "#{prefix}-#{name}"

  def screen(%{story: nil, gone: reason} = assigns) when not is_nil(reason),
    do: dead_end(assigns)

  def screen(%{story: nil} = assigns), do: catalogue(assigns)
  def screen(%{scene: nil} = assigns), do: front_page(assigns)
  def screen(assigns), do: reader(assigns)

  # ── A link that doesn't lead anywhere ────────────────────────────────────────

  # In the reading register, because the reader arrived here expecting to read.
  defp dead_end(assigns) do
    ~H"""
    <Kit.frame register={:page} class="flex flex-col min-h-[100dvh]">
      <Kit.header title="Browse" subtitle="What people have shared" back={~p"/browse"}>
        <:actions>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <div class="flex-1 min-h-0 overflow-y-auto">
        <Kit.sheet class="m-4">
          <Kit.empty :if={@gone == :down} headline="This isn't available">
            It was taken down after a report. If it was yours, check your email — this covers
            your own copy too.
            <:action>
              <.link navigate={~p"/browse"} class="btn btn-gh btn-sm">Back to browse</.link>
            </:action>
          </Kit.empty>

          <Kit.empty :if={@gone == :gone} headline="Nothing here">
            This link doesn't lead anywhere any more. It may have been unpublished.
            <:action>
              <.link navigate={~p"/browse"} class="btn btn-gh btn-sm">Back to browse</.link>
            </:action>
          </Kit.empty>
        </Kit.sheet>
      </div>
    </Kit.frame>
    """
  end

  # ── The catalogue ────────────────────────────────────────────────────────────

  defp catalogue(assigns) do
    ~H"""
    <Kit.frame class="flex flex-col min-h-[100dvh]">
      <Kit.header title="Browse" subtitle="What people have shared">
        <:actions>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <Kit.tabs>
        <:tab patch={~p"/browse?#{[tab: "stories"]}"} on={@tab == "stories"}>Stories</:tab>
        <:tab patch={~p"/browse?#{[tab: "worlds"]}"} on={@tab == "worlds"}>Worlds</:tab>
      </Kit.tabs>

      <div class="flex-1 min-h-0 overflow-y-auto">
        <Kit.sheet :if={@tab == "stories"} class="m-4">
          <div :for={group <- @stories}>
            <.story_card story={group.lead} />
            <%!-- Forks group under the original: three of them share a title until
                  somebody renames one, and author is the delineator (§3.1d). --%>
            <Kit.row :if={group.forks != []} class="px-4 py-2" style="background:var(--b2)">
              <span class="lbl dim"><%= fork_line(group.forks) %></span>
            </Kit.row>
            <Kit.row :for={f <- group.forks} class="px-4 py-2.5">
              <div class="flex items-center gap-2 mb-0.5">
                <.link navigate={~p"/browse?#{[story: f.id]}"} class="text-[13px] font-semibold">
                  <%= f.name %>
                </.link>
                <Kit.pill class="shrink-0"><%= count(f.scenes, "scene", "scenes") %></Kit.pill>
              </div>
              <div class="text-[11px] dim"><%= f.author %></div>
            </Kit.row>
          </div>

          <Kit.empty :if={@stories == []} headline="Nobody's published anything yet." class="py-9">
            When they do, it'll be here — stories you can read from the inside, and worlds
            you can take.
            <:action>
              <.link navigate={~p"/library"} class="btn btn-gh btn-sm">Go to your stuff</.link>
            </:action>
          </Kit.empty>
        </Kit.sheet>

        <Kit.sheet :if={@tab == "worlds"} class="m-4">
          <Kit.row :for={w <- @worlds} class="px-4 py-3">
            <div class="flex items-center justify-between gap-2 mb-1">
              <div class="ttl text-[15px] min-w-0 truncate font-semibold"><%= w.name %></div>
              <Kit.btn size={:sm} type="button" phx-click="take_world" phx-value-id={w.id}>
                Use this world
              </Kit.btn>
            </div>
            <div class="lbl dim mb-1.5"><%= w.author %></div>
            <p :if={w.cover} class="text-[13px] leading-relaxed dim"><%= w.cover %></p>
            <span :if={w.taken > 0} class="text-[11px] dim">
              <%= count(w.taken, "person has", "people have") %> taken this
            </span>
          </Kit.row>

          <Kit.empty :if={@worlds == []} headline="No worlds shared yet." class="py-9">
            A world you take is a copy — you write your own people into it, and nothing
            you do reaches the original.
          </Kit.empty>
        </Kit.sheet>
      </div>
    </Kit.frame>
    """
  end

  attr(:story, :map, required: true)

  defp story_card(assigns) do
    ~H"""
    <Kit.row class="px-4 py-3">
      <div class="flex items-center justify-between gap-2 mb-1">
        <.link
          navigate={~p"/browse?#{[story: @story.id]}"}
          class="ttl text-[16px] min-w-0 truncate font-semibold"
        >
          <%= @story.name %>
        </.link>
        <Kit.pill class="shrink-0"><%= count(@story.scenes, "scene", "scenes") %></Kit.pill>
      </div>
      <div class="lbl dim mb-1.5"><%= @story.author %></div>
      <p :if={@story.blurb} class="text-[13px] leading-relaxed mb-2"><%= @story.blurb %></p>
      <div class="flex flex-wrap gap-1.5">
        <Kit.pill :if={@story.heads > 0} colour="var(--lamp)"><%= heads_line(@story) %></Kit.pill>
        <Kit.pill :if={@story.heads == 0}>Spectator only</Kit.pill>
        <Kit.pill :if={Publication.forkable?(@story.pub)} colour="var(--ok)">Forkable</Kit.pill>
        <Kit.pill :if={@story.copies > 0}><%= count(@story.copies, "fork", "forks") %></Kit.pill>
      </div>
    </Kit.row>
    """
  end

  # ── A story's front page ─────────────────────────────────────────────────────

  defp front_page(assigns) do
    assigns = assign_new(assigns, :diverged, fn -> nil end)

    ~H"""
    <Kit.frame register={:page} class="flex flex-col min-h-[100dvh]">
      <Kit.header title={@row.name} eyebrow="Browse" subtitle={front_meta(@row)} back={~p"/browse"}>
        <:actions>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <div class="flex-1 min-h-0 overflow-y-auto">
        <Kit.sheet class="m-4">
          <Kit.row :if={@row.blurb} class="px-5 py-4">
            <p class="text-[15px] leading-[1.7]"><%= @row.blurb %></p>
          </Kit.row>

          <%!-- Choosing how to read comes before reading — the first real decision,
                and putting it up front is what stops this feeling like settings. --%>
          <Kit.row class="px-5 py-4">
            <div class="lbl dim mb-2.5">How you can read it</div>
            <div class="flex flex-col gap-2">
              <.link
                :for={m <- Publication.modes(@pub)}
                patch={~p"/browse?#{[story: @story.id, as: Publication.to_param(m)]}"}
                class="flex items-center gap-2.5"
              >
                <Kit.dot colour={mode_colour(m, voices(@snapshot))} />
                <div class="flex-1">
                  <div class="text-[13.5px] font-semibold">
                    <%= Publication.label(m, @row.author, @names) %>
                  </div>
                  <div class="text-[11px] dim"><%= Publication.blurb(m) %></div>
                </div>
                <span :if={m == @mode} class="text-[11px] dim shrink-0">Selected</span>
              </.link>
            </div>

            <%!-- Said plainly rather than implied by an absence: an unshared head is a
                  deliberate choice, and naming the count keeps it from reading as an
                  omission. --%>
            <p :if={@row.withheld > 0} class="text-[11px] leading-relaxed dim mt-2.5">
              <%= @row.author %> hasn't shared everyone. <%= withheld_line(@row.withheld) %>
            </p>

            <Kit.empty :if={Publication.modes(@pub) == []} headline="There's no way into this one.">
              It was published without granting anyone's perspective, so there's nothing
              here to read yet.
            </Kit.empty>
          </Kit.row>

          <%!-- The campaign's own Scenes list, with one substitution: the premise
                stands in for the summary, because a summary says how it turned out. --%>
          <Kit.row :if={Session.scenes(@snapshot) != []} class="px-5 py-4">
            <div class="lbl dim mb-2.5">Scenes</div>
            <div class="flex flex-col gap-3">
              <.link
                :for={{s, i} <- Enum.with_index(Session.scenes(@snapshot), 1)}
                patch={scene_path(@story.id, s, @mode)}
                class={["block", unreachable?(@snapshot, s, @mode) && "opacity-50"]}
              >
                <div class="flex items-center justify-between gap-2 mb-1">
                  <div class="ttl text-[14.5px] min-w-0 truncate font-semibold">
                    <%= i %>. <%= Map.get(s, :title) %>
                  </div>
                  <Kit.pill class="shrink-0"><%= count(Map.get(s, :beats) || 0, "beat", "beats") %></Kit.pill>
                </div>
                <div class="lbl dim mb-1"><%= contents_cast(@snapshot, s, @mode, @names) %></div>
                <p :if={Map.get(s, :premise)} class="text-[13px] leading-relaxed dim">
                  <%= Map.get(s, :premise) %>
                </p>
              </.link>
            </div>
          </Kit.row>

          <div class="px-5 py-4">
            <%!-- The shelf promises exactly one thing — you can get back to where you
                  were — and this is where it's kept. A reader who has never opened this
                  one starts at the beginning; a reader who has picks up mid-scene. --%>
            <.link
              :if={@mode && Session.scenes(@snapshot) != []}
              patch={scene_path(@story.id, resume_scene(assigns), @mode)}
              class="btn btn-pri w-full justify-center mb-2"
            >
              <%= if resuming?(assigns), do: "Carry on reading", else: "Start reading" %>
            </.link>
            <p :if={resuming?(assigns)} class="text-[11px] leading-relaxed dim text-center mb-2">
              <%= resume_line(assigns) %>
            </p>
            <.take_actions {assigns} />
          </div>
        </Kit.sheet>

        <.report_panel :if={@reporting} {assigns} />
      </div>

      <%!-- Picking up a story that has moved on (browse.md, `continue_reading_diverged`).
            A dialog rather than a pill, because *continue reading* is a request to be
            put somewhere and this is the moment to say the obvious place has changed.
            The current version is primary and not out of deference: an abandoned line
            ends wherever it was left, so the recommendation is about which version has
            more story in it. Asked once per line, not once per visit. --%>
      <div
        :if={@diverged}
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        style="background:color-mix(in srgb,var(--b1) 72%,transparent)"
        role="dialog"
        aria-label="This story has moved on"
      >
        <div class="sheet p-4 w-full" style="max-width:420px;background:var(--b2)">
          <div class="lbl dim mb-1"><%= @row.name %></div>
          <h3 class="ttl text-[15px] mb-2 font-semibold">This story has moved on</h3>
          <p class="text-[13px] leading-relaxed mb-3">
            You're partway through a version <%= @diverged.author %> stopped writing. It ends
            where they left it — the version they're still adding to picks up from
            <strong><%= @diverged.shared_point %></strong>, where the two last agree.
          </p>
          <div class="flex flex-col gap-1.5">
            <Kit.btn kind={:primary} type="button" class="justify-center" phx-click="continue_current">
              Read the current version
            </Kit.btn>
            <%!-- Available and unstigmatised: somebody may want to finish the version
                  they started, and that is not a mistake. --%>
            <Kit.btn kind={:ghost} type="button" class="justify-center" phx-click="continue_anyway">
              Carry on where I was
            </Kit.btn>
          </div>
        </div>
      </div>
    </Kit.frame>
    """
  end

  # An action that isn't available simply isn't shown — no greyed-out buttons and no
  # "request access". Not a locked door, a different offer. The four combinations of
  # forkable? and an embedded world are the four `taking*` states.
  defp take_actions(assigns) do
    assigns = assign(assigns, :bible, embedded_bible(assigns.snapshot))

    ~H"""
    <.fork_offer :if={Publication.forkable?(@pub)} {assigns} />
    <p :if={not Publication.forkable?(@pub)} class="text-[11px] leading-relaxed dim mb-2">
      <%= shared_to_be_read(assigns) %>
    </p>
    <.world_offer :if={@bible} {assigns} />
    <div class="flex">
      <Kit.btn size={:sm} type="button" phx-click="report" class="ml-auto">Report</Kit.btn>
    </div>
    """
  end

  # The fork offer, explicit about scale because a fork is not a bookmark. The two
  # sentences in the inset are load-bearing and not to be cut for length: the first
  # answers the fear that taking something damages it, the second the opposite fear —
  # that a fork is a shared document rather than a divergent copy.
  defp fork_offer(assigns) do
    ~H"""
    <div class="mb-3">
      <div class="ttl text-[15px] mb-1.5 font-semibold">Carry this on yourself?</div>
      <p class="text-[13px] leading-relaxed dim mb-2.5">
        You'll get your own copy of everything — the world, everyone in it, and everything
        that happened to them. It picks up where this leaves off, and nothing you do touches
        the original.
      </p>
      <div class="rounded-lg p-2.5 mb-3" style="background:var(--b3)">
        <p class="text-[12px] leading-relaxed">
          <%= @row.author %>'s version stays exactly as it is. Yours becomes a different
          story from the first thing you change.
        </p>
      </div>
      <Kit.btn kind={:primary} type="button" phx-click="fork" class="w-full justify-center">
        Make it mine
      </Kit.btn>
    </div>
    """
  end

  # The world on its own, with its cover. You take the whole bible and none of the arc —
  # nothing is withheld from a world you may take, and what *is* withheld is everything
  # the campaign changed, so the copy is the world at scene one. Both halves need saying,
  # and the second is the one people get wrong: read a story about a city falling and you
  # take home the city standing. The fork pointer appears only when a fork is offered.
  defp world_offer(assigns) do
    ~H"""
    <div class="mb-3">
      <div class="lbl dim mb-1">World</div>
      <div class="ttl text-[16px] mb-1 font-semibold"><%= world_name(@bible) %></div>
      <p :if={Map.get(@bible, :cover)} class="text-[13px] leading-relaxed mb-2.5">
        <%= Map.get(@bible, :cover) %>
      </p>
      <div class="rounded-lg p-2.5 mb-3" style="background:var(--b3)">
        <p class="text-[12px] leading-relaxed dim mb-2">
          The whole bible goes in your library — everything <%= @row.author %> wrote,
          including what was kept from you while you were reading.
        </p>
        <p class="text-[12px] leading-relaxed dim">
          What doesn't come is everything the story did to it. You get
          <%= world_name(@bible) %> as it stood at the first scene.<%= if Publication.forkable?(@pub) do %>
            To have it as the story left it, fork the campaign.<% end %>
        </p>
      </div>
      <Kit.btn
        kind={:primary}
        type="button"
        phx-click="take_story_world"
        class="w-full justify-center mb-1.5"
      >
        Use this world
      </Kit.btn>
      <p class="text-[11px] leading-relaxed dim text-center">
        Or take it unread and find out in play.
      </p>
    </div>
    """
  end

  defp world_name(bible), do: Map.get(bible, :name) || "the world"

  defp report_panel(assigns) do
    assigns = assign_new(assigns, :id, fn -> "" end)

    ~H"""
    <Kit.sheet class="m-4">
      <Kit.row class="px-4 py-3" style="background:var(--b2)">
        <div class="ttl text-[15px] font-semibold">Report <%= story_name(@snapshot) %></div>
      </Kit.row>
      <form id={eid(@id, "report-form")} phx-submit="send_report">
        <label :for={r <- report_reasons()} class="px-4 py-2.5 row flex items-start gap-2.5">
          <input type="radio" name="reason" value={r.value} required class="mt-1" />
          <span class="text-[13px]"><%= r.label %></span>
        </label>
        <div class="px-4 py-3">
          <label for={eid(@id, "report-detail")} class="sr-only">Anything that would help</label>
          <textarea
            id={eid(@id, "report-detail")}
            name="detail"
            rows="3"
            class="field px-3 py-2.5 text-[13px] w-full mb-2.5"
            placeholder="Anything that would help — where in the story, and what you saw…"
          ></textarea>
          <Kit.btn kind={:primary} type="submit" class="w-full justify-center">Send it</Kit.btn>
          <p class="text-[11px] leading-relaxed dim mt-2">A person reads every one of these.</p>
          <Kit.btn size={:sm} type="button" phx-click="cancel_report" class="mt-2">
            Never mind
          </Kit.btn>
        </div>
      </form>
    </Kit.sheet>
    """
  end

  # ── Reading ──────────────────────────────────────────────────────────────────

  # The play screen with a different bottom bar: same header, same perspective
  # control, same transcript, same beat rules. Only the composer is replaced, by
  # scene navigation.
  defp reader(assigns) do
    # A share token is a credential, not a state of this screen, so it defaults away
    # rather than becoming a fifteenth thing every storybook variation has to declare.
    # The public and unlisted readers are the same markup; only how you got here differs.
    assigns =
      assigns
      |> assign_new(:token, fn -> nil end)
      |> assign_new(:id, fn -> "" end)
      |> assign_new(:info, fn -> false end)
      |> assign_new(:off_canon, fn -> nil end)
      |> assign_new(:gone_notice, fn -> nil end)

    ~H"""
    <Kit.frame register={:page} class="flex flex-col min-h-[100dvh]">
      <Kit.header
        title={Map.get(@scene, :title)}
        eyebrow={story_name(@snapshot)}
        back={front_path(@story.id, @token)}
        back_label="The front page"
      >
        <:actions>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
        <:pills>
          <div class="flex items-center gap-1.5 shrink-0 min-w-0">
            <form id={eid(@id, "mode-form")} phx-change="switch_mode">
              <Kit.viewas_select
                id={eid(@id, "mode-select")}
                label="Reading as"
                name="as"
                colour={mode_colour(@mode, voices(@snapshot))}
              >
                <optgroup label="Who can show you this">
                  <option
                    :for={m <- can_show(@snapshot, @scene, @pub, @mode)}
                    value={Publication.to_param(m)}
                    selected={m == @mode}
                  >
                    <%= Publication.label(m, nil, @names) %>
                  </option>
                </optgroup>
                <%!-- Sorted by what it can actually give you here, with the reader's
                      current perspective kept rather than removed, so nothing jumps. --%>
                <optgroup :if={cannot_show(@snapshot, @scene, @pub, @mode) != []} label="Not in this one">
                  <option
                    :for={m <- cannot_show(@snapshot, @scene, @pub, @mode)}
                    value={Publication.to_param(m)}
                    selected={m == @mode}
                  >
                    <%= Publication.label(m, nil, @names) %> — wasn't there
                  </option>
                </optgroup>
              </Kit.viewas_select>
            </form>
            <%!-- The one thing the reader adds beside the control, and the only
                  surface-specific affordance the perspective control carries anywhere
                  (play.md, *The perspective control*). The control itself is identical
                  on all three surfaces; the explanation is not, because a reader is
                  being shown a deliberately partial story and has no way to know that
                  is intended. No toast on switch — the answer lives where somebody
                  confused would idiomatically go looking. --%>
            <Kit.info label="Reading as" phx-click="reading_as_info" />
          </div>
          <%!-- The off-canon pill (browse.md, `reading_off_canon`), in the slot the
                branch selector holds on play and the hub. A reader has no branch to
                choose, so what fills it is a statement rather than a picker. Neutral,
                not gold: a reader following a link they were sent is exactly where
                somebody meant them to be — a fact, not a warning. --%>
          <Kit.viewas
            :if={@off_canon}
            tag="button"
            type="button"
            label="Not the current version"
            colour="var(--bc)"
            class="shrink-0 ml-auto"
            phx-click="off_canon_open"
          />
        </:pills>
      </Kit.header>

      <%!-- Connection. The same class-driven treatment as play's, promising less: a
            reader has nothing at risk in the first place, and reading position is a
            URL, so even a full reload returns to the same place. No retry — this is
            the transport, not the fiction. --%>
      <div
        class="hidden [.phx-loading_&]:flex items-center gap-2 px-4 py-2 row"
        style="background:color-mix(in srgb,var(--lamp) 12%,transparent)"
      >
        <Kit.dot colour="var(--lamp)" />
        <span class="text-[12.5px]">
          Reconnecting — the story is still there, the page is catching up.
        </span>
      </div>
      <div
        class="hidden [.phx-error_&]:flex items-center gap-2 px-4 py-2 row"
        style="background:color-mix(in srgb,var(--pencil) 12%,transparent)"
      >
        <Kit.dot colour="var(--pencil)" />
        <span class="text-[12.5px]">
          No connection. The text you have stays readable — the page will catch up when
          you're back.
        </span>
      </div>

      <Kit.info_drawer :if={@info} title="Reading as" on_close="close_info">
        <:intro>
          Each of these people knows different things, so the story is a different length
          depending on whose eyes you're behind.
        </:intro>
        <:part name="Switching keeps your place">
          Things will appear and disappear — that's the point, not a fault. Nothing is
          hidden from you on purpose except what that person doesn't know.
        </:part>
      </Kit.info_drawer>

      <div class="flex-1 min-h-0 overflow-y-auto px-5 pb-3">
        <%!-- Tapping the off-canon pill explains and offers the switch, which lands
              at the last point the two lines share — everything before it is
              identical, so there is no reason to make anybody read it twice. The copy
              deliberately doesn't distinguish how they got here: a link into a
              non-canonical line and a line that stopped being canonical under them
              get the same answer. --%>
        <Kit.sheet :if={@off_canon && @off_canon[:open]} class="my-3 p-4">
          <h3 class="ttl text-[15px] mb-2 font-semibold">You're reading an older version</h3>
          <p class="text-[13px] leading-relaxed mb-2">
            <%= @off_canon.author %> has since published a different version of this story.
            The two are the same up to <strong><%= @off_canon.shared_point %></strong>, and
            go different ways after it.
          </p>
          <p class="text-[12px] leading-relaxed dim mb-3">
            This one stays where it is. Nothing you've read disappears.
          </p>
          <div class="flex flex-col gap-1.5">
            <Kit.btn kind={:primary} type="button" class="justify-center" phx-click="switch_to_current">
              Read the current version
            </Kit.btn>
            <Kit.btn kind={:ghost} type="button" class="justify-center" phx-click="off_canon_close">
              Stay on this one
            </Kit.btn>
          </div>
        </Kit.sheet>

        <%!-- A link to a scene that isn't there any more (browse.md, `scene_gone`):
              the reader lands at the line's earliest change — the cursor — because
              that is the last point they can trust. Distinct from `bookmark_gone`,
              which is a whole story disappearing. --%>
        <Kit.sheet :if={@gone_notice && @gone_notice.kind == :scene} class="my-3 p-4">
          <div class="lbl dim mb-1"><%= story_name(@snapshot) %></div>
          <h3 class="ttl text-[15px] mb-2 font-semibold">That scene isn't there any more</h3>
          <p class="text-[13px] leading-relaxed mb-3">
            The link pointed at a scene <%= @gone_notice.author %> has since removed. You're
            at the last point this version was still the story you were sent.
          </p>
          <div class="flex flex-col gap-1.5">
            <Kit.btn kind={:primary} type="button" class="justify-center" phx-click="dismiss_gone">
              Carry on from here
            </Kit.btn>
          </div>
        </Kit.sheet>

        <%!-- A link to a version that was deleted (browse.md, `branch_gone`). Not a
              404: a record survives deletion — the line's id, its parent, the cut
              beat — so the reader lands on the nearest surviving ancestor, at the
              cut. No apology: deleting an abandoned line is tidying, not
              retraction. Where they land may itself be off-canon, in which case the
              pill above applies on top — the two states compose. --%>
        <Kit.sheet :if={@gone_notice && @gone_notice.kind == :branch} class="my-3 p-4">
          <div class="lbl dim mb-1"><%= story_name(@snapshot) %></div>
          <h3 class="ttl text-[15px] mb-2 font-semibold">That version was deleted</h3>
          <p class="text-[13px] leading-relaxed mb-2">
            The link named a version <%= @gone_notice.author %> has removed. This is the one
            it came from, at the point they parted.
          </p>
          <p class="text-[12px] leading-relaxed dim mb-3">
            Nothing was taken down — a line was tidied up.
          </p>
          <div class="flex flex-col gap-1.5">
            <Kit.btn kind={:primary} type="button" class="justify-center" phx-click="dismiss_gone">
              Carry on from here
            </Kit.btn>
          </div>
        </Kit.sheet>

        <Transcript.transcript
          :if={@gap == nil}
          events={@events}
          register={:page}
          names={@names}
          voices={voices(@snapshot)}
        />

        <Transcript.who
          :if={@who}
          name={Map.get(@who, :name) || "Someone"}
          pronouns={Map.get(@who, :pronouns)}
          cover={Map.get(@who, :cover)}
          colour={Voice.of_sheet(@who)}
          on_close="close_who"
        />

        <%!-- A fact about the reader's perspective, with a way out. --%>
        <Kit.empty
          :if={@gap == :not_present}
          headline={"#{who(@mode, @names)} wasn't here."}
          class="py-8"
        >
          Whatever happened at <%= Map.get(@scene, :title) %>, they found out about it the way
          you're about to — afterwards, from someone else.
        </Kit.empty>

        <%!-- A fact about the publication, with none. Shown rather than skipped. --%>
        <Kit.empty :if={@gap == :not_shared} headline="This one isn't shared." class="py-8">
          Something happened here between people <%= @row.author %> didn't publish.
          You'll pick the story back up on the other side of it.
        </Kit.empty>
      </div>

      <div class="px-4 py-3 shrink-0" style="background:var(--b2);border-top:1px solid var(--rule)">
        <div class="flex items-center justify-between gap-2">
          <span class="text-[12.5px] dim"><%= place(@snapshot, @scene) %></span>
          <.link
            :if={Session.next_scene(@snapshot, Map.get(@scene, :id))}
            patch={scene_path(@story.id, Session.next_scene(@snapshot, Map.get(@scene, :id)), @mode)}
            class="btn btn-pri btn-sm"
          >
            Next scene
          </.link>
          <span :if={is_nil(Session.next_scene(@snapshot, Map.get(@scene, :id)))} class="text-[12.5px] dim">
            That's the end of it.
          </span>
        </div>

        <%!-- Reading never hits a wall; only the actions do. Said once, plainly, at
              the point it matters. --%>
        <p :if={is_nil(@current_user)} class="text-[11px] leading-relaxed dim mt-2">
          Reading is open to anyone.
          <.link navigate={~p"/login"} class="underline">Sign in</.link>
          to keep your place, take a copy, or read it as someone in it.
        </p>
      </div>
    </Kit.frame>
    """
  end

  # ── Copy ─────────────────────────────────────────────────────────────────────

  def story_name(snapshot), do: Session.title(snapshot)
  def blurb(snapshot), do: Session.blurb(snapshot)

  def embedded_bible(snapshot) do
    case Map.get(snapshot || %{}, :bible) do
      %WorldBible{} = bible -> bible
      _ -> nil
    end
  end

  def owner_id(%{owner_id: id}) do
    case Integer.parse(to_string(id)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp front_meta(row) do
    [row.author, count(row.scenes, "scene", "scenes")]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp heads_line(%{heads: 1}), do: "One head"
  defp heads_line(%{heads: n}), do: "#{n} heads"

  defp withheld_line(1), do: "One more person is in this and you don't get their side."
  defp withheld_line(n), do: "#{n} more people are in this and you don't get their side."

  defp fork_line(forks), do: count(length(forks), "other version", "other versions")

  defp shared_to_be_read(assigns) do
    if embedded_bible(assigns.snapshot) do
      "#{assigns.row.author} has shared this to be read, not continued. " <>
        "You can still take the world and write your own people into it."
    else
      "#{assigns.row.author} has shared this to be read. There's nothing here to take with you."
    end
  end

  defp count(1, one, _many), do: "1 #{one}"
  defp count(n, _one, many), do: "#{n} #{many}"

  # A character is the same hue everywhere — in the picker, in the perspective
  # control and above their turns in the transcript. Reading it off the pinned sheet
  # is what makes that true across a snapshot the author has since edited.
  defp mode_colour(:limited, _voices), do: "var(--lamp)"
  defp mode_colour(:spectator, _voices), do: "var(--bcm)"
  defp mode_colour({:character, id}, voices), do: Voice.of(voices, to_string(id))
  defp mode_colour(_, _voices), do: "var(--bc)"

  defp who(:limited, _names), do: "Nobody shared"
  defp who(:spectator, _names), do: "The camera"
  defp who({:character, id}, names), do: Map.get(names, to_string(id), to_string(id))
  defp who(_, _), do: "This perspective"

  # Who is this — the public read, from the snapshot the reader already holds. No extra
  # authorization question: a published campaign's characters travelled with it, and the
  # card shows the cover, which is the part written to be shown.
  def who_card(snapshot, id) do
    sheet =
      Enum.find_value(Map.get(snapshot || %{}, :characters) || [], fn c ->
        if to_string(Map.get(c, :source_id)) == to_string(id), do: Map.get(c, :sheet)
      end)

    sheet && Map.put(Map.new(Map.from_struct(sheet)), :id, to_string(id))
  end

  defp voices(snapshot) do
    for c <- Map.get(snapshot || %{}, :characters) || [],
        into: %{},
        do: {to_string(Map.get(c, :source_id)), Voice.of_sheet(Map.get(c, :sheet) || %{})}
  end

  # The one link out of a story that isn't a `patch`. `Kit.header`'s chevron navigates,
  # which tears the LiveView down and mounts a fresh one, so a reader who arrived on an
  # unlisted story's share link would come back without the grant they came in with and
  # find their own story gone. Every other route through the reader stays in-process and
  # needs nothing appended — a token in a URL is a credential, and the fewer places it
  # is written the better.
  defp front_path(story_id, nil), do: ~p"/browse?#{[story: story_id]}"
  defp front_path(story_id, token), do: ~p"/browse?#{[story: story_id, t: token]}"

  defp scene_path(story_id, scene, mode) do
    params =
      [story: story_id, scene: Map.get(scene || %{}, :id)] ++
        case Publication.to_param(mode) do
          nil -> []
          as -> [as: as]
        end

    ~p"/browse?#{params}"
  end

  # Where "carry on" goes: the bookmarked scene if it's still in this snapshot,
  # otherwise the beginning. A scene that has gone (an author republished with fewer)
  # falls back rather than linking into nothing.
  defp resume_scene(assigns),
    do: bookmarked_scene(assigns) || List.first(Session.scenes(assigns.snapshot))

  # The bookmarked scene, but only if it's still in this snapshot: an author who
  # republished with fewer scenes shouldn't strand a reader on a link into nothing.
  defp bookmarked_scene(%{bookmark: %{scene_id: id}} = assigns) when not is_nil(id) do
    assigns.snapshot
    |> Session.scenes()
    |> Enum.find(&(to_string(Map.get(&1, :id)) == to_string(id)))
  end

  defp bookmarked_scene(_assigns), do: nil

  # Being bookmarked at scene 1 still counts as coming back — otherwise "carry on"
  # would only ever appear from scene 2 onwards, which is the wrong side of the line
  # for the reader who closed the tab mid-first-scene.
  defp resuming?(assigns), do: bookmarked_scene(assigns) != nil

  defp resume_line(assigns) do
    case Session.position(assigns.snapshot, Map.get(resume_scene(assigns) || %{}, :id)) do
      {i, n} -> "You were on scene #{i} of #{n}#{as_line(assigns)}."
      nil -> "Picking up where you left off#{as_line(assigns)}."
    end
  end

  # Only the leading word drops case — the label carries a name, and downcasing the
  # whole phrase turns "As Ruthe Kell" into "as ruthe kell".
  defp as_line(%{mode: nil}), do: ""

  defp as_line(assigns) do
    case Publication.label(assigns.mode, nil, assigns.names) do
      <<first::utf8, rest::binary>> -> ", " <> String.downcase(<<first::utf8>>) <> rest
      label -> ", " <> label
    end
  end

  # No granted perspective means no way in, so every scene is unreachable — and saying
  # so is the point, since the contents still list them. Without this clause a
  # publication that shares nobody crashed its own front page: `Session.gap/3` has no
  # clause for a nil mode, and `mode` is nil exactly when the publication offers nothing.
  defp unreachable?(_snapshot, _scene, nil), do: true
  defp unreachable?(snapshot, scene, mode), do: Session.gap(snapshot, scene, mode) != nil

  # In the contents, a scene the reader's perspective wasn't in says so where the cast
  # would go — the same information, in the place they're already looking.
  # Same nil-mode case as `unreachable?/3`: nothing is shared, so the cast line says
  # that rather than asking `Session.gap/3` a question it has no clause for.
  defp contents_cast(_snapshot, _scene, nil, _names), do: "Not shared"

  defp contents_cast(snapshot, scene, mode, names) do
    case Session.gap(snapshot, scene, mode) do
      :not_present ->
        "#{who(mode, names)} wasn't here"

      :not_shared ->
        "Not shared"

      nil ->
        (Map.get(scene, :cast) || [])
        |> Enum.map(&Map.get(names, to_string(&1), to_string(&1)))
        |> Enum.join(", ")
    end
  end

  defp can_show(snapshot, scene, pub, mode),
    do: Publication.modes_for_scene(pub, cast_of(snapshot, scene), mode).can

  defp cannot_show(snapshot, scene, pub, mode),
    do: Publication.modes_for_scene(pub, cast_of(snapshot, scene), mode).cannot

  defp cast_of(_snapshot, scene), do: Map.get(scene || %{}, :cast) || []

  defp place(snapshot, scene) do
    case Session.position(snapshot, Map.get(scene || %{}, :id)) do
      {i, n} -> "Scene #{i} of #{n}"
      nil -> ""
    end
  end

  defp report_reasons do
    [
      %{value: "csam", label: "Sexual content involving minors"},
      %{value: "real_person_sexual", label: "Sexual content about a real person"},
      %{value: "harassment", label: "Harassment of a real person"},
      %{value: "nonconsensual_content", label: "Content shared without consent"},
      %{value: "other", label: "Content that breaks the rules another way"}
    ]
    |> Enum.filter(&(String.to_existing_atom(&1.value) in Report.reasons()))
  end
end

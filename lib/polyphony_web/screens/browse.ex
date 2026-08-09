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
    </Kit.frame>
    """
  end

  # An action that isn't available simply isn't shown — no greyed-out buttons and no
  # "request access". Not a locked door, a different offer.
  defp take_actions(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-1.5">
      <Kit.btn :if={Publication.forkable?(@pub)} size={:sm} type="button" phx-click="fork">
        Make it mine
      </Kit.btn>
      <Kit.btn :if={embedded_bible(@snapshot)} size={:sm} type="button" phx-click="take_story_world">
        Use this world
      </Kit.btn>
      <Kit.btn size={:sm} type="button" phx-click="report" class="ml-auto">Report</Kit.btn>
    </div>
    <p :if={not Publication.forkable?(@pub)} class="text-[11px] leading-relaxed dim mt-2">
      <%= shared_to_be_read(assigns) %>
    </p>
    """
  end

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
    assigns = assigns |> assign_new(:token, fn -> nil end) |> assign_new(:id, fn -> "" end)

    ~H"""
    <Kit.frame register={:page} class="flex flex-col min-h-[100dvh]">
      <Kit.header
        title={Map.get(@scene, :title)}
        eyebrow={story_name(@snapshot)}
        back={front_path(@story.id, @token)}
        back_label="The front page"
      >
        <:actions>
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
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <div class="flex-1 min-h-0 overflow-y-auto px-5 pb-3">
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

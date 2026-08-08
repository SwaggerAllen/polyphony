defmodule PolyphonyWeb.Screens.Campaign do
  @moduledoc """
  The campaign screen, as markup — the cast, the scenes, and the levers to start one
  or publish.
  """
  use PolyphonyWeb, :html

  alias Polyphony.Authoring.{CharacterSheet, WorldBible}
  alias Polyphony.Builds
  alias Polyphony.Characters
  alias PolyphonyCore.Content.CampaignConfig
  alias Polyphony.Library
  alias Polyphony.ReadModels.BuildRun
  alias PolyphonyWeb.{Kit, Layouts, Voice}

  # The campaign's sections, in the design's order. Premise sits after Cast because
  # the pitch is written *from* the cast (`ux/README.md`), and Quick Build is
  # deliberately absent — it's a one-shot card, not a section.
  @tabs [
    {"settings", "Settings"},
    {"world", "World"},
    {"cast", "Cast"},
    {"premise", "Premise"},
    {"scenes", "Scenes"}
  ]

  @doc "The sections, in order. The LiveView validates its `tab` param against this."
  def tabs, do: @tabs

  # "" in the app; a distinct prefix per storybook variation, which all render together.
  defp eid("", name), do: name
  defp eid(nil, name), do: name
  defp eid(prefix, name), do: "#{prefix}-#{name}"

  attr(:id, :string, default: "", doc: "prefix for every element id — see eid/2")

  attr(:current_user, :map, default: nil)
  attr(:entry, :any, required: true, doc: "the campaign's library entry")
  attr(:payload, :map, default: %{}, doc: "the campaign itself, decoded")
  attr(:tab, :string, default: "settings")

  attr(:viewer, :any,
    default: :omniscient,
    doc: "`:omniscient` or `{:character, id}` — whose eyes the world tab is read through"
  )

  attr(:seen, :any,
    default: nil,
    doc:
      "the world as `@viewer` knows it. Resolved in the LiveView: a character's read expands group membership live, which is a query"
  )

  attr(:cast, :list, default: [])
  attr(:addable, :list, default: [], doc: "characters that could still be cast")
  attr(:groups, :list, default: [])
  attr(:scenes, :list, default: [])

  attr(:scene_rows, :list,
    default: [],
    doc: "the scenes as `%{id:, number:, title:, premise:, beats:, cast:}`, oldest first"
  )

  attr(:bibles, :list, default: [], doc: "worlds this campaign could attach")
  attr(:bible_id, :any, default: nil)
  attr(:bible_name, :string, default: nil)
  attr(:world, :map, default: nil, doc: "the attached world's payload, for editing")

  attr(:llm, :map, default: %{})
  attr(:global_models, :map, default: %{})
  attr(:content, :any, default: nil, doc: "the campaign's content settings")

  attr(:quick_build_open, :boolean, default: false)
  attr(:qb_seeds, :list, default: [])
  attr(:qb_world, :string, default: "")
  attr(:qb_premise, :string, default: "")

  attr(:qb_bible_id, :any,
    default: nil,
    doc: "an existing world to build on, or nil to write one"
  )

  attr(:qb_groups, :boolean, default: false)
  attr(:qb_suggest, :boolean, default: true)
  attr(:build, :any, default: nil, doc: "the running or finished quick build")

  attr(:scene_cast, :any, default: nil, doc: "nil means everyone ready; a list is a choice")
  attr(:scene_location, :string, default: "")
  attr(:scene_premise, :string, default: "")
  attr(:scene_suggesting, :boolean, default: false)

  attr(:generating, :boolean, default: false, doc: "the pending cast is being filled in")
  attr(:expanding_premise, :boolean, default: false)
  attr(:writing_in, :any, default: nil, doc: "MapSet of characters being filled in")

  attr(:published?, :boolean, default: false)
  attr(:publish_help, :boolean, default: false)
  attr(:publish_warning, :any, default: nil)
  attr(:pub_spectator, :boolean, default: false)
  attr(:pub_forkable, :boolean, default: false)
  attr(:pub_perspectives, :list, default: [])

  def screen(assigns) do
    ~H"""
    <Kit.frame class="flex flex-col min-h-[100dvh]">
      <Kit.header title={campaign_title(@payload)} subtitle={campaign_meta(assigns)}>
        <:actions>
          <%!-- The perspective control, in the same place and the same markup it has on
                every other surface with a viewpoint (`ux/README.md` calls its drift into
                three treatments the worst consistency failure of the design pass). It
                belongs here because this screen *reviews* content: the world tab is a
                read of the bible, and "what does Wren actually know of this world"
                is a question you can only answer by looking through her eyes. --%>
          <form :if={scene_ready(@cast) != []} id={eid(@id, "campaign-viewer")} phx-change="view_as">
            <Kit.viewas_select
              id={eid(@id, "campaign-viewer-select")}
              label="Viewing as"
              name="as"
              colour={viewer_colour(assigns)}
            >
              <option value="" selected={@viewer == :omniscient}>Omniscient</option>
              <option
                :for={c <- scene_ready(@cast)}
                value={c.id}
                selected={@viewer == {:character, to_string(c.id)}}
              >
                <%= char_name(c) %>
              </option>
            </Kit.viewas_select>
          </form>
          <Kit.pill><%= String.capitalize(to_string(@entry.visibility)) %></Kit.pill>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <Kit.tabs>
        <:tab
          :for={{slug, label} <- tabs()}
          patch={~p"/campaigns/#{@entry.id}?#{[tab: slug]}"}
          on={@tab == slug}
          todo={unbuilt?(assigns, slug)}
        >
          <%= label %>
        </:tab>
      </Kit.tabs>

      <div class="flex-1 min-h-0 overflow-y-auto">
        <.settings_tab :if={@tab == "settings"} {assigns} />
        <.world_tab :if={@tab == "world"} {assigns} />
        <.cast_tab :if={@tab == "cast"} {assigns} />
        <.premise_tab :if={@tab == "premise"} {assigns} />
        <.scenes_tab :if={@tab == "scenes"} {assigns} />
      </div>
    </Kit.frame>
    """
  end

  # ── Settings ──────────────────────────────────────────────────────────────────

  defp settings_tab(assigns) do
    ~H"""
    <div class="px-4 py-4 space-y-4">
      <%!-- First run only. The design's own argument for Quick Build being a card and
            not a tab: it's a one-shot, and a tab for it would be dead weight from the
            second day of a campaign's life. --%>
      <div
        :if={first_run?(assigns)}
        class="rounded-xl p-4"
        style="background:color-mix(in srgb,var(--lamp) 10%,transparent);border:1px solid var(--lamp)"
      >
        <div class="ttl text-[16px] mb-1 font-semibold">Build the whole thing at once</div>
        <p class="text-[13px] leading-relaxed dim mb-3">
          Say as much or as little as you like about the story and get a world, a cast who
          already know each other, and a pitch. You can change any of it after.
        </p>
        <Kit.btn kind={:primary} type="button" phx-click="toggle_quick_build">
          <%= if @quick_build_open, do: "Not now", else: "Try Quick Build" %>
        </Kit.btn>
      </div>

      <.quick_build :if={quick_build_open?(assigns)} {assigns} />
      <.build_card :if={@build} build={@build} />

      <form id={eid(@id, "campaign-content")} phx-change="update_content">
        <div class="lbl dim mb-2">What this campaign can contain</div>
        <Kit.sheet class="px-3.5 py-3">
          <label class="flex items-center justify-between gap-3 cursor-pointer">
            <span>
              <span class="text-[14px] font-semibold block">Adult content</span>
              <span class="text-[11px] dim">Off by default, even though you can turn it on</span>
            </span>
            <input type="checkbox" name="adult_content" value="true" checked={@content.adult_content} class="sr-only peer" />
            <Kit.sw on={@content.adult_content} />
          </label>

          <div :if={@content.adult_content} class="space-y-2.5 pt-3 mt-3" style="border-top:1px solid var(--rule)">
            <label :for={{field, label} <- content_categories()} class="flex items-center justify-between cursor-pointer">
              <span class="text-[13px]"><%= label %></span>
              <input type="checkbox" name={field} value="true" checked={Map.get(@content, String.to_existing_atom(field))} class="sr-only" />
              <Kit.sw on={Map.get(@content, String.to_existing_atom(field))} />
            </label>
          </div>

          <%!-- The ceiling stated in the author's vocabulary, not the config's — the
                copy rule that the model's words aren't the author's. --%>
          <div class="rounded-lg px-3 py-2 mt-3" style="background:var(--b3)">
            <div class="lbl dim mb-0.5">This campaign plays as</div>
            <div class="text-[13.5px] font-semibold leading-snug"><%= CampaignConfig.label(@content) %></div>
          </div>
          <p class="text-[11px] leading-relaxed dim mt-2">
            A ceiling, not a target. A character's own limits still hold underneath it, and a
            boundary in a disabled category is forced closed in play (§A5).
          </p>
        </Kit.sheet>
      </form>

      <%!-- Flat, like everything else on this screen. A settings page is read by
            scrolling it; a fold hides one of its sections behind a guess about whether
            you want it, and the guess is wrong the moment you came here to change it. --%>
      <div>
        <div class="lbl dim mb-2">Model tuning</div>
        <form id={eid(@id, "campaign-tuning")} phx-change="update_details">
          <Kit.sheet class="px-3.5 py-3 space-y-3">
            <label class="flex items-center justify-between gap-3 cursor-pointer">
              <span class="text-[13px]">Director reasoning (“thinking”)</span>
              <input type="checkbox" name="director_thinking" value="true" checked={@llm.director_thinking} class="sr-only" />
              <Kit.sw on={@llm.director_thinking} />
            </label>
            <div class="flex flex-wrap gap-3">
              <label class="flex-1 min-w-[8rem]">
                <span class="lbl dim">Director max tokens</span>
                <input type="number" name="director_max_tokens" value={@llm.director_max_tokens} min="256" step="128" phx-debounce="blur" class="field px-3 py-2 text-[13px] w-full mt-1" />
              </label>
              <label class="flex-1 min-w-[8rem]">
                <span class="lbl dim">Character max tokens</span>
                <input type="number" name="character_max_tokens" value={@llm.character_max_tokens} min="256" step="128" phx-debounce="blur" class="field px-3 py-2 text-[13px] w-full mt-1" />
              </label>
            </div>
            <label class="block">
              <span class="lbl dim">Model</span>
              <input type="text" name="model" value={@llm.model} placeholder={@global_models.workhorse || "DEEPINFRA_MODEL"} phx-debounce="blur" class="field px-3 py-2 text-[13px] w-full mt-1" />
            </label>
            <label class="block">
              <span class="lbl dim">Heavy fallback model</span>
              <input type="text" name="heavy_model" value={@llm.heavy_model} placeholder={@global_models.heavy || "DEEPINFRA_MODEL_HEAVY"} phx-debounce="blur" class="field px-3 py-2 text-[13px] w-full mt-1" />
            </label>
            <label class="block">
              <span class="lbl dim">Service tier</span>
              <select name="service_tier" class="field px-3 py-2 text-[13px] w-full mt-1">
                <option value="" selected={@llm.service_tier in [nil, ""]}>Standard</option>
                <option value="priority" selected={@llm.service_tier == "priority"}>Priority — jump the queue</option>
                <option value="flex" selected={@llm.service_tier == "flex"}>Flex — cheaper, slower</option>
              </select>
            </label>
            <p class="text-[11px] leading-relaxed dim">
              Point a campaign at a better-provisioned model, or set Priority, when the default
              is overloaded. Takes effect on the next beat.
            </p>
          </Kit.sheet>
        </form>
      </div>

      <%!-- Publishing is a decision about the campaign, and it lived on **Cast** — next
            to the people, because the perspective list is people. But the list is one
            control inside it: the panel also decides whether a spectator may read at
            all and whether the sheets travel, neither of which is about the cast. It
            belongs with the other things you decide about the campaign as a whole,
            above the three ways it ends. --%>
      <.publish_panel {assigns} />

      <.ending_panel {assigns} />
    </div>
    """
  end

  # The three ways a campaign ends. Filing, throwing away and starting over are
  # genuinely different acts, not one control with a severity dial, so they are three
  # controls with the copy that tells them apart — and none of them was reachable from
  # inside a campaign at all. The library's row menu could file and bin one; nothing
  # anywhere could restart one.
  defp ending_panel(assigns) do
    ~H"""
    <Kit.sheet>
      <Kit.row class="px-4 py-3" style="background:var(--b2)">
        <span class="lbl dim">Ending it</span>
      </Kit.row>

      <Kit.row class="px-4 py-3 flex items-center justify-between gap-3">
        <div class="min-w-0">
          <div class="text-[13px] font-semibold">Archive</div>
          <p class="text-[11px] leading-relaxed dim">
            Out of the way, on the archive shelf. Nothing is at risk and it comes back
            with one button.
          </p>
        </div>
        <Kit.btn size={:sm} type="button" phx-click="archive_campaign" class="shrink-0">
          Archive
        </Kit.btn>
      </Kit.row>

      <%!-- Deliberately *not* wrapped in a confirm: trash is on a clock and the trash
            shelf carries the one irreversible button, where the countdown is visible.
            The library row menu says the same thing in the same words. --%>
      <Kit.row class="px-4 py-3 flex items-center justify-between gap-3">
        <div class="min-w-0">
          <div class="text-[13px] font-semibold">Move to trash</div>
          <p class="text-[11px] leading-relaxed dim">
            Recoverable until it expires. The world and the cast go with it.
          </p>
        </div>
        <Kit.btn size={:sm} kind={:pen} type="button" phx-click="trash_campaign" class="shrink-0">
          Trash
        </Kit.btn>
      </Kit.row>

      <%!-- This one *does* confirm, and it is the only one here that has to: archive
            and trash are both reversible, and this is not. --%>
      <Kit.row class="px-4 py-3 flex items-center justify-between gap-3">
        <div class="min-w-0">
          <div class="text-[13px] font-semibold">Start over</div>
          <p class="text-[11px] leading-relaxed dim">
            Lets go of <%= played_line(assigns) %> and everything play raised about these
            people — the arc proposals go with the scenes that made them. The world, the
            cast and the premise are untouched.
          </p>
        </div>
        <Kit.btn
          size={:sm}
          kind={if @scenes == [], do: :off, else: :pen}
          type="button"
          phx-click="restart_campaign"
          disabled={@scenes == []}
          data-confirm={@scenes != [] && restart_confirm(assigns)}
          class="shrink-0"
        >
          Start over
        </Kit.btn>
      </Kit.row>
    </Kit.sheet>
    """
  end

  defp played_line(%{scenes: []}), do: "nothing yet"
  defp played_line(%{scenes: scenes}), do: count_label(length(scenes), "scene", "scenes")

  defp restart_confirm(assigns) do
    "Start #{campaign_label(assigns)} over? " <>
      "#{played_line(assigns)} and any arc proposals from them are let go of. " <>
      "This can't be undone."
  end

  # Names what goes with it. The arc proposals are the part an author doesn't expect to
  # lose — they were raised *by* this scene and outliving it would make them unanswerable
  # — so the confirmation says so rather than saying "this can't be undone" twice.
  defp delete_scene_confirm(scene) do
    "Delete #{scene_label(scene)}? " <>
      "#{count_label(scene.beats, "beat", "beats") || "Nothing"} played in it, and any arc " <>
      "proposals it raised, are let go of. This can't be undone."
  end

  defp campaign_label(assigns) do
    case String.trim(to_string(assigns.payload[:name] || "")) do
      "" -> "this campaign"
      name -> name
    end
  end

  defp quick_build(assigns) do
    ~H"""
    <Kit.sheet class="px-3.5 py-3">
      <form id={eid(@id, "quick-build")} phx-submit="quick_build" phx-change="sync_quick_build">
        <%!-- A world you already wrote, or a new one. Quick Build only ever invented one,
              which made it useless for the second campaign in a setting — the case where
              an author has the most to reuse and the least reason to pay for it again. --%>
        <label for={eid(@id, "qb-bible")} class="lbl dim">World</label>
        <select
          id={eid(@id, "qb-bible")}
          name="bible_id"
          class="field px-3 py-2.5 text-[13px] w-full mt-1.5"
        >
          <option value="" selected={@qb_bible_id in [nil, ""]}>✦ Write a new one</option>
          <option :for={b <- @bibles} value={b.id} selected={to_string(b.id) == to_string(@qb_bible_id)}>
            <%= bible_label_of(b) %>
          </option>
        </select>

        <%!-- Hidden rather than disabled when a world is chosen: a seed for a world that
              isn't going to be written is a field whose text is silently discarded. --%>
        <div :if={@qb_bible_id in [nil, ""]}>
          <label for={eid(@id, "qb-world")} class="lbl dim mt-3 block">World seed</label>
          <textarea
            id={eid(@id, "qb-world")}
            name="world_seed"
            rows="2"
            phx-debounce="blur"
            class="field px-3 py-2.5 text-[13px] w-full mt-1.5"
            placeholder="A rain-drowned harbour city where debts are paid in memories."
          ><%= @qb_world %></textarea>
        </div>

        <%!-- Separate from the world seed, and this is the whole point of it: written into
              one box, "a smuggler owes the harbour-master a favour" became *setting* — it
              went into the bible's canon and every later campaign in that world inherited
              it. A premise is what happens to this cast, once. Blank still generates one. --%>
        <label for={eid(@id, "qb-premise")} class="lbl dim mt-3 block">What this story is about</label>
        <textarea
          id={eid(@id, "qb-premise")}
          name="campaign_premise"
          rows="2"
          phx-debounce="blur"
          class="field px-3 py-2.5 text-[13px] w-full mt-1.5"
          placeholder="A shipment came in that isn't on any manifest, and one of them signed for it."
        ><%= @qb_premise %></textarea>
        <p class="text-[11px] leading-relaxed dim mt-1.5">
          The campaign's premise, not the world's. Leave it blank and one gets written from
          the world and the cast.
        </p>

        <div class="lbl dim mt-3 mb-1.5">Characters — one concept each</div>
        <div :for={{seed, i} <- Enum.with_index(@qb_seeds)} class="flex gap-1.5 mb-1.5">
          <input
            type="text"
            name="char_seed[]"
            value={seed}
            phx-debounce="blur"
            placeholder="a disgraced harbour-master who sold her own past"
            class="field px-3 py-2 text-[13px] flex-1"
          />
          <Kit.btn kind={:pen} type="button" phx-click="remove_seed" phx-value-index={i} disabled={length(@qb_seeds) <= 1}>
            ✕
          </Kit.btn>
        </div>
        <Kit.btn kind={:ghost} size={:sm} type="button" phx-click="add_seed">+ character</Kit.btn>

        <label class="flex items-center justify-between gap-3 mt-3 cursor-pointer">
          <span class="text-[13px]">
            Also suggest off-screen relationships
            <span class="text-[11px] dim block">Stubs mentors, rivals and family for each character</span>
          </span>
          <input type="checkbox" name="suggest_offscreen" value="true" checked={@qb_suggest} class="sr-only" />
          <Kit.sw on={@qb_suggest} />
        </label>

        <%!-- Off by default like the one above: it is a provider call, and a two-hander
              needs no order or watch. Where a world does name one, this is what makes
              belonging mean something — the cast written into a group start out holding
              its facts, secrets included, which is what `Group.seed/2` is for. --%>
        <label class="flex items-center justify-between gap-3 mt-3 cursor-pointer">
          <span class="text-[13px]">
            Also write the groups this world names
            <span class="text-[11px] dim block">
              A crew, a household, an order — and the cast in them start out knowing what
              it knows
            </span>
          </span>
          <input type="checkbox" name="groups" value="true" checked={@qb_groups} class="sr-only" />
          <Kit.sw on={@qb_groups} />
        </label>

        <div class="mt-3">
          <Kit.btn kind={:primary} type="submit" disabled={building?(assigns)}>
            <%= if building?(assigns), do: "✦ Building…", else: "✦ Quick build" %>
          </Kit.btn>
        </div>
      </form>
    </Kit.sheet>
    """
  end

  # The build's own card, drawn from the run row rather than from socket state — so it
  # is the same card whether you started the build, came back to it on a phone, or
  # reloaded the page while it ran. Outside the Quick Build form on purpose: the form is
  # first-run only, and the build that empties "first run" would take its own progress
  # off the screen with it.
  defp build_card(assigns) do
    ~H"""
    <Kit.sheet class="m-4">
      <Kit.row class="px-4 py-2.5 flex items-center justify-between gap-2" style="background:var(--b2)">
        <span class="lbl dim">Quick build</span>
        <Kit.pill :if={@build.status == "running"} colour="var(--lamp)">Running</Kit.pill>
        <Kit.pill :if={@build.status == "failed"} colour="var(--pencil)">Failed</Kit.pill>
        <Kit.pill :if={@build.status == "done"} colour="var(--ok)">Done</Kit.pill>
      </Kit.row>

      <div class="px-4 py-3">
        <Kit.bar :if={@build.status == "running"} fraction={Builds.percent(@build) / 100} />
        <div class="text-[12px] mt-1.5 leading-relaxed">
          <%= @build.label %><span :if={@build.status == "running"}>…</span>
          <span :if={@build.status == "running"} class="mono dim">
            (<%= min(@build.step + 1, @build.total) %>/<%= @build.total %>)
          </span>
        </div>
        <p :if={@build.detail} class="text-[12px] leading-relaxed dim mt-1.5"><%= @build.detail %></p>

        <%!-- The sentence that makes leaving safe. It is the whole point of the row:
              the work is not in your browser, so neither is your obligation to sit
              and watch it. --%>
        <p :if={@build.status == "running"} class="text-[11px] leading-relaxed dim mt-2">
          This runs on the server. You can leave this page — the world and everyone
          written so far are already attached to this campaign.
        </p>

        <div :if={@build.status != "running"} class="mt-2.5 flex gap-1.5">
          <%!-- A failed build has already attached its world, so the campaign is no
                longer first-run and the card that offers Quick Build is gone. Without
                this there is no way back to it — and this resumes rather than restarts,
                so it costs only what is left to do. --%>
          <Kit.btn :if={@build.status == "failed"} kind={:primary} size={:sm} type="button" phx-click="retry_build">
            ✦ Pick up where it stopped
          </Kit.btn>
          <Kit.btn size={:sm} type="button" phx-click="dismiss_build">Dismiss</Kit.btn>
        </div>
      </div>
    </Kit.sheet>
    """
  end

  # ── World ─────────────────────────────────────────────────────────────────────

  defp world_tab(assigns) do
    ~H"""
    <div>
      <%!-- `ux/polyphony-campaign.html` §04 "Attached", which had never been ported:
            the tab showed the picker and nothing whatever about the world it had
            picked. A quick-built campaign therefore read as a name in a dropdown and
            no setting at all — the world had been written, it just wasn't on screen. --%>
      <.attached_world :if={@world} {assigns} />

      <Kit.row
        :if={is_nil(@world)}
        class="px-4 py-2.5 flex items-center justify-between gap-2"
        style="background:var(--b2)"
      >
        <span class="lbl dim">The world</span>
      </Kit.row>

      <div :if={@bibles != []} class="px-4 py-3.5">
        <p class="text-[13px] leading-relaxed dim mb-3">
          The world bible grounds the setting for this campaign's scenes and its published
          snapshot. Attaching one copies it — a campaign accumulates its own world arc, so two
          campaigns can't share a bible.
        </p>
        <form id={eid(@id, "campaign-world")} phx-change="select_world">
          <label for={eid(@id, "bible-select")} class="sr-only">World</label>
          <select id={eid(@id, "bible-select")} name="bible_id" class="field px-3 py-2.5 text-[14px] w-full">
            <option value="">— none —</option>
            <option :for={b <- @bibles} value={b.id} selected={@bible_id == b.id}>
              <%= bible_label_of(b) %>
            </option>
          </select>
        </form>

        <%!-- Under the picker, not beside it: taking one you already have is the cheaper
              move and it should be the one you see first. --%>
        <Kit.btn :if={is_nil(@world)} size={:sm} type="button" phx-click="new_world" class="mt-2">
          Write a new one instead
        </Kit.btn>
      </div>

      <%!-- The picker was the whole tab, and **nothing in the app wrote a world** — so a
            campaign that skipped Quick Build faced a list it had no way to add to, and
            the only advice on offer was to go to the library, which has no world-create
            button either. --%>
      <Kit.empty :if={@bibles == [] and is_nil(@world)} headline="No world yet.">
        A campaign can play without one, but the Director has much less to go on — the
        setting, the tone and the rules all come from here.
        <:action>
          <Kit.btn kind={:primary} size={:sm} type="button" phx-click="new_world">
            Write a world
          </Kit.btn>
        </:action>
      </Kit.empty>
    </div>
    """
  end

  # The attached world, read rather than edited — enough to know what the Director is
  # working from without leaving the campaign. Every section is guarded, because a world
  # attached by hand can be a name and nothing else, and a heading over an empty space
  # reads as a bug rather than as an absence.
  defp attached_world(assigns) do
    ~H"""
    <div>
      <Kit.row
        class="px-4 py-3 flex items-center justify-between gap-2"
        style="background:var(--b2)"
      >
        <div class="min-w-0">
          <div class="ttl text-[15px] font-semibold truncate"><%= @bible_name %></div>
          <%!-- Attaching **copies** (§2.5b), so this is no longer the library's world:
                editing here can't reach back and change the template, and the label is
                the only place that's visible. --%>
          <div class="lbl dim mt-0.5">This campaign's copy</div>
        </div>
        <.link navigate={~p"/authoring/bible/#{@bible_id}"} class="btn btn-gh btn-sm shrink-0">
          Edit
        </.link>
      </Kit.row>

      <%!-- Said out loud, in the kit's secret tint, because the whole value of the
            control is knowing which read you are looking at — a page that silently
            drops three rules looks like a page missing three rules. --%>
      <Kit.row
        :if={@viewer != :omniscient}
        class="px-4 py-2 flex items-center gap-2"
        style="background:color-mix(in srgb,var(--secret) 14%,transparent)"
      >
        <Kit.dot colour="var(--secret)" />
        <span class="text-[12.5px]">
          As <b><%= viewer_name(assigns) %></b> knows it — what they haven't been told isn't here
        </span>
      </Kit.row>

      <%!-- Every field the editor has, because this is where a world gets *reviewed*
            and a review of half of it is a review of nothing. The cover was missing —
            the one part a stranger reads — and so was starting canon, which is what
            the Director opens a scene from. --%>
      <Kit.row :if={filled(@seen.cover)} class="px-4 py-3">
        <div class="lbl dim mb-1">Cover</div>
        <p class="text-[13px] leading-relaxed"><%= @seen.cover %></p>
      </Kit.row>

      <Kit.row :if={filled(@seen.setting)} class="px-4 py-3">
        <div class="lbl dim mb-1">Setting</div>
        <p class="text-[13px] leading-relaxed"><%= @seen.setting %></p>
      </Kit.row>

      <Kit.row :if={filled(@seen.tone)} class="px-4 py-3">
        <div class="lbl dim mb-1">Tone</div>
        <p class="text-[13px] leading-relaxed"><%= @seen.tone %></p>
      </Kit.row>

      <.world_list label="Rules" entries={WorldBible.entries(@seen.rules)} />
      <.world_list label="What's true at the start" entries={WorldBible.entries(@seen.starting_canon)} />

      <Kit.row :if={world_empty?(@seen)} class="px-4 py-3">
        <p class="text-[12.5px] leading-relaxed dim">
          <%= if @viewer == :omniscient,
            do: "Nothing written past the name yet.",
            else: "Nothing here has been shared with them." %>
        </p>
      </Kit.row>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:entries, :list, required: true)

  defp world_list(assigns) do
    ~H"""
    <Kit.row :if={@entries != []} class="px-4 py-3">
      <div class="lbl dim mb-1.5"><%= @label %></div>
      <div class="space-y-1 text-[13px] leading-relaxed">
        <%!-- Concealed entries are marked, not hidden, for the omniscient author: they
              are omniscient over their own world, and `:secret` is the same mark the
              bible editor gives them, so the two screens don't describe one entry two
              ways. A character's read never reaches here concealed — `for_character/3`
              has already dropped what they don't know. --%>
        <Kit.marked
          :for={{entry, i} <- Enum.with_index(@entries, 1)}
          mark={if(entry.concealed, do: :secret, else: :plain)}
          class="flex gap-2"
        >
          <span class="dim mono text-[11px] pt-0.5"><%= i %></span>
          <span><%= entry.statement %></span>
        </Kit.marked>
      </div>
    </Kit.row>
    """
  end

  defp world_empty?(%WorldBible{} = w) do
    not filled(w.cover) and not filled(w.setting) and not filled(w.tone) and
      WorldBible.entries(w.rules) == [] and WorldBible.entries(w.starting_canon) == []
  end

  defp world_empty?(_), do: true

  defp filled(value), do: is_binary(value) and String.trim(value) != ""

  defp publish_panel(assigns) do
    ~H"""
    <Kit.row class="px-4 py-3" style="background:var(--b2)">
      <div class="flex items-center gap-1.5 mb-2">
        <span class="lbl dim">How it's meant to be read</span>
        <Kit.info label="publishing" phx-click="publish_help" />
      </div>

      <Kit.info_drawer :if={@publish_help} title="About publishing" on_close="publish_help">
        <:intro>
          Publishing asks two separate questions, not one ladder (§3.1c): which
          perspectives a reader may take, and whether the authoring surface comes with it.
        </:intro>
        <:part colour="var(--bcm)" name="As a spectator">
          Everything said and done, and nobody's thoughts. The safe read, and the one
          that keeps the irony intact for somebody coming to the story cold.
        </:part>
        <:part colour="var(--secret)" name="Behind someone's eyes">
          Publishing a head hands over what that character knew while they knew it —
          which is a spoiler control, not a reading preference. A reader who takes Wren's
          view learns what Wren was hiding.
        </:part>
        <:part colour="var(--ok)" name="With the sheets">
          The world and the cast travel too, so a reader can fork the story and carry it
          on. Concealed entries never come with it — what you kept back was never shared.
        </:part>
      </Kit.info_drawer>

      <div class="flex flex-col gap-1.5 mb-3">
        <label class="flex items-center gap-2.5 text-[13px]">
          <Kit.chk state={if @pub_spectator, do: :on, else: :off} phx-click="toggle_spectator" />
          <span class="flex-1">
            As a spectator
            <span class="dim">— everything said and done, nobody's thoughts</span>
          </span>
        </label>

        <%!-- The spoiler control, not a reading preference: publishing a head hands
              away everything in it, and only the author knows which are meant to be
              read. So nothing here is ticked by default.

              **In tier order, not roster order.** The roster is the order people were
              cast, which is an accident of how the campaign was built; the tier is the
              author's own statement about who the story is about. Main cast first,
              then recurring, then walk-ons — a reader offered a walk-on's head above a
              lead's is being offered the wrong story, and a list of forty walk-ons
              buries the two heads worth publishing. --%>
        <label :for={c <- publish_order(@cast)} class="flex items-center gap-2.5 text-[13px]">
          <Kit.chk
            state={if to_string(c.id) in @pub_perspectives, do: :on, else: :off}
            phx-click="toggle_perspective"
            phx-value-id={c.id}
          />
          <span class="av shrink-0" style={"background:#{Voice.of_sheet(Library.payload(c))}"}></span>
          <span class="flex-1">As <%= char_name(c) %></span>
        </label>
      </div>

      <div class="lbl dim mb-1.5">And whether it can be carried on</div>
      <label class="flex items-center gap-2.5 text-[13px] mb-3">
        <Kit.chk state={if @pub_forkable, do: :on, else: :off} phx-click="toggle_forkable" />
        <span class="flex-1">
          Forkable
          <span class="dim">— world, cast, sheets and arc, so someone can continue it</span>
        </span>
      </label>

      <%!-- The gap can be the point; it just must not happen by accident (§3.1c-ii). --%>
      <div
        :if={@publish_warning}
        class="rounded-lg p-2.5 mb-3"
        style="background:color-mix(in srgb,var(--lamp) 10%,transparent);border-left:2px solid var(--lamp)"
      >
        <div class="text-[12.5px] font-semibold mb-0.5"><%= unreadable_line(@publish_warning) %></div>
        <p class="text-[12px] leading-relaxed dim">
          <span class="ttl"><%= warned_titles(@publish_warning) %></span>
          — nobody you've shared was in
          <%= if length(@publish_warning.scenes) == 1, do: "it", else: "them" %>. Readers will see
          that it happened and no more.
        </p>
        <p class="text-[11px] leading-relaxed dim mt-1.5">
          Sometimes a gap is the point. Worth knowing you've made one.
        </p>
      </div>

      <div class="flex flex-wrap items-center gap-1.5">
        <Kit.btn
          kind={:primary}
          size={:sm}
          phx-click="publish"
          data-confirm={publish_confirm(assigns)}
          disabled={@pub_perspectives == [] and not @pub_spectator}
        >
          <%= if @published?, do: "Update what's published", else: "Publish" %>
        </Kit.btn>
        <span :if={@pub_perspectives == [] and not @pub_spectator} class="text-[11px] dim">
          Pick at least one way to read it.
        </span>
      </div>
    </Kit.row>
    """
  end

  defp unreadable_line(%{scenes: [_]}), do: "One scene nobody will be able to read"
  defp unreadable_line(%{scenes: s}), do: "#{length(s)} scenes nobody will be able to read"

  defp warned_titles(%{scenes: scenes}),
    do: scenes |> Enum.map(&Map.get(&1, :title)) |> Enum.join(", ")

  defp publish_confirm(assigns) do
    heads = length(assigns.pub_perspectives)

    read =
      cond do
        heads > 1 -> "#{heads} people's heads"
        heads == 1 -> "one person's head"
        true -> "no interiority"
      end

    fork = if assigns.pub_forkable, do: " They can also take a copy and carry it on.", else: ""

    if assigns.published? do
      "Replace what's published? Readers get #{read}, including anyone partway through — " <>
        "there's one published copy and this becomes it." <> fork
    else
      "Publish a public copy? Readers get #{read}." <> fork
    end
  end

  # ── Cast ──────────────────────────────────────────────────────────────────────

  defp cast_tab(assigns) do
    ~H"""
    <div>
      <Kit.row class="px-4 py-2.5 flex items-center justify-between gap-2" style="background:var(--b2)">
        <span class="lbl dim">Cast · <%= length(@cast) %></span>
        <div class="flex gap-1.5">
          <Kit.btn size={:sm} type="button" phx-click="new_character">✦ Write one</Kit.btn>
          <Kit.btn kind={:primary} size={:sm} type="button" phx-click="start_scene" disabled={scene_cast_entries(assigns) == []}>
            Set a scene
          </Kit.btn>
        </div>
      </Kit.row>

      <%!-- Stubs come from other people's relationships, so they arrive in batches.
            One button fills them all rather than twenty trips through the editor. --%>
      <Kit.row
        :if={pending_count(@cast) > 0}
        class="px-4 py-2.5 flex items-center justify-between gap-2"
      >
        <span class="text-[12px] dim">
          <%= pending_line(pending_count(@cast)) %> — stubs from relationships, not written yet.
        </span>
        <Kit.btn size={:sm} type="button" phx-click="generate_pending" disabled={@generating}>
          <%= if @generating, do: "Filling them in…", else: "Fill them in" %>
        </Kit.btn>
      </Kit.row>

      <.cast_row :for={c <- named_cast(@cast)} entry={c} />

      <%!-- Walk-ons collapse behind a count (`ux/polyphony-campaign.html` §06: "Main cast
            reads as the short list you authored; walk-ons collapse behind a count"). A
            quick-built campaign arrives with three people you asked for and a dozen the
            cast introduced — a flat list buries the ones you came for. --%>
      <details :if={walk_ons(@cast) != []}>
        <summary
          class="row px-4 py-3 flex items-center justify-between gap-2 cursor-pointer list-none"
          style="background:var(--b2)"
        >
          <div>
            <span class="lbl dim">Walk-ons · <%= length(walk_ons(@cast)) %></span>
            <div class="text-[11px] dim mt-0.5">
              Written around the cast. Only remembered in their own scenes.
            </div>
          </div>
          <span class="dim text-[14px] shrink-0">⌄</span>
        </summary>
        <.cast_row :for={c <- walk_ons(@cast)} entry={c} />
      </details>

      <Kit.empty :if={@cast == []} headline="Nobody is in this story yet.">
        A campaign needs at least one character before a scene can open.
        <:action>
          <Kit.btn kind={:primary} size={:sm} type="button" phx-click="new_character">
            ✦ Write a character
          </Kit.btn>
        </:action>
      </Kit.empty>

      <div :if={@addable != []} class="px-4 py-3" style="background:var(--b2)">
        <form id={eid(@id, "add-character")} phx-submit="add_character" class="flex gap-1.5">
          <label for={eid(@id, "add-character-select")} class="sr-only">Add a character</label>
          <select id={eid(@id, "add-character-select")} name="id" class="field px-3 py-2 text-[13px] flex-1">
            <option :for={c <- @addable} value={c.id}>
              <%= char_name(c) %><%= if pending?(c), do: " (pending)", else: "" %>
            </option>
          </select>
          <Kit.btn kind={:ghost} type="submit">Add</Kit.btn>
        </form>
      </div>

      <p :if={@addable == [] and @cast != []} class="px-4 py-3 text-[11px] leading-relaxed dim">
        Everyone you've written<span :if={@bible_name}> in <%= @bible_name %></span> is already
        in the cast.
      </p>

      <%!-- Beside Cast, per §06b: groups are written with the character editor and
            seed the people they produce, so this is where they belong rather than in
            a corner of their own. --%>
      <.groups_card {assigns} />
    </div>
    """
  end

  attr(:entry, :any, required: true)

  defp cast_row(assigns) do
    ~H"""
    <Kit.row class="px-4 py-2.5 flex items-center gap-2.5">
      <span class="av shrink-0" style={"background:#{Voice.of_sheet(Library.payload(@entry))}"}></span>
      <div class="min-w-0 flex-1">
        <div class="text-[13.5px] font-semibold"><%= char_name(@entry) %></div>
        <div class="text-[11px] dim truncate"><%= char_blurb(@entry) %></div>
      </div>
      <Kit.pill :if={pending?(@entry)} colour="var(--lamp)">Pending</Kit.pill>
      <.link navigate={~p"/authoring/character/#{@entry.id}"} class="btn btn-gh btn-sm shrink-0">
        Edit
      </.link>
      <Kit.btn kind={:pen} size={:sm} phx-click="remove_character" phx-value-id={@entry.id}>
        Remove
      </Kit.btn>
    </Kit.row>
    """
  end

  # Tier, not status, is what separates the short list you authored from the people it
  # produced (§2.5) — a main-cast member can be a half-written stub and still be one of
  # the two people you came for.
  defp named_cast(cast), do: Enum.reject(cast, &walk_on?/1)
  defp walk_ons(cast), do: Enum.filter(cast, &walk_on?/1)

  defp walk_on?(entry), do: Characters.tier_of(entry) == :incidental

  # ── Premise ───────────────────────────────────────────────────────────────────

  defp premise_tab(assigns) do
    ~H"""
    <div class="px-4 py-4">
      <%!-- Premise comes after Cast in the tab order because the pitch is written
            *from* the cast — which is also what Expand reads.

            The **title lives here**, not in Settings. It was filed with the content
            switches and the model pickers, which is where a campaign's configuration
            goes — but a title isn't configuration, it's the first line of the pitch,
            and it is written in the same sitting and out of the same material. Naming
            it in one place and pitching it in another meant nothing on either screen
            could see the other. --%>
      <form id={eid(@id, "campaign-premise")} phx-change="update_details">
        <label for={eid(@id, "campaign-name")} class="lbl dim">What it's called</label>
        <input
          id={eid(@id, "campaign-name")}
          type="text"
          name="name"
          value={@payload[:name]}
          placeholder="Name this campaign…"
          phx-debounce="blur"
          class="field px-3 py-2.5 text-[14px] w-full mt-1.5 mb-4"
        />

        <div class="flex items-center justify-between gap-2 mb-2">
          <label for={eid(@id, "premise-input")} class="lbl dim">What this story is about</label>
          <Kit.btn kind={:ghost} size={:sm} type="button" phx-click="expand_premise" disabled={@expanding_premise}>
            <%= if @expanding_premise, do: "✦ …", else: "✦ Expand" %>
          </Kit.btn>
        </div>

        <textarea
          id={eid(@id, "premise-input")}
          name="premise"
          rows="8"
          phx-debounce="blur"
          class="field px-3.5 py-3 text-[14px] leading-relaxed w-full"
          placeholder="A shipment came in that isn't on any manifest…"
        ><%= @payload[:premise] %></textarea>
      </form>

      <p class="text-[11px] leading-relaxed dim mt-2">
        Expand deepens whatever's saved, grounded in the world and the cast — so it reads best
        once both exist.<span :if={blank?(@payload[:name])}>
          With no title yet, it writes one too.</span>
      </p>
    </div>
    """
  end

  # `ux/polyphony-campaign.html` §06b, which had no implementation at all — the domain
  # could seed from a group, resolve an audience through one, and fan its arc out to
  # every member, and there was no way to make one.
  defp groups_card(assigns) do
    ~H"""
    <Kit.sheet class="m-4">
      <Kit.row class="px-4 py-2.5 flex items-center justify-between gap-2" style="background:var(--b2)">
        <span class="lbl dim">Groups · <%= length(@groups) %></span>
        <Kit.btn size={:sm} type="button" phx-click="new_group">✦ Write one</Kit.btn>
      </Kit.row>

      <Kit.row :for={g <- @groups} class="px-4 py-2.5 flex items-center gap-2.5">
        <span class="av shrink-0" style={"background:#{g.colour}"}></span>
        <.link navigate={~p"/authoring/group/#{g.id}"} class="min-w-0 flex-1">
          <div class="text-[13.5px] font-semibold truncate"><%= g.name %></div>
          <div class="text-[11px] dim"><%= group_line(g) %></div>
        </.link>
        <span class="dim text-[14px] shrink-0">›</span>
      </Kit.row>

      <div :if={@groups != []} class="px-4 py-2.5">
        <p class="text-[11px] leading-relaxed dim">
          Anyone written from a group starts with its fields and knows whatever it knows.
        </p>
      </div>

      <Kit.empty :if={@groups == []} headline="No groups yet." class="py-6">
        A group is written like a character and used as a starting point for others — a
        crew, a household, an order. It saves writing the same person five times, and
        gives secrets somewhere to point.
        <:action>
          <Kit.btn kind={:primary} size={:sm} type="button" phx-click="new_group">
            ✦ Write a group
          </Kit.btn>
        </:action>
      </Kit.empty>
    </Kit.sheet>
    """
  end

  # The design's own line: "6 members · seeds new people · 2 secrets".
  defp group_line(g) do
    [
      "#{g.members} member#{if g.members == 1, do: "", else: "s"}",
      "seeds new people",
      g.secrets > 0 && "#{g.secrets} secret#{if g.secrets == 1, do: "", else: "s"}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  # ── Scenes ────────────────────────────────────────────────────────────────────

  defp scenes_tab(assigns) do
    ~H"""
    <div>
      <Kit.row class="px-4 py-2.5 flex items-center justify-between gap-2" style="background:var(--b2)">
        <span class="lbl dim"><%= length(@scenes) %> <%= if length(@scenes) == 1, do: "scene", else: "scenes" %></span>
        <Kit.btn kind={:primary} size={:sm} type="button" phx-click="start_scene" disabled={scene_cast_entries(assigns) == []}>
          Set a scene
        </Kit.btn>
      </Kit.row>

      <%!-- Who is in it. Not every scene is the whole cast, and opening one with
            everybody present is how a two-hander becomes a crowd — the roster is what
            turn order walks, so it is also a cost. Everyone ready is the default, so
            an author who never touches this gets exactly what they got before. --%>
      <Kit.row :if={@cast != []} class="px-4 py-3">
        <div class="flex items-center justify-between gap-2">
          <span class="lbl dim">Who's in it</span>
          <span class="text-[11px] dim"><%= length(scene_cast_entries(assigns)) %> of <%= length(scene_ready(@cast)) %></span>
        </div>
        <div class="flex flex-wrap gap-1.5 mt-1.5">
          <button
            :for={c <- scene_ready(@cast)}
            type="button"
            class={["pill", not MapSet.member?(scene_cast_ids(assigns), c.id) && "dim"]}
            style={MapSet.member?(scene_cast_ids(assigns), c.id) && "background:var(--b3)"}
            aria-pressed={to_string(MapSet.member?(scene_cast_ids(assigns), c.id))}
            phx-click="toggle_scene_cast"
            phx-value-id={c.id}
          >
            <%= char_name(c) %>
          </button>
        </div>
        <p :if={scene_cast_entries(assigns) == []} class="text-[11px] leading-relaxed mt-1.5" style="color:var(--pencil)">
          Nobody is in it. Pick at least one.
        </p>

        <%!-- The walk-ons this story invented for itself, reachable from the screen
              where you choose a cast. `SceneControl` refuses a non-`:full` character,
              so offering one as a chip would be offering a choice that can't be
              honoured — the answer is to write them, here, rather than to send the
              author to another tab to run a batch they didn't ask for. Written in,
              they are selected: the only reason to press this while picking a cast is
              to use them. --%>
        <div :if={pending_cast(@cast) != []} class="mt-3 pt-3" style="border-top:1px solid var(--rule)">
          <div class="lbl dim mb-1.5">Not written yet</div>
          <div class="flex flex-col gap-1.5">
            <div
              :for={c <- pending_cast(@cast)}
              class="flex items-center justify-between gap-2"
            >
              <span class="text-[13px] min-w-0 truncate"><%= char_name(c) %></span>
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
          <p class="text-[11px] leading-relaxed dim mt-2">
            Stubs somebody's relationships invented. Writing one puts them in this scene.
          </p>
        </div>
      </Kit.row>

      <%!-- `OpenScene` has carried `location_id` since §2.3 and nothing ever passed
            one, so every scene opened nowhere. It is a reference field on purpose — a
            string today, a location entity later without changing the event — which is
            why this is a line of text rather than a picker.

            The premise is the scene's, not the campaign's. Every scene used to open on
            the campaign premise, which is the pitch for the whole story and says
            nothing about what is happening *now*. Blank still falls back to it. --%>
      <Kit.row class="px-4 py-3">
        <form id={eid(@id, "scene-where")} phx-change="set_scene_location">
          <div class="flex items-center justify-between gap-2">
            <label for={eid(@id, "scene-location")} class="lbl dim">Where the next scene happens</label>
            <Kit.btn
              size={:sm}
              type="button"
              phx-click="suggest_scene"
              disabled={@scene_suggesting}
            >
              <%= if @scene_suggesting, do: "✦ …", else: "✦ Suggest" %>
            </Kit.btn>
          </div>
          <input
            id={eid(@id, "scene-location")}
            type="text"
            name="location"
            value={@scene_location}
            phx-debounce="blur"
            placeholder="The quay, after the second bell"
            class="field px-3 py-2.5 text-[14px] w-full mt-1.5"
          />
          <p class="text-[11px] leading-relaxed dim mt-1.5">
            The Director opens there, and it grounds what everyone can see.
          </p>

          <label for={eid(@id, "scene-premise")} class="lbl dim mt-3 block">What's already true when it opens</label>
          <textarea
            id={eid(@id, "scene-premise")}
            name="premise"
            rows="2"
            phx-debounce="blur"
            placeholder="The ledger is due at the office by dawn and only one of them knows it."
            class="field px-3 py-2.5 text-[13px] leading-relaxed w-full mt-1.5"
          ><%= @scene_premise %></textarea>
          <p class="text-[11px] leading-relaxed dim mt-1.5">
            The pressure this scene opens under. Left blank, the campaign's premise stands in.
          </p>
        </form>
      </Kit.row>

      <%!-- Newest first: the scene an author wants is nearly always the one they were
            just in. The numbers therefore count down, which is what a reverse-chronological
            list of chapters looks like and is not a mistake. --%>
      <Kit.row :for={s <- Enum.reverse(@scene_rows)} class="px-4 py-3 flex items-center gap-2">
        <.link navigate={~p"/play/#{s.id}"} class="min-w-0 flex-1">
          <div class="ttl text-[14.5px] font-semibold truncate"><%= scene_label(s) %></div>
          <div :if={scene_blurb(s) != ""} class="text-[11px] dim truncate"><%= scene_blurb(s) %></div>
        </.link>
        <Kit.btn
          kind={:pen}
          size={:sm}
          type="button"
          phx-click="delete_scene"
          phx-value-id={s.id}
          data-confirm={delete_scene_confirm(s)}
          class="shrink-0"
        >
          Delete
        </Kit.btn>
        <span class="dim text-[14px] shrink-0">›</span>
      </Kit.row>

      <Kit.empty :if={@scene_rows == []} headline="Nothing has happened yet.">
        Set a scene and the Director will open it.
        <:action>
          <Kit.btn kind={:primary} size={:sm} type="button" phx-click="start_scene" disabled={scene_cast_entries(assigns) == []}>
            Set a scene
          </Kit.btn>
        </:action>
      </Kit.empty>

      <Kit.row class="px-4 py-3 flex items-center justify-between gap-2">
        <div class="min-w-0">
          <div class="text-[13px] font-semibold">What play has changed</div>
          <div class="text-[11px] dim">Arc the scenes proposed, waiting on you</div>
        </div>
        <.link navigate={~p"/arc/#{@entry.id}"} class="btn btn-gh btn-sm shrink-0">Review</.link>
      </Kit.row>
    </div>
    """
  end

  # ── Render helpers ────────────────────────────────────────────────────────────

  defp campaign_title(payload) do
    case payload[:name] do
      n when is_binary(n) and n != "" -> n
      _ -> "Untitled campaign"
    end
  end

  # The meta line the mock puts under the title: world, cast size, scene count. Says
  # "Nothing built yet" on a campaign that has none of them rather than "0 · 0".
  defp campaign_meta(assigns) do
    parts =
      [
        assigns.bible_name,
        count_label(length(assigns.cast), "cast", "cast"),
        count_label(length(assigns.scenes), "scene", "scenes")
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: "Nothing built yet", else: Enum.join(parts, " · ")
  end

  def count_label(0, _one, _many), do: nil
  def count_label(1, one, _many), do: "1 #{one}"
  def count_label(n, _one, many), do: "#{n} #{many}"

  # The kit's amber dot on a tab means *unbuilt*, and the mock uses it only on a
  # campaign's first run — an invitation, not an error. So it goes once something
  # exists anywhere.
  defp unbuilt?(assigns, slug) do
    first_run?(assigns) and
      case slug do
        "world" -> is_nil(assigns.bible_id)
        "cast" -> assigns.cast == []
        "premise" -> assigns.payload[:premise] in [nil, ""]
        _ -> false
      end
  end

  defp scene_ready(cast), do: Enum.filter(cast, &full?/1)

  defp pending_cast(cast), do: Enum.filter(cast, &pending?/1)

  # Tier first, then the roster's own order within a tier — which is cast order, and is
  # what the voice colours key on, so two people in the same tier stay in the order they
  # read in everywhere else.
  @tier_rank %{main: 0, recurring: 1, incidental: 2}

  defp publish_order(cast) do
    cast
    |> Enum.with_index()
    |> Enum.sort_by(fn {c, i} -> {Map.get(@tier_rank, Characters.tier_of(c), 3), i} end)
    |> Enum.map(&elem(&1, 0))
  end

  # Who is in the next scene: the author's selection, or everyone ready if they haven't
  # made one. Always intersected with who is *currently* ready — a selection made before
  # somebody was removed or generated must not resurrect them or hold a stub.
  def scene_cast_ids(assigns) do
    ready = for c <- assigns.cast, full?(c), into: MapSet.new(), do: c.id

    case assigns.scene_cast do
      nil -> ready
      chosen -> MapSet.intersection(chosen, ready)
    end
  end

  def scene_cast_entries(assigns) do
    chosen = scene_cast_ids(assigns)
    Enum.filter(assigns.cast, &MapSet.member?(chosen, &1.id))
  end

  def blank?(value), do: String.trim(to_string(value || "")) == ""

  defp building?(%{build: %BuildRun{status: "running"}}), do: true
  defp building?(_), do: false

  defp first_run?(assigns),
    do: assigns.cast == [] and is_nil(assigns.bible_id) and assigns.scenes == []

  # The card and the form it opens are one thing, so they ask one question. They drifted
  # apart: the card is first-run only, but the form was shown on the open flag alone —
  # and a successful build never cleared it. So the card vanished the moment the
  # campaign stopped being first-run, and the form it had opened stayed on screen,
  # offering to build a world and cast that now existed, underneath the settings for
  # them.
  defp quick_build_open?(assigns), do: assigns.quick_build_open and first_run?(assigns)

  defp content_categories,
    do: [
      {"sexual", "Sex"},
      {"graphic_violence", "Graphic violence"},
      {"other", "Other mature themes"}
    ]

  defp char_blurb(entry) do
    case Library.payload(entry) do
      %CharacterSheet{premise: p} when is_binary(p) and p != "" -> p
      _ -> "No sheet written yet"
    end
  end

  @doc """
  What a scene is called: its number in the campaign, and where it happens.

  It used to be `"Scene " <> first twelve characters of the stream id`, which is not a
  name — the scenes list read as a column of near-identical hex, and the same string was
  being handed to the model as *the scenes already played* to steer it away from repeating
  a setting it could not identify.

  A scene with no location falls back to *A scene*, which `Preflight.describe/1` supplies,
  so the number still distinguishes it.
  """
  def scene_label(%{number: n, title: title}), do: "Scene #{n} · #{title}"

  # How many beats, and what the author said was true when it opened. The premise is the
  # one line that says what this scene *is* rather than where it sits.
  def scene_blurb(%{beats: beats, premise: premise}) do
    [count_label(beats, "beat", "beats"), blank_to_nil(premise)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp blank_to_nil(_), do: nil

  def char_name(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> "char-#{entry.id}"
    end
  end

  def full?(entry), do: match?(%CharacterSheet{status: :full}, Library.payload(entry))

  def pending?(char) do
    match?(%CharacterSheet{status: s} when s != :full, Library.payload(char))
  end

  defp pending_count(cast), do: Enum.count(cast, &pending?/1)

  defp pending_line(1), do: "1 pending character"
  defp pending_line(n), do: "#{n} pending characters"

  def bible_label_of(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> "Untitled world (##{entry.id})"
    end
  end

  defp viewer_name(%{viewer: :omniscient}), do: "Omniscient"

  defp viewer_name(%{viewer: {:character, id}, cast: cast}) do
    case Enum.find(cast, &(to_string(&1.id) == id)) do
      nil -> "Omniscient"
      entry -> char_name(entry)
    end
  end

  defp viewer_colour(%{viewer: :omniscient}), do: "var(--bc)"

  defp viewer_colour(%{viewer: {:character, id}, cast: cast}) do
    case Enum.find(cast, &(to_string(&1.id) == id)) do
      nil -> "var(--bc)"
      entry -> Voice.of_sheet(Library.payload(entry))
    end
  end
end

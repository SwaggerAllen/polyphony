defmodule PolyphonyWeb.Screens.SheetEditor do
  @moduledoc """
  The character sheet editor, as markup.

  The biggest authoring surface, and the one where concealment is authored: a fact
  marked concealed gains a *who else knows* control, and the audience is written from
  the secret's side so it scales with the number of secrets rather than secrets times
  cast. Boundaries are the other half — what this character will not do, and in which
  direction the pressure runs.
  """
  use PolyphonyWeb, :html

  import PolyphonyWeb.BlockField

  alias Polyphony.Authoring.{Audience, CharacterSheet}
  alias Polyphony.Authoring.CharacterSheet.{Boundary, Relationship}
  alias PolyphonyWeb.{AudiencePicker, Kit, Layouts, Voice}

  @stops [
    {"name", "Name"},
    {"cover", "Cover"},
    {"premise", "Premise"},
    {"appearance", "Appearance"},
    {"voice", "Voice"},
    {"temperament", "Temperament"},
    {"backstory", "Backstory"},
    {"facts", "Facts"},
    {"knows", "Who they know"},
    {"pushed", "Pushed"},
    {"groups", "Groups"}
  ]

  @field_specs [
    {"premise", "Premise"},
    {"appearance", "Appearance"},
    {"voice", "Voice"},
    {"temperament", "Temperament"},
    {"backstory", "Backstory"}
  ]
  @block_fields Enum.map(@field_specs, &elem(&1, 0))

  # "" in the app; a distinct prefix per storybook variation, which all render together.
  defp eid("", name), do: name
  defp eid(nil, name), do: name
  defp eid(prefix, name), do: "#{prefix}-#{name}"

  attr(:id, :string, default: "", doc: "prefix for every element id — see eid/2")

  attr(:current_user, :map, default: nil)
  attr(:entry, :any, required: true, doc: "the library entry being edited")
  attr(:campaign, :any, default: nil, doc: "%{id, name} — resolved in the LiveView")
  attr(:sheet, :any, default: nil, doc: "the %CharacterSheet{} itself")
  attr(:name, :string, default: "")
  attr(:role, :any, default: nil)
  attr(:tier, :any, default: nil, doc: "context residency, separate from sheet status")
  attr(:pronouns, :any, default: nil)
  attr(:cover, :any, default: nil)
  attr(:blocks, :any, default: %{}, doc: "the prose fields, edited as blocks")
  attr(:facts, :list, default: [], doc: "a concealed one gains a *who else knows* control")

  attr(:arc_counts, :map,
    default: %{},
    doc: "field => how many times play has revised it (STR-62)"
  )

  attr(:arc_prompt, :any,
    default: nil,
    doc: "the which-do-you-mean prompt for an edit to an arc-touched field, or nil"
  )

  attr(:arc_scenes, :list, default: [], doc: "the campaign's scenes, for *in a scene*")

  attr(:boundaries, :list,
    default: [],
    doc: "what they won't do, and which way the pressure runs"
  )

  attr(:relationships, :list, default: [])
  attr(:groups, :list, default: [], doc: "%{id, name, hue} — this character's groups")
  attr(:all_groups, :list, default: [], doc: "%{id, name, hue} — everything they could join")
  attr(:knows, :list, default: [], doc: "other people's secrets she is in the audience for")
  attr(:char_names, :any, default: %{}, doc: "id → name; names are display, ids are the key")
  attr(:char_hues, :any, default: %{})
  attr(:char_links, :any, default: %{})
  attr(:world_context, :any, default: nil)
  attr(:scene_count, :any, default: 0)
  attr(:generating, :any, default: nil)
  attr(:panel, :any, default: nil)
  attr(:drawer, :any, default: nil)
  attr(:brief_open, :boolean, default: false)
  attr(:dirty, :boolean, default: false)
  attr(:saved, :boolean, default: false)
  attr(:picker_groups, :list, default: [])
  attr(:picker_people, :list, default: [])
  attr(:picker_labels, :any, default: %{})

  attr(:resolved_audience, :list,
    default: [],
    doc: "who already sees it — a read, answered in the LiveView"
  )

  attr(:audience_at, :any,
    default: nil,
    doc: "index of the fact whose *who else knows* picker is open, or nil"
  )

  def screen(assigns) do
    ~H"""
    <%!-- **`height`, not `min-height`.** A `min-h-[100dvh]` column grows with its
          content, so `flex-1 min-h-0 overflow-y-auto` inside it never has a height to
          be a fraction *of* — nothing scrolls, the page runs to whatever length the
          sheet is, and the `shrink-0` bar meant to hold the bottom of the viewport
          lands at the bottom of a document several screens tall. Play has always
          pinned its say-bar this way; these three didn't. --%>
    <Kit.frame class="flex flex-col min-h-0" style="height:100dvh">
      <Kit.header
        title={header_title(@name)}
        eyebrow={@world_context && @world_context["name"]}
        back={back_to(@campaign)}
        back_label={back_label(@campaign)}
        back_confirm={leave_confirm(@dirty)}
      >
        <:actions>
          <Kit.pill :if={@sheet.status != :full} colour="var(--lamp)">Pending</Kit.pill>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <%!-- The identity line: who they are at a glance, in the order a reader needs
            it. Tier carries an info affordance because "Main cast" is the mock's own
            example of a label that means something a first-time reader wouldn't
            assume — it secretly means context residency. --%>
      <Kit.row class="px-4 py-3 flex items-start gap-3" style="background:var(--b2)">
        <span class="w-11 h-11 rounded-xl shrink-0" style={"background:#{Voice.of_sheet(@sheet)}"}></span>
        <div class="min-w-0 flex-1">
          <div class="ttl text-[18px] truncate font-semibold"><%= header_title(@name) %></div>
          <div class="flex flex-wrap items-center gap-1.5 mt-1">
            <Kit.pill>
              <%= CharacterSheet.tier_label(@tier) %>
              <Kit.info label="cast tiers" phx-click="drawer" phx-value-section="tier" />
            </Kit.pill>
            <Kit.pill :if={@pronouns != ""}><%= @pronouns %></Kit.pill>
            <Kit.pill :if={@world_context}><%= @world_context["name"] %></Kit.pill>
            <Kit.pill><%= scene_line(@scene_count) %></Kit.pill>
          </div>
        </div>
      </Kit.row>

      <Kit.jump class="shrink-0">
        <:stop :for={{id, label} <- stops()}>
          <a href={"##{id}"}><%= label %></a>
        </:stop>
      </Kit.jump>

      <div class="flex-1 min-h-0 overflow-y-auto">
        <Kit.info_drawer :if={@drawer == "tier"} on_close="close_drawer" title="About cast tiers">
          <:part colour="var(--lamp)" name="Main cast">
            Always in context. The people the story is about.
          </:part>
          <:part colour="var(--v2)" name="Recurring">
            Also always in context — a side character who should remember and be remembered.
          </:part>
          <:part colour="var(--bcm)" name="Walk-ons">
            Loaded only for the scenes they appear in. A walk-on who turns out to matter
            gets promoted; one who has served their purpose gets demoted rather than deleted.
          </:part>
        </Kit.info_drawer>

        <%!-- One brief writes everything, above the sheet rather than buried in it.
              It was several screens down, under the fields it fills — which is the
              wrong way round on a blank character: the whole point is that you don't
              have to start with the fields. The world bible and the mock's own
              new-character flow (§02, "✦ Write her sheet") both lead with it, and it
              folds away once there is a sheet here, like the campaign's Quick Build. --%>
        <Kit.sheet
          :if={@brief_open or empty_sheet?(assigns)}
          class="m-4"
          style={empty_sheet?(assigns) && "border-color:var(--lamp)"}
        >
          <Kit.row class="px-4 py-3 flex items-center justify-between gap-2" style="background:var(--b2)">
            <span class="ttl text-[15px] font-semibold">Who are they, in a line</span>
            <button
              :if={not empty_sheet?(assigns)}
              type="button"
              class="dim text-[17px] leading-none"
              phx-click="toggle_brief"
              aria-label="Close"
            >
              ×
            </button>
          </Kit.row>
          <div class="px-4 py-3">
            <form id={eid(@id, "sheet-generate-all")} phx-submit="generate_all">
              <label for={eid(@id, "brief")} class="sr-only">Describe the character</label>
              <textarea
                id={eid(@id, "brief")}
                name="brief"
                rows="2"
                placeholder="A jaded harbour-town detective who used to be a priest and still prays out of habit."
                class="field px-3 py-2.5 text-[13px] leading-relaxed w-full mb-2"
              ></textarea>
              <Kit.btn kind={:primary} type="submit" disabled={busy?(@generating, "all")}>
                <%= if busy?(@generating, "all"), do: "✦ Writing…", else: "✦ Write every field" %>
              </Kit.btn>
            </form>
            <p class="text-[11px] leading-relaxed dim mt-2">
              Builds on anything already written rather than replacing it.
            </p>
          </div>
        </Kit.sheet>

        <div :if={not @brief_open and not empty_sheet?(assigns)} class="px-4 pt-4">
          <Kit.btn size={:sm} type="button" phx-click="toggle_brief">✦ Write it from a line</Kit.btn>
        </div>

        <%!-- ── Writing this sheet ──────────────────────────────────────── --%>
        <%!-- Near the top, because both things in it decide how the rest is *written*
              rather than being part of it: the tier is what puts a character in every
              scene's context or only in the scenes they appear in, and a stub's "how
              they fit" is the seed every ✦ on this page reads. Answering them after
              writing the sheet is answering them too late.

              The world picker is gone. A character belongs to one campaign (§2.7) and
              a campaign holds its own copy of a bible, so the setting is decided before
              this screen opens — the picker could only be used to ground a character in
              a world their campaign doesn't play in, and since attaching copies, most
              of what it listed was other campaigns' working copies. It is stated in the
              header instead, where the rest of the identity line is. --%>
        <Kit.sheet class="m-4">
          <Kit.row class="px-4 py-3" style="background:var(--b2)">
            <span class="lbl dim">Writing this sheet</span>
          </Kit.row>

          <Kit.row :if={@sheet.status != :full} class="px-4 py-3">
            <p class="text-[13px] leading-relaxed dim mb-2">
              They came out of someone else's relationships and haven't been written yet. Set
              how they fit, fill the fields in — or write them — and save.
            </p>
            <form id={eid(@id, "stub-role-form")} phx-change="set_role">
              <label for={eid(@id, "stub-role")} class="lbl dim">How they fit</label>
              <input
                id={eid(@id, "stub-role")}
                type="text"
                name="role"
                value={@role}
                autocomplete="off"
                phx-debounce="blur"
                placeholder="e.g. estranged mentor, harbour smuggler"
                class="field px-3 py-2 text-[13px] w-full mt-1.5"
              />
            </form>
          </Kit.row>

          <%!-- Tier saves on tap rather than with the form: it's a property of the
                campaign's shape rather than of the prose, and a set of pills has no
                obvious "apply". --%>
          <Kit.row class="px-4 py-3">
            <span class="lbl dim">They're</span>
            <div class="flex flex-wrap gap-1.5 mt-1.5">
              <button
                :for={t <- CharacterSheet.tiers()}
                type="button"
                class={["pill", t != @tier && "dim"]}
                style={t == @tier && "background:var(--b3)"}
                aria-pressed={to_string(t == @tier)}
                phx-click="set_tier"
                phx-value-tier={t}
              >
                <%= CharacterSheet.tier_label(t) %>
              </button>
            </div>
            <p class="text-[11px] leading-relaxed dim mt-2">
              Main cast and recurring are always in context; a walk-on is loaded only for
              the scenes they're in.
            </p>
          </Kit.row>
        </Kit.sheet>

        <%!-- One form owns everything the sheet stores: the cover, the five prose
              fields, and the name and pronouns in its footer. The list sections below
              it are read-and-toggle only — adding to one opens a panel *outside* this
              form, because a form inside a form isn't a thing, and because the mock
              puts adding in its own sheet anyway (§02, §04). --%>
        <form id={eid(@id, "sheet-form")} phx-submit="save" phx-change="sync">
        <Kit.sheet class="m-4">
          <%!-- ── Name and pronouns ───────────────────────────────────────── --%>
          <%!-- First, because it is the only field on the sheet that is *identity*
                rather than description — everything below it is written about the
                person these two name. It used to sit at the very bottom, under groups,
                filed with the Save button it happened to share a row with, so on a
                blank character the first thing you were asked for was their cover. --%>
          <div class="row px-4 py-3" id={eid(@id, "name")}>
            <label for={eid(@id, "sheet-name")} class="lbl dim">Name</label>
            <input
              id={eid(@id, "sheet-name")}
              type="text"
              name="name"
              value={@name}
              phx-debounce="600"
              placeholder="Their name"
              class="field px-3 py-2.5 text-[14px] w-full mt-1.5"
            />

            <%!-- Free text, never a menu: the set isn't closed, and a fixed list would
                  be a decision about people rather than about data. --%>
            <label for={eid(@id, "sheet-pronouns")} class="lbl dim mt-3 block">Pronouns</label>
            <input
              id={eid(@id, "sheet-pronouns")}
              type="text"
              name="pronouns"
              value={@pronouns}
              phx-debounce="600"
              placeholder="she / her"
              class="field px-3 py-2.5 text-[14px] w-full mt-1.5"
            />
          </div>

          <%!-- ── Cover ───────────────────────────────────────────────────── --%>
          <div class="row px-4 py-3" id={eid(@id, "cover")}>
            <div class="flex items-center justify-between gap-2 mb-2">
              <span class="flex items-center gap-1.5">
                <span class="lbl dim">Cover</span>
                <Kit.info label="the cover" phx-click="drawer" phx-value-section="cover" />
              </span>
              <Kit.btn
                size={:sm}
                type="button"
                phx-click="generate_cover"
                disabled={busy?(@generating, "cover")}
              >
                <%= if busy?(@generating, "cover"), do: "✦ …", else: "✦ Rewrite" %>
              </Kit.btn>
            </div>
            <label for={eid(@id, "cover-text")} class="sr-only">Cover</label>
            <%!-- Written from everything below it, so it is the slowest ✦ on the screen
                  and the one most worth drawing. An existing cover stays on the page
                  while the new one is written — it is still the true cover until the
                  replacement lands. --%>
            <Kit.skel_lines
              :if={busy?(@generating, "cover") and blank_cover?(@cover)}
              lines={["100%", "95%", "48%"]}
              label="Writing the cover"
            />
            <textarea
              :if={not (busy?(@generating, "cover") and blank_cover?(@cover))}
              id={eid(@id, "cover-text")}
              name="cover"
              rows="3"
              phx-debounce="600"
              class="field px-3 py-2.5 text-[13px] leading-relaxed w-full"
              placeholder="The only part strangers see."
            ><%= @cover %></textarea>
            <Kit.skel_lines
              :if={busy?(@generating, "cover") and not blank_cover?(@cover)}
              class="mt-1.5"
              lines={["92%", "56%"]}
              label="Writing a new cover"
            />
            <p class="text-[11px] dim mt-1.5">The only part strangers see.</p>
          </div>

          <Kit.info_drawer :if={@drawer == "cover"} on_close="close_drawer" title="About the cover">
            <:intro>
              A short blurb someone reads before they decide to take this character on.
              It's written from everything below it — the secrets included — under
              instruction to give none of them away.
            </:intro>
            <:part colour="var(--secret)" name="It knows the secrets">
              That's what stops it reading like a stranger wrote it. If a draft quotes one,
              it's thrown away rather than shown to you.
            </:part>
          </Kit.info_drawer>

          <%!-- ── The five written fields ─────────────────────────────────── --%>
          <div :for={{f, label} <- field_specs()}>
            <.block_field
              id={eid(@id, f)}
              field={f}
              label={label}
              blocks={@blocks[f]}
              generating={@generating}
            />
            <%!-- The field carries how many times play has changed it — the warning
                  that an edit here will ask which kind of change it is (STR-62). --%>
            <p :if={Map.get(@arc_counts, f, 0) > 0} class="px-4 pb-2 text-[11px] dim">
              Play has changed this <%= times_word(Map.get(@arc_counts, f)) %> — editing
              will ask which you mean.
            </p>
          </div>

          <%!-- ── Facts ───────────────────────────────────────────────────── --%>
          <div class="row px-4 py-3" id={eid(@id, "facts")}>
            <div class="flex items-center justify-between gap-2 mb-2">
              <span class="flex items-center gap-1.5">
                <span class="lbl dim">What's true about them</span>
                <Kit.info label="facts" phx-click="drawer" phx-value-section="facts" />
              </span>
              <Kit.btn
                size={:sm}
                type="button"
                phx-click="suggest_facts"
                disabled={busy?(@generating, "facts")}
              >
                <%= if busy?(@generating, "facts"), do: "✦ …", else: "✦ Suggest" %>
              </Kit.btn>
            </div>

            <p :if={@facts == [] and not suggesting_facts?(assigns)} class="text-[13px] dim">
              Nothing yet. Facts are the flat statements they'd never contradict.
            </p>

            <%!-- Suggestions arrive as a batch of rows, so the wait is drawn as rows.
                  "✦ Write every field" writes facts too, which is why "all" counts. --%>
            <Kit.skel_lines
              :if={suggesting_facts?(assigns)}
              class="mb-2"
              lines={["86%", "70%", "78%"]}
              label="Suggesting facts"
            />

            <.fact_row
              :for={{f, i} <- Enum.with_index(@facts)}
              prefix={@id}
              fact={f}
              index={i}
              labels={@picker_labels}
            />

            <.add_row label="Add something that's true…" panel="fact" />
          </div>

          <Kit.info_drawer :if={@drawer == "facts"} on_close="close_drawer" title="About facts">
            <:intro>
              Short, flat statements that are true about them. They're what they'd never
              contradict, so keep them to things you'd defend rather than things you'd like.
            </:intro>
            <:part colour="var(--lamp)" name="Always in mind">
              In front of them for every turn, in every scene. Everything else is remembered
              when it's relevant — they still know it, it's just fetched rather than carried.
              A few is right.
            </:part>
            <:part colour="var(--secret)" name="Secret">
              Nobody starts out knowing it. Everyone else finds out in play, if they ever do —
              and the two settings are independent, so they can have a secret they rarely
              think about.
            </:part>
          </Kit.info_drawer>

          <%!-- ── What they start out knowing (§04) ───────────────────────── --%>
          <%!-- The other direction, and read-only on purpose: one fact, one home, so
                nothing can drift out of sync. Each line says where it came from, so
                an inherited one is obvious, and offers the way to where it's edited. --%>
          <div :if={@knows != []} class="row px-4 py-3" id={eid(@id, "knows-secrets")}>
            <div class="lbl dim mb-2">What they start out knowing</div>
            <div :for={k <- @knows} class="py-2">
              <p class="text-[13px] leading-relaxed"><%= k.statement %></p>
              <div class="lbl dim mt-1"><%= knows_provenance(k) %></div>
            </div>
            <p class="text-[11px] leading-relaxed dim mt-1.5">
              To change who knows something, change it where the secret lives. There's
              only ever one copy.
            </p>
          </div>

          <%!-- ── Relationships ───────────────────────────────────────────── --%>
          <div class="row px-4 py-3" id={eid(@id, "knows")}>
            <div class="flex items-center justify-between gap-2 mb-2">
              <span class="flex items-center gap-1.5">
                <span class="lbl dim">Who they know</span>
                <Kit.info label="relationships" phx-click="drawer" phx-value-section="knows" />
              </span>
              <Kit.btn
                size={:sm}
                type="button"
                phx-click="suggest_relationships"
                disabled={busy?(@generating, "relationships")}
              >
                <%= if busy?(@generating, "relationships"), do: "✦ …", else: "✦ Suggest" %>
              </Kit.btn>
            </div>

            <p
              :if={@relationships == [] and not busy?(@generating, "relationships")}
              class="text-[13px] dim"
            >
              Nobody yet. A name that doesn't exist becomes a walk-on when you save.
            </p>

            <Kit.skel_lines
              :if={busy?(@generating, "relationships")}
              class="mb-2"
              lines={["74%", "88%", "66%"]}
              label="Suggesting who they know"
            />

            <div :for={{r, i, colour} <- rel_rows(@relationships, @char_hues)} class="py-2.5">
              <div class="flex items-center gap-2.5 mb-1">
                <span class="av" style={"background:#{colour}"}></span>
                <span class="text-[13.5px] font-semibold flex-1 min-w-0 truncate">
                  <.rel_target
                    target={r.target}
                    target_id={r.target_id}
                    links={@char_links}
                    confirm={leave_confirm(@dirty)}
                  />
                </span>
                <Kit.btn
                  size={:sm}
                  kind={:pen}
                  type="button"
                  phx-click="remove_relationship"
                  phx-value-index={i}
                >
                  Remove
                </Kit.btn>
              </div>
              <p :if={present_string?(r.descriptor)} class="text-[13px] leading-relaxed">
                <%= r.descriptor %>
              </p>
              <%!-- Both directions are shown because the interesting cases are the
                    lopsided ones: asymmetry should look deliberate, not forgotten. --%>
              <div
                :if={present_string?(r.reciprocal)}
                class="flex items-start gap-2 mt-2 pt-2"
                style="border-top:1px solid var(--rule)"
              >
                <span class="lbl dim shrink-0 pt-0.5">Back →</span>
                <p class="text-[12.5px] leading-relaxed dim"><%= r.reciprocal %></p>
              </div>
            </div>

            <.add_row label="Add someone they know…" panel="relationship" />
          </div>

          <Kit.info_drawer :if={@drawer == "knows"} on_close="close_drawer" title="About who they know">
            <:intro>
              How <em>they</em> regard someone else — directional, and often lopsided. The
              interesting cases are where the two directions don't match.
            </:intro>
            <:part colour="var(--bcm)" name="A name nobody has yet">
              Joins the campaign as a walk-on and stays unwritten until someone needs them.
              That's what stops the whole cast writing itself sideways from one button.
            </:part>
          </Kit.info_drawer>

          <%!-- ── Pressures: two lists, never one ─────────────────────────── --%>
          <div id={eid(@id, "pushed")}>
            <.pressure_list
              :for={direction <- Boundary.directions()}
              direction={direction}
              boundaries={@boundaries}
              generating={@generating}
            />

            <div class="row px-4 py-3">
              <.add_row label="Add something…" panel="pressure" />
            </div>
          </div>

          <Kit.info_drawer :if={@drawer == "pushed"} on_close="close_drawer" title="About being pushed">
            <:intro>
              These are played, not filtered. A line they hold is a scene beat — something
              the story has to work against, and something that can give at the right moment.
            </:intro>
            <:part colour="var(--pencil)" name="Won't, and can't stop">
              Two directions. What they refuse, and what they do whether or not they mean to.
              Both can be absolute or can turn once.
            </:part>
            <:part colour="var(--lamp)" name="Until, and then">
              What has to happen before it turns, and what they're like afterwards. They
              aren't told the second one until it's true of them.
            </:part>
            <:part colour="var(--bcm)" name="Flagging mature content">
              Only if the item is about it. A flagged one stays closed in campaigns that
              don't allow that content — and for something they can't stop, closed means
              they don't do it. The ceiling always pushes toward refusal.
            </:part>
          </Kit.info_drawer>

          <%!-- ── Groups ──────────────────────────────────────────────────── --%>
          <div class="px-4 py-3" id={eid(@id, "groups")}>
            <div class="flex items-center justify-between gap-2 mb-2">
              <span class="flex items-center gap-1.5">
                <span class="lbl dim">Groups they belong to</span>
                <Kit.info label="groups" phx-click="drawer" phx-value-section="groups" />
              </span>
            </div>

            <p :if={@groups == []} class="text-[13px] dim">Nobody has a claim on them yet.</p>

            <div :for={g <- @groups} class="flex items-center gap-2.5 py-2">
              <span class="av" style={"background:#{g.hue}"}></span>
              <div class="min-w-0 flex-1">
                <div class="text-[13px] font-semibold"><%= g.name %></div>
                <div class="text-[11px] dim">Member</div>
              </div>
              <Kit.btn
                size={:sm}
                kind={:pen}
                type="button"
                phx-click="leave_group"
                phx-value-group_id={g.id}
              >
                Remove
              </Kit.btn>
            </div>

            <.add_row
              :if={joinable(@all_groups, @groups) != []}
              label="Add a group…"
              panel="group"
            />
          </div>

        </Kit.sheet>
        </form>

        <%!-- The shared picker, outside the sheet's form like every other panel. It
              draws itself as a `Kit.overlay` — this sheet is long enough that an
              inline panel opened from a fact halfway down lands off-screen. --%>
        <AudiencePicker.picker
          :if={open_fact(assigns)}
          statement={open_fact(assigns).statement}
          context_label={header_title(@name)}
          audience={open_fact(assigns).audience}
          groups={@picker_groups}
          people={@picker_people}
          owner={to_string(@entry.id)}
          owner_label={header_title(@name)}
          resolved={@resolved_audience}
        />

        <.fact_panel :if={@panel == "fact"} id={@id} />
        <.relationship_panel :if={@panel == "relationship"} id={@id} names={@char_names} />
        <.pressure_panel :if={@panel == "pressure"} id={@id} />
        <.group_panel :if={@panel == "group"} id={@id} groups={joinable(@all_groups, @groups)} />
        <.arc_touched_panel :if={@arc_prompt} id={@id} prompt={@arc_prompt} scenes={@arc_scenes} />

        <Kit.info_drawer :if={@drawer == "groups"} on_close="close_drawer" title="About groups">
          <:intro>
            A group is written like a character and used as a starting point for others.
            Joining one and being written from one are different things.
          </:intro>
          <:part colour="var(--secret)" name="Belonging is live">
            It's what a secret addressed to the group resolves against, right now. It works
            for people who were never written from the group at all.
          </:part>
          <:part colour="var(--bcm)" name="Seeding was a copy">
            Whatever they took from the group when they were written is theirs. Editing the
            group later doesn't reach back into them, and joining now doesn't backfill what
            it knows — they'd learn that in a scene.
          </:part>
        </Kit.info_drawer>

      </div>

      <.save_bar {assigns} />
    </Kit.frame>
    """
  end

  # ── Section components ────────────────────────────────────────────────────────

  # The "Add …" affordance the mock draws at the foot of every list: a field-shaped
  # row rather than a button, because what follows is a form and this reads as its
  # first line. Tapping it opens the panel below the sheet — the mock's own treatment
  # (§04 "Adding someone who doesn't exist"), and the reason the lists themselves can
  # sit inside the sheet's one form without nesting a second.
  attr(:label, :string, required: true)
  attr(:panel, :string, required: true)

  defp add_row(assigns) do
    ~H"""
    <button
      type="button"
      class="field px-3 py-2 text-[13px] dim w-full text-left mt-2"
      phx-click="panel"
      phx-value-panel={@panel}
    >
      <%= @label %>
    </button>
    """
  end

  # One fact: its statement, its state, and a menu holding its two switches.
  #
  # State and controls are separated because the list is read far more often than it
  # is edited — the flags show as a rule and a chip, and the switches live behind the
  # row's `⋯` (`ux/polyphony-character.html` §03, "item menu · one switch pattern").
  # Same geometry as `Kit.menu`, and `<details>` for the same reason: it opens without
  # a live connection and closes on Escape for free.
  attr(:fact, :map, required: true)
  attr(:index, :integer, required: true)
  attr(:labels, :map, default: %{})
  attr(:prefix, :string, default: "", doc: "the screen's id prefix — `id` here is the fact index")

  defp fact_row(assigns) do
    ~H"""
    <%!-- The menu opens **in the flow**. The kit's `.sheet` is `overflow:hidden` — it
          is what rounds the corners — so an absolutely-positioned panel was clipped by
          the sheet's bottom edge, which meant the last facts on a sheet, the ones
          nearest that edge, were the ones whose menus you couldn't read. Same fix and
          same reason as the world bible's lists: this is one control in three places
          (§04) and it must not behave differently in one of them. --%>
    <details class="py-2.5" id={eid(@prefix, "fact-#{@index}")}>
      <summary class="flex items-start gap-2 list-none cursor-pointer">
        <%!-- Secret owns the left border and always-in-mind is a chip, because only one
              of them can own the structure and a fact can be both. --%>
        <Kit.marked mark={if(@fact.concealed, do: :secret, else: :plain)} class="min-w-0 flex-1">
          <p class="text-[13.5px] leading-relaxed"><%= @fact.statement %></p>
          <div
            :if={@fact.concealed or @fact.core}
            class="flex flex-wrap items-center gap-x-2 gap-y-1 mt-1"
          >
            <%!-- The audience is part of the item, so the count reads without opening
                  anything (§01). --%>
            <AudiencePicker.line :if={@fact.concealed} audience={@fact.audience} labels={@labels} />
            <Kit.chip_core :if={@fact.core} />
          </div>
        </Kit.marked>
        <span class="pill shrink-0" aria-label="Change this fact">⋯</span>
      </summary>

      <nav class="sheet mt-1.5" style="background:var(--b2)">
          <button
            type="button"
            class="row w-full px-4 py-2.5 flex items-center justify-between gap-3 text-left"
            phx-click="toggle_fact"
            phx-value-index={@index}
            phx-value-flag="core"
            aria-pressed={to_string(!!@fact.core)}
          >
            <span>
              <span class="block text-[13px] font-semibold">Always in mind</span>
              <span class="block text-[11px] dim">In front of them every turn</span>
            </span>
            <Kit.sw on={!!@fact.core} colour="var(--lamp)" />
          </button>
          <%!-- Concealment is what the audience says, not a flag beside it (STR-62).
                The picker is always on the row; *Nobody* is the honest resting state,
                a fact about the world rather than a setting you left off. Name anyone
                and the row goes purple — the treatment is derived, never stored beside
                an audience it could disagree with. --%>
          <button
            type="button"
            class="row w-full px-4 py-2.5 flex items-center justify-between gap-2 text-[13px] text-left"
            phx-click="open_audience"
            phx-value-index={@index}
          >
            <span>Who else knows</span>
            <span class={[
              "pill",
              not @fact.concealed && "dim"
            ]} style={@fact.concealed && "border-color:var(--secret);color:var(--secret)"}>
              <%= knows_count(@fact.audience) %> ▾
            </span>
          </button>
          <button
            type="button"
            class="w-full px-4 py-2.5 text-[13px] text-left"
            style="color:var(--pencil)"
            phx-click="remove_fact"
            phx-value-index={@index}
          >
            Delete
          </button>
      </nav>
    </details>
    """
  end

  # Editing a field play has already revised asks which you mean (STR-62). The two
  # answers land in different places in her history: *she's changed again* is an
  # authored proposal on top of what play did, *I wrote her wrong* rewrites the
  # origin and play's changes still apply on top.
  attr(:id, :string, required: true)
  attr(:prompt, :map, required: true)
  attr(:scenes, :list, default: [])

  defp arc_touched_panel(assigns) do
    ~H"""
    <Kit.sheet class="mx-4 mb-4" id={eid(@id, "arc-touched")}>
      <Kit.row class="px-4 py-3 flex items-center justify-between" style="background:var(--b2)">
        <span class="ttl text-[15px] font-semibold"><%= @prompt.label %> — which do you mean?</span>
        <button
          type="button"
          class="dim text-[17px] leading-none"
          phx-click="arc_prompt_cancel"
          aria-label="Keep it as it was"
        >
          ×
        </button>
      </Kit.row>
      <div class="px-4 py-3">
        <p class="text-[12.5px] leading-relaxed dim mb-2.5">
          Play has changed this <%= times_word(@prompt.count) %>. The same keystrokes can
          mean two different things, and they land in different places in her history.
        </p>

        <Kit.marked mark={:prop} class="mb-2.5">
          <p class="text-[13px] leading-relaxed"><%= @prompt.value %></p>
        </Kit.marked>

        <form id={eid(@id, "arc-touched-form")} phx-change="arc_prompt_sync" phx-submit="arc_changed_again">
          <div class="lbl dim mb-1">Because <span class="dim">· optional</span></div>
          <label for={eid(@id, "arc-because")} class="sr-only">Because</label>
          <input
            id={eid(@id, "arc-because")}
            type="text"
            name="because"
            value={@prompt.because}
            placeholder="Leave empty if you just decided it"
            class="field px-3 py-2 text-[12.5px] w-full mb-2.5"
          />

          <div :if={@scenes != []}>
            <div class="lbl dim mb-1">In a scene <span class="dim">· optional</span></div>
            <label for={eid(@id, "arc-scene")} class="sr-only">Which scene</label>
            <select id={eid(@id, "arc-scene")} name="scene_id" class="field px-3 py-2 text-[13px] w-full mb-2.5">
              <option value="" selected={is_nil(@prompt.scene_id)}>No scene · just now</option>
              <option :for={s <- @scenes} value={s.id} selected={@prompt.scene_id == s.id}>
                <%= s.label %>
              </option>
            </select>
          </div>

          <Kit.btn kind={:primary} type="submit" class="w-full justify-center mb-1.5">
            She's changed again — propose it
          </Kit.btn>
        </form>
        <Kit.btn type="button" phx-click="arc_wrote_wrong" class="w-full justify-center">
          I wrote her wrong — rewrite the origin
        </Kit.btn>
        <p class="text-[11px] leading-relaxed dim mt-2">
          Proposing leaves her history standing and joins her pending arc. Rewriting the
          origin corrects the person you first wrote — what play has concluded since still
          applies on top.
        </p>
      </div>
    </Kit.sheet>
    """
  end

  defp times_word(1), do: "once"
  defp times_word(2), do: "twice"
  defp times_word(n), do: "#{n} times"

  # A panel is a sheet with a header, a form, and a way out. Every one of them is the
  # same shape, so the shape lives here and each panel is only its fields.
  attr(:title, :string, required: true)
  attr(:form_id, :string, required: true)
  attr(:submit, :string, required: true)
  attr(:action, :string, default: "Add")
  slot(:inner_block, required: true)
  slot(:note)

  defp panel(assigns) do
    ~H"""
    <Kit.sheet class="mx-4 mb-4">
      <Kit.row class="px-4 py-3 flex items-center justify-between" style="background:var(--b2)">
        <span class="ttl text-[15px] font-semibold"><%= @title %></span>
        <button
          type="button"
          class="dim text-[17px] leading-none"
          phx-click="panel"
          phx-value-panel=""
          aria-label={"Close #{@title}"}
        >
          ×
        </button>
      </Kit.row>
      <div class="px-4 py-3">
        <form id={@form_id} phx-submit={@submit}>
          <%= render_slot(@inner_block) %>
          <Kit.btn kind={:primary} type="submit" class="mt-1.5"><%= @action %></Kit.btn>
        </form>
        <p :if={@note != []} class="text-[11px] leading-relaxed dim mt-2">
          <%= render_slot(@note) %>
        </p>
      </div>
    </Kit.sheet>
    """
  end

  attr(:id, :string, default: "")

  defp fact_panel(assigns) do
    ~H"""
    <.panel title="Something that's true" form_id={eid(@id, "fact-form")} submit="add_fact">
      <label for={eid(@id, "fact-statement")} class="lbl dim">The fact</label>
      <input
        id={eid(@id, "fact-statement")}
        type="text"
        name="statement"
        autocomplete="off"
        placeholder="She has signed the harbour register every day since she was fourteen."
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5"
      />
      <:note>
        Flat and defensible — something they'd never contradict. You can make it always
        in mind, or a secret, once it's on the list.
      </:note>
    </.panel>
    """
  end

  attr(:names, :list, required: true)

  attr(:id, :string, default: "")

  defp relationship_panel(assigns) do
    ~H"""
    <.panel title="Who do they know?" form_id={eid(@id, "rel-form")} submit="add_relationship">
      <label for={eid(@id, "rel-target")} class="lbl dim">Their name</label>
      <input
        id={eid(@id, "rel-target")}
        type="text"
        name="target"
        list="char-names"
        autocomplete="off"
        placeholder="Aldous Ashgrove"
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5 mb-3"
      />
      <datalist id={eid(@id, "char-names")}>
        <option :for={n <- @names} value={n}></option>
      </datalist>
      <label for={eid(@id, "rel-descriptor")} class="lbl dim">How do they regard them?</label>
      <input
        id={eid(@id, "rel-descriptor")}
        type="text"
        name="descriptor"
        placeholder="The only person on the quay she'd trust with a key."
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5"
      />
      <:note>
        A name nobody has yet joins the campaign as a walk-on and stays unwritten until
        someone needs them.
      </:note>
    </.panel>
    """
  end

  attr(:id, :string, default: "")

  defp pressure_panel(assigns) do
    ~H"""
    <.panel title="Where can they be pushed?" form_id={eid(@id, "boundary-form")} submit="add_boundary">
      <label for={eid(@id, "boundary-topic")} class="lbl dim">What</label>
      <input
        id={eid(@id, "boundary-topic")}
        type="text"
        name="topic"
        autocomplete="off"
        placeholder="Name her father"
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5 mb-3"
      />

      <label for={eid(@id, "boundary-direction")} class="lbl dim">Which way it runs</label>
      <select
        id={eid(@id, "boundary-direction")}
        name="direction"
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5 mb-3"
      >
        <option value="refusal">Something they won't do</option>
        <option value="compulsion">Something they can't stop doing</option>
      </select>

      <label for={eid(@id, "boundary-stance")} class="lbl dim">Does anything change that?</label>
      <select
        id={eid(@id, "boundary-stance")}
        name="stance"
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5 mb-3"
      >
        <option value="closed">Never — whatever happens</option>
        <option value="conditional">Not until…</option>
        <option value="open">No gate at all</option>
      </select>

      <label for={eid(@id, "boundary-condition")} class="lbl dim">Until</label>
      <input
        id={eid(@id, "boundary-condition")}
        type="text"
        name="condition"
        placeholder="Someone she loves is going to be hurt by the silence."
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5 mb-3"
      />

      <label for={eid(@id, "boundary-after")} class="lbl dim">And then</label>
      <input
        id={eid(@id, "boundary-after")}
        type="text"
        name="after_release"
        placeholder="She says it flatly, in public, and doesn't soften it."
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5 mb-3"
      />

      <label for={eid(@id, "boundary-pressure")} class="lbl dim">If they're pushed before then</label>
      <input
        id={eid(@id, "boundary-pressure")}
        type="text"
        name="on_pressure"
        placeholder="She gets very polite, and very boring, and leaves."
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5 mb-3"
      />

      <label for={eid(@id, "boundary-category")} class="lbl dim">Anything to flag?</label>
      <select
        id={eid(@id, "boundary-category")}
        name="category"
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5"
      >
        <option value="">Nothing — most aren't</option>
        <option value="sexual">Sex</option>
        <option value="graphic_violence">Violence</option>
        <option value="other">Other</option>
      </select>

      <:note>
        <em>And then</em> is written for you, and they aren't told it until it happens.
        Flag mature content only if the item is about it — a campaign that doesn't allow
        it holds this closed either way.
      </:note>
    </.panel>
    """
  end

  attr(:groups, :list, required: true)

  attr(:id, :string, default: "")

  defp group_panel(assigns) do
    ~H"""
    <.panel title="Which group?" form_id={eid(@id, "group-form")} submit="join_group">
      <label for={eid(@id, "group-select")} class="lbl dim">The group</label>
      <select
        id={eid(@id, "group-select")}
        name="group_id"
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5"
      >
        <option :for={g <- @groups} value={g.id}><%= g.name %></option>
      </select>
      <:note>
        Joining is membership and nothing else — they don't quietly gain what the group
        knows. They'd learn that in a scene.
      </:note>
    </.panel>
    """
  end

  # One direction's pressure list. Two lists rather than one is the design's whole
  # argument for this section: direction lives in the grouping, not the wording, so
  # an item can never be read backwards.
  attr(:direction, :atom, required: true)
  attr(:boundaries, :list, required: true)
  attr(:generating, :any, required: true)

  defp pressure_list(assigns) do
    items =
      for {b, i} <- Enum.with_index(assigns.boundaries),
          (b.direction || :refusal) == assigns.direction,
          do: {b, i}

    assigns = assign(assigns, :items, items)

    ~H"""
    <div class="row px-4 py-3">
      <div class="flex items-center justify-between gap-2 mb-2">
        <span class="flex items-center gap-1.5">
          <span class="lbl dim"><%= Boundary.direction_label(@direction) %></span>
          <Kit.info
            :if={@direction == :refusal}
            label="being pushed"
            phx-click="drawer"
            phx-value-section="pushed"
          />
        </span>
        <Kit.btn
          :if={@direction == :refusal}
          size={:sm}
          type="button"
          phx-click="suggest_boundaries"
          disabled={busy?(@generating, "boundaries")}
        >
          <%= if busy?(@generating, "boundaries"), do: "✦ …", else: "✦ Suggest" %>
        </Kit.btn>
      </div>

      <p
        :if={@items == [] and not busy?(@generating, "boundaries")}
        class="text-[13px] dim"
      ><%= empty_pressure(@direction) %></p>

      <%!-- One ✦ writes both directions in a single call, so both panes wait together
            and both say so. Silence in one of them would read as that half having
            failed. --%>
      <Kit.skel_lines
        :if={busy?(@generating, "boundaries")}
        class="mb-2"
        lines={["58%", "90%", "72%"]}
        label="Suggesting what they will and won't do"
      />

      <div :for={{b, i} <- @items} class="py-2">
        <Kit.marked mark={if(@direction == :compulsion, do: :compel, else: :bound)}>
          <div class="flex items-center justify-between gap-2 mb-1.5">
            <span class="text-[14px] font-semibold"><%= b.topic %></span>
            <Kit.pill colour={stance_colour(b.stance)} class="shrink-0">
              <%= stance_label(b.stance, @direction) %>
            </Kit.pill>
          </div>
          <div :if={present_string?(b.condition)} class="flex gap-2.5 mb-1">
            <span class="lbl dim shrink-0 pt-0.5 w-14">until</span>
            <span class="text-[13px] leading-relaxed flex-1"><%= b.condition %></span>
          </div>
          <%!-- Shown to the author, never to the character until it's true of them —
                that withholding is `Polyphony.Context`'s job, not this screen's. --%>
          <div :if={present_string?(b.after_release)} class="flex gap-2.5 mb-1">
            <span class="lbl dim shrink-0 pt-0.5 w-14"><%= after_label(@direction) %></span>
            <span class="text-[13px] leading-relaxed flex-1 dim"><%= b.after_release %></span>
          </div>
          <div :if={present_string?(b.on_pressure)} class="flex gap-2.5">
            <span class="lbl dim shrink-0 pt-0.5 w-14"><%= pressure_label(@direction) %></span>
            <span class="text-[13px] leading-relaxed flex-1 dim"><%= b.on_pressure %></span>
          </div>
          <div :if={b.category} class="flex items-center gap-1.5 mt-2">
            <Kit.dot colour="var(--pencil)" />
            <span class="text-[12px] dim">
              Flagged as <%= category_label(b.category) %> — a campaign that doesn't allow it
              holds this closed, whatever the story does.
            </span>
          </div>
        </Kit.marked>
        <Kit.btn
          size={:sm}
          kind={:pen}
          type="button"
          class="mt-1.5"
          phx-click="remove_boundary"
          phx-value-index={i}
        >
          Remove
        </Kit.btn>
      </div>
    </div>
    """
  end

  # The one info drawer, used by every section (`ux/polyphony-character.html` §06b):
  # title, prose, then a subsection per concept with its own status dot. It is the
  # kit's sheet-and-rows applied to explanation rather than a new component — and
  # there is one per *section*, not one per setting, because the concepts in a
  # section only make sense together.

  # The bar that doesn't scroll away. A sibling of the scroll container rather than
  # something inside it, so it holds the bottom of the viewport the way play's say-bar
  # does — no new kit primitive, and no `position:fixed` to fight the layout.
  #
  # It exists because of what Save actually *does* that autosave deliberately doesn't.
  # The prose is already safe: every edit and every generation calls `touch/1`, which
  # writes a beat later. What only a deliberate Save does is **promote a stub to
  # `:full`** — and `SceneControl` refuses anything that isn't, so a sheet written
  # entirely by "✦ Write every field" is complete, saved, and still uncastable. That
  # was invisible: the one control that changed it was the last thing on a very long
  # page, behind five prose fields, the facts, the relationships and the groups.
  #
  # So the bar says which of the two situations you are in rather than "unsaved
  # changes", which would be a lie most of the time.
  defp save_bar(assigns) do
    ~H"""
    <div
      class="shrink-0 px-4 py-3 flex items-center gap-2"
      style="background:var(--b2);border-top:1px solid var(--rule)"
    >
      <div class="min-w-0 flex-1">
        <div :if={@sheet.status != :full} class="text-[12.5px] leading-snug" style="color:var(--lamp)">
          Not finished yet — saving is what makes them castable.
        </div>
        <div :if={@sheet.status == :full and @dirty} class="text-[12px] dim" role="status">
          Saving…
        </div>
        <div
          :if={@sheet.status == :full and not @dirty and @saved}
          class="text-[12px]"
          style="color:var(--ok)"
          role="status"
        >
          ✓ Saved
        </div>
        <div :if={@sheet.status == :full and not @dirty and not @saved} class="text-[12px] dim">
          Everything here is saved as you write.
        </div>
      </div>

      <%!-- Outside the form, submitting it by id. The alternative is a second form or
            a duplicate button inside the sheet, and both mean two Saves that can
            disagree. --%>
      <Kit.btn kind={:primary} type="submit" form="sheet-form" class="shrink-0">
        <%= if @sheet.status == :full, do: "Save", else: "Save & finish" %>
      </Kit.btn>
    </div>
    """
  end

  # `@cover` is nil on a sheet that has never had one.
  def blank_cover?(cover), do: String.trim(to_string(cover)) == ""

  # Facts arrive from their own ✦ and from "✦ Write every field", which writes them
  # too — a wait the facts section had no way to show.
  defp suggesting_facts?(assigns),
    do: busy?(assigns.generating, "facts") or busy?(assigns.generating, "all")

  # ── Render helpers ────────────────────────────────────────────────────────────

  # The fact whose audience is open, if any.
  defp open_fact(%{audience_at: index} = assigns) when is_integer(index),
    do: Enum.at(assigns.facts, index)

  defp open_fact(_assigns), do: nil

  # The owner is always in it, so the count never reads as nobody on a fact that is
  # at minimum known to the person it's about.
  defp knows_count(audience) do
    case length(Audience.named(Audience.from(audience))) +
           length(Audience.from(audience).group_ids) do
      0 -> "Nobody"
      n -> to_string(n)
    end
  end

  defp knows_provenance(%{from: from, why: :group}), do: "From #{from} · they're in a group"
  defp knows_provenance(%{from: from, why: _named}), do: "From #{from} · you named them"

  defp header_title(name) when name in [nil, ""], do: "Someone new"
  defp header_title(name), do: name

  defp scene_line(1), do: "In 1 scene"
  defp scene_line(n), do: "In #{n} scenes"

  defp empty_pressure(:compulsion), do: "Nothing drives them."
  defp empty_pressure(_), do: "Nothing gives."

  defp after_label(:compulsion), do: "and now"
  defp after_label(_), do: "and then"

  defp pressure_label(:compulsion), do: "if resisted"
  defp pressure_label(_), do: "if pushed"

  # A gate that will never move is the pencil (an editorial fact about the sheet);
  # one the story can still turn is the lamp; one with no gate at all is done.
  defp stance_colour(:closed), do: "var(--pencil)"
  defp stance_colour(:conditional), do: "var(--lamp)"
  defp stance_colour(_), do: "var(--ok)"

  defp stance_label(:closed, :compulsion), do: "Always"
  defp stance_label(:closed, _), do: "Never"
  defp stance_label(:conditional, :compulsion), do: "Until"
  defp stance_label(:conditional, _), do: "Not yet"
  defp stance_label(:open, :compulsion), do: "Freely"
  defp stance_label(_, _), do: "Open"

  defp category_label(:sexual), do: "sex"
  defp category_label(:graphic_violence), do: "graphic violence"
  defp category_label(cat), do: to_string(cat)

  defp joinable(all, joined) do
    held = MapSet.new(joined, & &1.id)
    Enum.reject(all, &MapSet.member?(held, &1.id))
  end

  # Each relationship with its index and its target's voice colour, resolved before
  # the template rather than inside it — the same person is the same hue here as in
  # the transcript. Someone who doesn't exist yet has no hue and gets the neutral one.
  defp rel_rows(relationships, hues) do
    for {%Relationship{target_id: id, target: name} = r, i} <- Enum.with_index(relationships) do
      colour =
        Map.get(hues, id) || Map.get(hues, String.downcase(to_string(name || ""))) ||
          Voice.neutral()

      {r, i, colour}
    end
  end

  # A relationship's target: a link to that character's sheet when it's an existing
  # (or already-saved-stub) character, otherwise plain text.
  attr(:target, :string, required: true)
  attr(:target_id, :integer, default: nil)
  attr(:links, :map, required: true)
  attr(:confirm, :string, default: nil)

  defp rel_target(assigns) do
    # Prefer the stable id; fall back to a name lookup for un-linked (legacy) rels.
    id = assigns.target_id || Map.get(assigns.links, String.downcase(assigns.target))
    assigns = assign(assigns, :id, id)

    ~H"""
    <.link :if={@id} navigate={~p"/authoring/character/#{@id}"} data-confirm={@confirm}>
      <%= @target %>
    </.link>
    <span :if={is_nil(@id)}><%= @target %></span>
    """
  end

  # The leave-confirmation message when there are unsaved edits, else nil (which
  # renders no data-confirm attribute, so a clean page never prompts).
  defp leave_confirm(true), do: "You have unsaved changes. Leave without saving?"
  defp leave_confirm(false), do: nil

  def blank_to_nil(value) do
    case String.trim(to_string(value || "")) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # The campaign reaches the screen as `%{id, name}` — unwrapping a library payload is
  # a read, and a screen renders from assigns.
  defp back_label(nil), do: "Back to library"

  defp back_label(%{name: n}) when is_binary(n) and n != "", do: "Back to #{n}"

  defp back_label(_campaign), do: "Back to the campaign"

  # The rest of the campaign's cast — who **already exists in this story**, which is a
  # different question from who this character is connected to (`relations`).
  #
  # Quick Build has passed this since two blank slots produced two of the same person;
  # this screen's "✦ Write every field" is the same generation with the same blank
  # brief, through the same `Autofill.generate_all/4`, and it was passing no ensemble at
  # all — so it had the bug for the same reason, one screen over. Anyone already named
  # in `relations` is left out rather than described twice under two headings that say
  # different things about them.

  # Back to where you came from. A character belongs to one campaign (§2.7), and that
  # is where you were when you opened them — the library is a place you pass through on
  # the way in, not the place you were. Falling back to it keeps the chevron meaningful
  # for a character that has no campaign yet.
  defp back_to(nil), do: ~p"/library"

  defp back_to(campaign), do: ~p"/campaigns/#{campaign.id}"

  # Blank enough that leading with the brief is the helpful thing rather than clutter.
  # The prose is what "written" means here — a name alone is a stub somebody hasn't
  # started, which is exactly when the one-line path should be open.
  defp empty_sheet?(assigns) do
    Enum.all?(@block_fields, &(join_blocks(assigns.blocks[&1]) == "")) and
      assigns.facts == [] and assigns.relationships == []
  end

  defp field_specs, do: @field_specs

  @doc false
  def present_string?(v), do: is_binary(v) and String.trim(v) != ""

  # The owner's other character entries — powers the relationship datalist (names)
  # and the "open this character" links (name → id).

  defp stops, do: @stops
end

defmodule PolyphonyWeb.Screens.BibleEditor do
  @moduledoc """
  The world bible editor, as markup.

  A world is written once and **copied** when it is attached, so a bible with a campaign
  belongs to that campaign alone. Rules and starting canon are both entry lists and both
  carry the same secret control — that sameness is the design's point, because to a
  reader they are the same thing: something true that may or may not be known.

  The preview is read-only and rendered through the same filter the context path uses,
  so what an author previews cannot drift from what a character's prompt contains.
  """
  use PolyphonyWeb, :html

  import PolyphonyWeb.BlockField

  alias Polyphony.Authoring.WorldBible
  alias PolyphonyWeb.{AudiencePicker, Kit, Layouts}

  @stops [
    {"cover", "Cover"},
    {"name", "Name"},
    {"setting", "Setting"},
    {"tone", "Tone"},
    {"rules", "Rules"},
    {"starting_canon", "What's true"},
    {"sharing", "Sharing"}
  ]

  @prose_specs [{"setting", "Setting"}, {"tone", "Tone"}]

  # Lists of statements, edited as items. Both are `WorldBible.Entry` lists, and both
  # carry the same secret control — that sameness is the design's point (§04).
  @list_specs [
    {"rules", "Rules", "Add a rule…"},
    {"starting_canon", "What's already true", "Add something that's true…"}
  ]

  # "" in the app; a distinct prefix per storybook variation, which all render together.
  defp eid("", name), do: name
  defp eid(nil, name), do: name
  defp eid(prefix, name), do: "#{prefix}-#{name}"

  attr(:id, :string, default: "", doc: "prefix for every element id — see eid/2")
  attr(:current_user, :map, default: nil)
  attr(:entry, :any, required: true, doc: "the library entry being edited")
  attr(:campaign, :any, default: nil, doc: "%{id, name} — resolved in the LiveView")

  attr(:share_url, :string,
    default: nil,
    doc:
      "the unlisted link, built in the LiveView. The host comes from the endpoint's config, which is ambient rather than an assign — a screen that reads it renders differently depending on where it is mounted"
  )

  attr(:name, :string, default: "")
  attr(:name_error, :any, default: nil)
  attr(:name_clash, :any, default: nil, doc: "another world of the same name; flagged on save")
  attr(:cover, :any, default: nil, doc: "the only part a stranger sees before taking the world")
  attr(:blocks, :any, default: %{}, doc: "setting and tone, edited as blocks")
  attr(:items, :any, default: %{}, doc: "rules and starting canon — the same object twice")
  attr(:knows_counts, :map, default: %{}, doc: "`{field, index}` → how many others know")
  attr(:copied_from, :any, default: nil, doc: "attaching a world copies it; this says from where")
  attr(:copy_count, :integer, default: 0)
  attr(:preview, :boolean, default: false)
  attr(:draft, :any, default: nil, doc: "the unsaved draft — its cover, and what it holds back")
  attr(:seen, :any, default: nil, doc: "that draft as a character sees it")
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

  attr(:audience_at, :any, default: nil, doc: "`{field, index}` of the open picker, or nil")

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
        title={world_title(@name)}
        subtitle={lineage_line(assigns)}
        back={back_to(@campaign)}
        back_label={back_label(@campaign)}
        back_confirm={leave_confirm(@dirty)}
      >
        <:actions>
          <form id={eid(@id, "preview-form")} phx-change="preview">
            <Kit.viewas_select
              id={eid(@id, "preview-select")}
              label="Preview as"
              name="as"
              colour={if @preview, do: "var(--secret)", else: "var(--bc)"}
            >
              <option value="" selected={not @preview}>Omniscient</option>
              <%!-- Short here, spelled out in the banner: the control is a chip and a
                    long option would stretch it across the header. --%>
              <option value="stranger" selected={@preview}>A stranger</option>
            </Kit.viewas_select>
          </form>
          <Kit.pill><%= String.capitalize(@entry.visibility) %></Kit.pill>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <%!-- **Preview is read-only** (§3.2). Editing a bible while looking at a
            filtered version of it is how someone deletes something they couldn't
            see, so preview replaces the editor rather than sitting beside it. --%>
      <.preview :if={@preview} seen={@seen} bible={@draft} />

      <div :if={not @preview} class="flex flex-col flex-1 min-h-0">
        <Kit.jump class="shrink-0">
          <:stop :for={{id, label} <- stops()}>
            <a href={"##{id}"}><%= label %></a>
          </:stop>
        </Kit.jump>

        <div class="flex-1 min-h-0 overflow-y-auto">
          <%!-- One brief writes everything, and the field-by-field path stays visible
                underneath so it never reads as the only way in (§02). Like the
                campaign's Quick Build it folds away once there's a world here — it
                would be dead weight from this world's second day. --%>
          <Kit.sheet
            :if={@brief_open or empty_world?(assigns)}
            class="m-4"
            style={empty_world?(assigns) && "border-color:var(--lamp)"}
          >
            <Kit.row class="px-4 py-3 flex items-center justify-between gap-2" style="background:var(--b2)">
              <span class="ttl text-[15px] font-semibold">Describe it in a line</span>
              <button
                :if={not empty_world?(assigns)}
                type="button"
                class="dim text-[17px] leading-none"
                phx-click="toggle_brief"
                aria-label="Close"
              >
                ×
              </button>
            </Kit.row>
            <div class="px-4 py-3">
              <form id={eid(@id, "bible-generate-all")} phx-submit="generate_all">
                <label for={eid(@id, "brief")} class="sr-only">Describe the world</label>
                <textarea
                  id={eid(@id, "brief")}
                  name="brief"
                  rows="2"
                  placeholder="A port town that runs on tides and debts…"
                  class="field px-3 py-2.5 text-[13px] leading-relaxed w-full mb-2"
                ></textarea>
                <Kit.btn kind={:primary} type="submit" disabled={busy?(@generating, "all")}>
                  <%= if busy?(@generating, "all"), do: "✦ Writing…", else: "✦ Write the whole bible" %>
                </Kit.btn>
              </form>
              <p class="text-[11px] leading-relaxed dim mt-2">
                Builds on anything already written rather than replacing it, and leaves an
                authored list alone.
              </p>
            </div>
          </Kit.sheet>

          <div :if={not @brief_open and not empty_world?(assigns)} class="px-4 pt-4">
            <Kit.btn size={:sm} type="button" phx-click="toggle_brief">✦ Write it from a line</Kit.btn>
          </div>

          <form id={eid(@id, "bible-form")} phx-submit="save" phx-change="sync">
            <Kit.sheet class="m-4">
              <%!-- ── Cover ─────────────────────────────────────────────────── --%>
              <div class="row px-4 py-3" id={eid(@id, "cover")}>
                <div class="flex items-center justify-between gap-2 mb-2">
                  <span class="flex items-center gap-1.5">
                    <span class="lbl dim">Cover</span>
                    <Kit.info label="the cover" phx-click="drawer" phx-value-section="cover" />
                  </span>
                  <Kit.btn
                    kind={if(@cover in [nil, ""], do: :primary, else: :ghost)}
                    size={:sm}
                    type="button"
                    phx-click="generate_cover"
                    disabled={busy?(@generating, "cover")}
                  >
                    <%= cover_action(@cover, busy?(@generating, "cover")) %>
                  </Kit.btn>
                </div>

                <label for={eid(@id, "cover-text")} class="sr-only">Cover</label>
                <%!-- The slowest ✦ here, and now the tail of an even longer chained one,
                      so it draws where the words will land rather than leaving an empty
                      box that reads as nothing having happened. --%>
                <Kit.skel_lines
                  :if={busy?(@generating, "cover") and @cover in [nil, ""]}
                  lines={["100%", "95%", "48%"]}
                  label="Writing the cover"
                />
                <textarea
                  :if={not (busy?(@generating, "cover") and @cover in [nil, ""])}
                  id={eid(@id, "cover-text")}
                  name="cover"
                  rows="3"
                  phx-debounce="600"
                  class="field px-3 py-2.5 text-[13px] leading-relaxed w-full"
                  placeholder="Nothing here yet. This is the only part strangers see before they take your world."
                ><%= @cover %></textarea>

                <%!-- What the check was against, not just that it happened: "checked"
                      is worth nothing unless it says what it was checked against. --%>
                <div
                  :if={@cover not in [nil, ""] and secret_count(assigns) > 0}
                  class="flex items-center gap-2 mt-2.5 pt-2.5"
                  style="border-top:1px solid var(--rule)"
                >
                  <Kit.dot colour="var(--secret)" />
                  <span class="text-[11px] leading-relaxed dim">
                    <%= checked_line(secret_count(assigns)) %>
                  </span>
                </div>
                <p :if={@cover in [nil, ""]} class="text-[11px] leading-relaxed dim mt-1.5">
                  It'll be written from everything below — secrets included — with instructions
                  to give none of them away.
                </p>
              </div>

              <%!-- ── Name ──────────────────────────────────────────────────── --%>
              <div class="row px-4 py-3" id={eid(@id, "name")}>
                <label for={eid(@id, "bible-name")} class="lbl dim">Name</label>
                <input
                  id={eid(@id, "bible-name")}
                  type="text"
                  name="name"
                  value={@name}
                  phx-debounce="600"
                  placeholder="Saltmarch"
                  class="field px-3 py-2.5 text-[14px] w-full mt-1.5"
                  style={@name_error && "border-color:var(--pencil)"}
                />
                <div :if={@name_error} class="flex items-start gap-1.5 mt-1.5">
                  <Kit.dot colour="var(--pencil)" class="mt-1.5 shrink-0" />
                  <span class="text-[12px] leading-relaxed" style="color:var(--pencil)">
                    <%= @name_error %> Pick something else, or
                    <%!-- A real link, because the other world is usually one nobody
                          made on purpose — an interrupted Quick Build's leftover — and
                          "open that one" was advice with nowhere to click. --%>
                    <.link
                      :if={@name_clash}
                      navigate={~p"/authoring/bible/#{@name_clash.id}"}
                      class="underline"
                    >
                      open that one</.link><span :if={!@name_clash}>open that one</span>.
                  </span>
                </div>
              </div>

              <%!-- ── Prose ─────────────────────────────────────────────────── --%>
              <.block_field
                :for={{f, label} <- prose_specs()}
                id={eid(@id, f)}
                field={f}
                label={label}
                blocks={@blocks[f]}
                generating={@generating}
              />

              <%!-- ── Lists ─────────────────────────────────────────────────── --%>
              <.item_list
                :for={{f, label, add} <- list_specs()}
                field={f}
                label={label}
                add_label={add}
                placeholder={panel_placeholder(f)}
                panel={@panel}
                items={@items[f]}
                generating={@generating}
                labels={@picker_labels}
                knows_counts={@knows_counts}
                prefix={@id}
                last={f == "starting_canon"}
              />
            </Kit.sheet>

          </form>

          <Kit.info_drawer :if={@drawer == "cover"} on_close="close_drawer" title="About the cover">
            <:intro>
              The existing fields are written for the Director — setting and tone are
              instructions to a model. Someone deciding whether to use this world wants
              different prose entirely, so the cover is its own field.
            </:intro>
            <:part colour="var(--secret)" name="It's written from the secrets">
              That's what stops it reading like a stranger wrote it. A draft that quotes one
              is thrown away rather than shown to you.
            </:part>
            <:part colour="var(--bcm)" name="You can take a world without reading it">
              Save it off the cover and find out what's in it while you play. For a writer
              who wants to be surprised by their own campaign, that's the point.
            </:part>
          </Kit.info_drawer>

          <Kit.info_drawer :if={@drawer == "secrets"} on_close="close_drawer" title="About secrets">
            <:intro>
              Anything here can be marked secret — a rule, something that's already true, a
              character's fact. It's one control in all three places.
            </:intro>
            <:part colour="var(--secret)" name="It stays out of the story, not just the page">
              A secret is absent from every character's context. They aren't told to ignore
              it; it isn't there. That's what makes it hold.
            </:part>
            <:part colour="var(--bc)" name="The Director still knows">
              Knowing a secret is how it aims a scene at one. The asymmetry is the feature.
            </:part>
            <:part colour="var(--bcm)" name="Who else knows comes later">
              For now a secret is known by nobody. Naming the people who start out in on it
              is the audience picker, which isn't built yet.
            </:part>
          </Kit.info_drawer>

          <%!-- Outside the form, like every other panel: it isn't part of the sheet's
                own submission, and a form inside a form isn't a thing. It draws itself
                as a `Kit.overlay`, so where in the document it sits stops mattering. --%>
          <AudiencePicker.picker
            :if={open_item(assigns)}
            statement={open_item(assigns).statement}
            context_label={world_title(@name)}
            audience={open_item(assigns).audience}
            groups={@picker_groups}
            people={@picker_people}
            resolved={@resolved_audience}
          />

          <%!-- The owner for the inline "add" control, which sits up in its own list
                inside `#bible-form`. It carries no markup of its own: a form element
                exists here only because one form cannot be nested in another, and the
                control points at it with `form="item-form"`. --%>
          <form id={eid(@id, "item-form")} phx-submit="add_item"></form>

          <%!-- ── Template or copy (§2.5b) ─────────────────────────────────── --%>
          <Kit.sheet class="m-4">
            <Kit.row class="px-4 py-3" style="background:var(--b2)">
              <span class="lbl dim">Reuse</span>
            </Kit.row>
            <Kit.row :if={@copied_from} class="px-4 py-2.5 flex items-start gap-2">
              <Kit.dot colour="var(--lamp)" class="mt-1.5 shrink-0" />
              <div>
                <p class="text-[12px] leading-relaxed">
                  This is a copy, with a history of its own. Editing it reaches nothing else.
                </p>
                <Kit.btn size={:sm} type="button" phx-click="save_to_library" class="mt-2">
                  Save a copy to your library
                </Kit.btn>
                <p class="text-[11px] leading-relaxed dim mt-1.5">
                  A snapshot of it as it is now, not a link back.
                </p>
              </div>
            </Kit.row>
            <div class="px-4 py-2.5 flex items-start gap-2">
              <Kit.dot colour="var(--bcm)" class="mt-1.5 shrink-0" />
              <p class="text-[12px] leading-relaxed dim">
                <%= reuse_line(@copy_count) %>
              </p>
            </div>
          </Kit.sheet>

          <%!-- ── Sharing ──────────────────────────────────────────────────── --%>
          <Kit.sheet class="m-4" id={eid(@id, "sharing")}>
            <Kit.row class="px-4 py-3" style="background:var(--b2)">
              <span class="ttl text-[15px] font-semibold">Who can see <%= world_title(@name) %></span>
            </Kit.row>

            <button
              :for={{v, title, note} <- visibilities()}
              type="button"
              class={["row w-full px-4 py-2.5 flex items-start gap-2.5 text-left", v == @entry.visibility && "bg-[var(--b3)]"]}
              phx-click="set_visibility"
              phx-value-visibility={v}
              aria-pressed={to_string(v == @entry.visibility)}
            >
              <Kit.dot
                colour={if(v == @entry.visibility, do: "var(--lamp)", else: "var(--rule)")}
                class="mt-1.5"
              />
              <span>
                <span class="block text-[13px] font-semibold"><%= title %></span>
                <span class="block text-[11px] dim"><%= note %></span>
              </span>
            </button>

            <%!-- The token appears the moment it exists rather than being minted and
                  shown to nobody, which is what the design objected to. --%>
            <div :if={@entry.share_token} class="px-4 py-3">
              <div class="lbl dim mb-1.5">Share link</div>
              <div
                class="field px-3 py-2.5 mono text-[12px] leading-relaxed mb-2"
                style="word-break:break-all"
              >
                <%= @share_url %>
              </div>
              <Kit.btn
                kind={:pen}
                size={:sm}
                type="button"
                phx-click="rotate_link"
                data-confirm="A new link stops the old one working. Continue?"
              >
                New link
              </Kit.btn>
              <p class="text-[11px] leading-relaxed dim mt-2">A new link breaks the old one.</p>
            </div>
          </Kit.sheet>
        </div>

        <.save_bar {assigns} />
      </div>
    </Kit.frame>
    """
  end

  # ── Components ────────────────────────────────────────────────────────────────

  # One authored list — a rule, or something already true. Same component for both,
  # and the same secret control, because they are the same thing to a reader.
  attr(:field, :string, required: true)
  attr(:label, :string, required: true)
  attr(:add_label, :string, required: true)
  attr(:placeholder, :string, required: true)
  attr(:panel, :any, required: true)
  attr(:items, :list, required: true)
  attr(:generating, :any, required: true)
  attr(:last, :boolean, default: false)
  attr(:labels, :map, default: %{})

  attr(:prefix, :string,
    default: "",
    doc: "the screen's id prefix — `field` is this list's own id"
  )

  attr(:knows_counts, :map,
    default: %{},
    doc: "`{field, index}` → how many others know, counted once in the LiveView"
  )

  defp item_list(assigns) do
    ~H"""
    <div class={[not @last && "row", "px-4 py-3"]} id={eid(@prefix, @field)}>
      <div class="flex items-center justify-between gap-2 mb-2">
        <span class="flex items-center gap-1.5">
          <span class="lbl dim"><%= @label %></span>
          <Kit.info label="secrets" phx-click="drawer" phx-value-section="secrets" />
        </span>
        <Kit.btn
          size={:sm}
          type="button"
          phx-click="suggest_items"
          phx-value-field={@field}
          disabled={busy?(@generating, @field)}
        >
          <%= if busy?(@generating, @field), do: "✦ …", else: "✦ Suggest" %>
        </Kit.btn>
      </div>

      <p :if={@items == []} class="text-[13px] dim">Nothing yet.</p>

      <%!-- The menu opens **in the flow**, not as an absolutely-positioned layer. The
            kit's `.sheet` is `overflow:hidden` (it's what rounds the corners), so a
            floating panel was clipped by the sheet's bottom edge — which meant the
            last items in a list, the ones nearest that edge, were exactly the ones
            whose menus you couldn't read. It also matches how the mock draws a row
            menu (`ux/polyphony-campaign.html` §05 "Row menu"): a panel, not a layer.
            Opening the whole row rather than the ⋯ alone is the other half — a
            fourteen-pixel target is not a phone affordance. --%>
      <details :for={{item, i} <- Enum.with_index(@items)} class="py-1.5">
        <summary class="flex items-start gap-2 list-none cursor-pointer">
          <Kit.marked
            mark={if(item.concealed, do: :secret, else: :plain)}
            class="min-w-0 flex-1"
          >
            <span class="text-[13.5px] leading-relaxed"><%= item.statement %></span>
            <%!-- The audience is part of the item, not behind the picker, so the count
                  is readable without opening anything (§01). --%>
            <AudiencePicker.line
              :if={item.concealed}
              audience={item.audience}
              labels={@labels}
              class="mt-1"
            />
          </Kit.marked>
          <span class="pill shrink-0" aria-label={"Change item #{i + 1}"}>⋯</span>
        </summary>

        <nav class="sheet mt-1.5" style="background:var(--b2)">
            <%!-- Concealment is what the audience says, not a flag beside it
                  (STR-62). The picker is always on the row; a world's facts start
                  shared, so *naming* an audience is what conceals — the opposite
                  direction from a character's, and the same rule underneath. --%>
            <button
              type="button"
              class="row w-full px-4 py-2.5 flex items-center justify-between gap-2 text-[13px] text-left"
              phx-click="open_audience"
              phx-value-field={@field}
              phx-value-index={i}
            >
              <span>Who knows</span>
              <span
                class={["pill", not item.concealed && "dim"]}
                style={item.concealed && "border-color:var(--secret);color:var(--secret)"}
              >
                <%= if item.concealed, do: @knows_counts[{@field, i}] || "A few", else: "Everyone" %> ▾
              </span>
            </button>
            <button
              type="button"
              class="row w-full px-4 py-2.5 text-[13px] text-left"
              phx-click="move_item"
              phx-value-field={@field}
              phx-value-index={i}
              phx-value-by="-1"
            >
              Move up
            </button>
            <button
              type="button"
              class="row w-full px-4 py-2.5 text-[13px] text-left"
              phx-click="move_item"
              phx-value-field={@field}
              phx-value-index={i}
              phx-value-by="1"
            >
              Move down
            </button>
            <button
              type="button"
              class="w-full px-4 py-2.5 text-[13px] text-left"
              style="color:var(--pencil)"
              phx-click="remove_item"
              phx-value-field={@field}
              phx-value-index={i}
            >
              Delete
            </button>
        </nav>
      </details>

      <%!-- Adding happens **here**, in the list it adds to. It used to open a separate
            sheet below the whole bible form, far enough away that the two didn't
            obviously belong together — you pressed "Add something that's true…" and a
            panel appeared somewhere else on the page. Closed, this is the same box as
            before; open, that box is the input. --%>
      <button
        :if={@panel != @field}
        type="button"
        class="field px-3 py-2 text-[13px] dim w-full text-left mt-2"
        phx-click="panel"
        phx-value-panel={@field}
      >
        <%= @add_label %>
      </button>

      <div :if={@panel == @field} class="mt-2">
        <label for={"new-#{@field}"} class="sr-only"><%= @add_label %></label>
        <div class="flex gap-1.5">
          <%!-- `form=` rather than a nested `<form>`: this markup lives inside
                `#bible-form`, a form inside a form isn't a thing, and without an owner
                of its own Enter here would submit the *bible* and lose what was typed.
                HTML form association puts the control on `#item-form` (rendered empty,
                outside, below) wherever it happens to sit in the document.
                `phx-mounted` rather than `autofocus`, for the same class of reason:
                the attribute only fires on a page load, and this arrives by patch —
                it would look right in the markup and leave the caret nowhere. --%>
          <input
            id={"new-#{@field}"}
            form="item-form"
            type="text"
            name="statement"
            autocomplete="off"
            phx-mounted={JS.focus()}
            placeholder={@placeholder}
            class="field px-3 py-2.5 text-[13px] flex-1"
          />
          <input form="item-form" type="hidden" name="field" value={@field} />
          <Kit.btn kind={:primary} type="submit" form="item-form">Add</Kit.btn>
          <Kit.btn kind={:ghost} type="button" phx-click="panel" phx-value-panel="">
            Cancel
          </Kit.btn>
        </div>
        <p class="text-[11px] leading-relaxed dim mt-1.5">
          Everything starts public. Mark it secret from its own menu once it's on the list.
        </p>
      </div>
    </div>
    """
  end

  # The read-only preview (§3.2), rendered through the **same** filter the context
  # path uses — `WorldBible.for_character/1` — so this can't drift from what a
  # character's prompt actually contains.
  attr(:bible, :map,
    required: true,
    doc: "the draft itself — its cover, and how much is being held back"
  )

  attr(:seen, :map,
    required: true,
    doc:
      "the bible as a character sees it — filtered in the LiveView through the same call the context path uses, so this can't drift from what a prompt contains"
  )

  defp preview(assigns) do
    ~H"""
    <div class="flex-1 min-h-0 overflow-y-auto">
      <Kit.sheet class="m-4">
        <Kit.row
          class="px-4 py-2 flex items-center justify-between gap-2"
          style="background:color-mix(in srgb,var(--secret) 14%,transparent)"
        >
          <span class="text-[12.5px]">
            Previewing as <b>somebody with no part in this</b> · read-only
          </span>
        </Kit.row>

        <Kit.row :if={@bible.cover} class="px-4 py-3">
          <div class="lbl dim mb-1.5">Cover</div>
          <p class="text-[14px] leading-relaxed"><%= @bible.cover %></p>
        </Kit.row>

        <%!-- Paragraphs, not one run-on block: the field is stored blank-line
              separated and reads as prose, which is the point of previewing it. --%>
        <Kit.row :if={@seen.setting} class="px-4 py-3">
          <div class="lbl dim mb-1.5">Setting</div>
          <p :for={para <- paragraphs(@seen.setting)} class="text-[13.5px] leading-relaxed mb-2 last:mb-0">
            <%= para %>
          </p>
        </Kit.row>

        <Kit.row :if={@seen.tone} class="px-4 py-3">
          <div class="lbl dim mb-1.5">Tone</div>
          <p :for={para <- paragraphs(@seen.tone)} class="text-[13.5px] leading-relaxed mb-2 last:mb-0">
            <%= para %>
          </p>
        </Kit.row>

        <Kit.row :for={{label, list} <- preview_lists(@seen)} class="px-4 py-3">
          <div class="lbl dim mb-1.5"><%= label %></div>
          <div class="space-y-1.5 text-[13.5px] leading-relaxed">
            <div :for={s <- list}><%= s %></div>
          </div>
        </Kit.row>

        <div class="px-4 py-2.5">
          <p class="text-[11px] leading-relaxed dim"><%= hidden_line(@bible) %></p>
        </div>
      </Kit.sheet>
    </div>
    """
  end

  # The one info drawer, same shape as the character sheet's — title, prose, a
  # subsection per concept with its own dot.

  # The bar that doesn't scroll away, and its own comment two hundred lines up said why
  # it was needed: *"Save sits at the foot of a sheet several viewports tall and Name is
  # at its head, so the refusal rendered somewhere the author wasn't looking — pressing
  # Save read as nothing happening at all."* That was patched by also flashing the
  # clash; this puts the control itself where it can be seen.
  #
  # What it says is what is actually true. The prose autosaves — every edit calls
  # `touch/1` — so "unsaved changes" would be a lie most of the time. What only a
  # deliberate Save does here is run the **name-clash gate**: two worlds with one name
  # is the bug that made an interrupted Quick Build unsaveable, and a timer is not
  # entitled to decide a name is fine.
  defp save_bar(assigns) do
    ~H"""
    <div
      class="shrink-0 px-4 py-3 flex items-center gap-2"
      style="background:var(--b2);border-top:1px solid var(--rule)"
    >
      <div class="min-w-0 flex-1">
        <div :if={@name_error} class="text-[12.5px] leading-snug" style="color:var(--pencil)">
          <%= @name_error %>
        </div>
        <div :if={is_nil(@name_error) and @dirty} class="text-[12px] dim" role="status">
          Saving…
        </div>
        <div
          :if={is_nil(@name_error) and not @dirty and @saved}
          class="text-[12px]"
          style="color:var(--ok)"
          role="status"
        >
          ✓ Saved
        </div>
        <div :if={is_nil(@name_error) and not @dirty and not @saved} class="text-[12px] dim">
          Everything here is saved as you write.
        </div>
      </div>

      <%!-- Outside the form, submitting it by id — the alternative is a second form or
            a duplicate button inside the sheet, and both mean two Saves that can
            disagree about what was pressed. --%>
      <Kit.btn kind={:primary} type="submit" form="bible-form" class="shrink-0">Save</Kit.btn>
    </div>
    """
  end

  # Back to where you came from. Attaching a world **copies** it (§2.5b), so a bible
  # with a campaign belongs to that campaign alone and there is one right answer; a
  # library template has none, and keeps the library.
  defp back_to(nil), do: ~p"/library"
  defp back_to(campaign), do: ~p"/campaigns/#{campaign.id}"

  # The campaign arrives as `%{id, name}` — unwrapping a library payload is a read.
  defp back_label(nil), do: "Back to library"
  defp back_label(%{name: n}) when is_binary(n) and n != "", do: "Back to #{n}"
  defp back_label(_campaign), do: "Back to the campaign"

  # ── Render helpers ────────────────────────────────────────────────────────────

  # "Nothing written" is about the *world*, not the form: a name alone is a world
  # someone has started, and the first-run card should still be leading them in.
  defp empty_world?(assigns) do
    join_blocks(assigns.blocks["setting"]) == "" and join_blocks(assigns.blocks["tone"]) == "" and
      assigns.items["rules"] == [] and assigns.items["starting_canon"] == []
  end

  defp world_title(name) when name in [nil, ""], do: "Untitled world"
  defp world_title(name), do: name

  defp cover_action(_cover, true), do: "✦ …"
  defp cover_action(cover, _busy) when cover in [nil, ""], do: "✦ Write it"
  defp cover_action(_cover, _busy), do: "✦ Rewrite"

  defp secret_count(assigns),
    do: Enum.count(assigns.items["rules"] ++ assigns.items["starting_canon"], & &1.concealed)

  defp checked_line(1), do: "Checked against your 1 secret — it isn't mentioned."
  defp checked_line(n), do: "Checked against your #{n} secrets — none is mentioned."

  defp lineage_line(%{copied_from: nil, copy_count: 0}), do: "World"
  defp lineage_line(%{copied_from: nil, copy_count: 1}), do: "World · used in 1 campaign"
  defp lineage_line(%{copied_from: nil, copy_count: n}), do: "World · used in #{n} campaigns"
  defp lineage_line(_), do: "World · a copy"

  defp reuse_line(0),
    do:
      "Attaching this to a campaign gives that campaign its own copy. Nothing you write here " <>
        "afterwards reaches it."

  defp reuse_line(1),
    do:
      "One campaign was started from this. It has its own copy, so changes here only affect " <>
        "campaigns you start from now on."

  defp reuse_line(n),
    do:
      "#{n} campaigns were started from this. They have their own copies, so changes here only " <>
        "affect campaigns you start from now on."

  defp visibilities do
    [
      {"private", "Just me", "Nobody else can open it"},
      {"unlisted", "Anyone with the link", "Not listed, not searchable"},
      {"public", "Anyone", "Listed in Browse for people to find"}
    ]
  end

  defp panel_placeholder("rules"), do: "No magic. What looks like it is a bribe."
  defp panel_placeholder(_), do: "Nobody in Saltmarch has seen a customs inspector in nine years."

  # The entry whose audience is open, if any.
  defp open_item(%{audience_at: {field, index}} = assigns),
    do: Enum.at(assigns.items[field] || [], index)

  defp open_item(_assigns), do: nil

  defp paragraphs(text), do: text |> to_string() |> to_blocks()

  defp preview_lists(seen) do
    [
      {"Rules", WorldBible.statements(seen.rules)},
      {"What's already true", WorldBible.statements(seen.starting_canon)}
    ]
    |> Enum.reject(fn {_l, list} -> list == [] end)
  end

  defp hidden_line(bible) do
    case length(WorldBible.secrets(bible)) do
      0 -> "There's nothing held back — this is the whole world."
      1 -> "One thing is held back. They have no idea."
      n -> "#{n} things are held back. They have no idea."
    end
  end

  @doc false
  def draft_bible(%{bible: bible} = assigns) do
    %WorldBible{
      bible
      | name: assigns.name,
        cover: blank_to_nil(assigns.cover),
        setting: join_blocks(assigns.blocks["setting"]),
        tone: join_blocks(assigns.blocks["tone"]),
        rules: assigns.items["rules"],
        starting_canon: assigns.items["starting_canon"]
    }
  end

  defp leave_confirm(true), do: "You have unsaved changes. Leave without saving?"

  defp leave_confirm(false), do: nil

  defp list_specs, do: @list_specs

  defp prose_specs, do: @prose_specs

  defp stops, do: @stops

  defp blank_to_nil(v) do
    case String.trim(to_string(v || "")) do
      "" -> nil
      s -> s
    end
  end
end

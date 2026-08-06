defmodule PolyphonyWeb.Screens.GroupEditor do
  @moduledoc """
  The group editor, as markup.

  A group is a membership rather than a label, which is why its facts carry concealment
  the way a character's do — `Group.secrets/1` exists and the design's own row reads
  *6 members · 2 secrets*.

  **Telling the members is a decision, not a save.** A change to the group fans out into
  one proposal against the template and one per current member, reviewed individually —
  nothing propagates silently, which is the rule everywhere else. That it is a button
  rather than a consequence of saving is the whole point.
  """
  use PolyphonyWeb, :html

  @prose_specs [
    {"premise", "What they are"},
    {"appearance", "How they read"},
    {"temperament", "How they behave"},
    {"backstory", "Where they came from"}
  ]

  @stops [
    {"name", "Name"},
    {"premise", "What they are"},
    {"appearance", "How they read"},
    {"temperament", "How they behave"},
    {"backstory", "History"},
    {"facts", "What's true"},
    {"members", "Members"}
  ]

  import PolyphonyWeb.BlockField

  alias PolyphonyWeb.{Kit, Layouts}

  # "" in the app, where the screen renders once and its ids are what tests target;
  # a distinct prefix per storybook variation, which all render on one page.
  defp eid("", name), do: name
  defp eid(nil, name), do: name
  defp eid(prefix, name), do: "#{prefix}-#{name}"

  attr(:id, :string, default: "", doc: "prefix for every element id — see eid/2")

  attr(:campaign, :any, default: nil, doc: "%{id, name} — resolved in the LiveView")
  attr(:dirty, :boolean, default: false)
  attr(:saved, :boolean, default: false)
  attr(:name, :string, default: "")
  attr(:blocks, :any, default: %{}, doc: "the prose fields, keyed by spec")

  attr(:facts, :list,
    default: [],
    doc: "group facts; a concealed one is what makes this a membership rather than a label"
  )

  attr(:members, :list,
    default: [],
    doc: "%{id, name, hue} — resolved in the LiveView, never here"
  )

  attr(:generating, :any, default: nil)

  attr(:telling, :boolean,
    default: false,
    doc: "a fan-out in flight: one proposal per member, each reviewed on its own"
  )

  attr(:panel, :any, default: nil, doc: "which panel is open — held in the URL, not the socket")
  attr(:current_user, :map, default: nil)

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
        title={@name}
        eyebrow="Group"
        back={back_to(@campaign)}
        back_label={back_label(@campaign)}
      >
        <:actions>
          <Kit.pill><%= length(@members) %> in it</Kit.pill>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <Kit.jump class="shrink-0">
        <:stop :for={{id, label} <- stops()}>
          <a href={"##{id}"}><%= label %></a>
        </:stop>
      </Kit.jump>

      <div class="flex-1 min-h-0 overflow-y-auto">
        <Kit.sheet class="m-4" style="border-color:var(--lamp)">
          <Kit.row class="px-4 py-3" style="background:var(--b2)">
            <span class="lbl dim">Write it from a line</span>
          </Kit.row>
          <div class="px-4 py-3">
            <form id={eid(@id, "group-generate-all")} phx-submit="generate_all">
              <label for={eid(@id, "brief")} class="sr-only">Describe the group</label>
              <textarea
                id={eid(@id, "brief")}
                name="brief"
                rows="2"
                placeholder="The harbour watch — half constabulary, half smugglers…"
                class="field px-3 py-2.5 text-[13px] leading-relaxed w-full mb-2"
              ></textarea>
              <Kit.btn kind={:primary} type="submit" disabled={busy?(@generating, "all")}>
                <%= if busy?(@generating, "all"), do: "✦ …", else: "✦ Write the group" %>
              </Kit.btn>
            </form>
          </div>
        </Kit.sheet>

        <form id={eid(@id, "group-form")} phx-submit="save" phx-change="sync">
          <Kit.sheet class="m-4">
            <div class="row px-4 py-3" id={eid(@id, "name")}>
              <label for={eid(@id, "group-name")} class="lbl dim">Name</label>
              <input
                id={eid(@id, "group-name")}
                type="text"
                name="name"
                value={@name}
                phx-debounce="600"
                placeholder="The Tidewatch"
                class="field px-3 py-2.5 text-[14px] w-full mt-1.5"
              />
            </div>

            <.block_field
              :for={{f, label} <- prose_specs()}
              id={eid(@id, f)}
              field={f}
              label={label}
              blocks={@blocks[f]}
              generating={@generating}
            />

            <%!-- The same control as a world's rules and a character's facts (§04),
                  because to a reader they are the same thing: something true that may
                  or may not be known. Here it is also what membership *grants* — this
                  is the list a secret pointed at the group resolves to. --%>
            <div class="px-4 py-3" id={eid(@id, "facts")}>
              <div class="flex items-center justify-between gap-2 mb-2">
                <span class="lbl dim">What's true about them</span>
                <span class="lbl dim"><%= secrets(@facts) %> secret</span>
              </div>

              <p :if={@facts == []} class="text-[13px] dim">Nothing yet.</p>

              <details :for={{fact, i} <- Enum.with_index(@facts)} class="py-1.5" id={eid(@id, "fact-#{i}")}>
                <summary class="flex items-start gap-2 list-none cursor-pointer">
                  <Kit.marked
                    mark={if(fact.concealed, do: :secret, else: :plain)}
                    class="min-w-0 flex-1"
                  >
                    <span class="text-[13.5px] leading-relaxed"><%= fact.statement %></span>
                  </Kit.marked>
                  <span class="pill shrink-0" aria-label={"Change item #{i + 1}"}>⋯</span>
                </summary>

                <nav class="sheet mt-1.5" style="background:var(--b2)">
                  <button
                    type="button"
                    class="row w-full px-4 py-2.5 flex items-center justify-between gap-3 text-left"
                    phx-click="toggle_secret"
                    phx-value-index={i}
                    aria-pressed={to_string(fact.concealed)}
                  >
                    <span>
                      <span class="block text-[13px] font-semibold">Secret</span>
                      <span class="block text-[11px] dim">
                        Only people this group's membership lets in on it
                      </span>
                    </span>
                    <Kit.sw on={fact.concealed} colour="var(--secret)" />
                  </button>
                  <button
                    type="button"
                    class="row w-full px-4 py-2.5 text-[13px] text-left"
                    phx-click="tell"
                    phx-value-index={i}
                  >
                    Tell the members
                    <span class="block text-[11px] dim">
                      Proposes it to each of them, one review at a time
                    </span>
                  </button>
                  <button
                    type="button"
                    class="w-full px-4 py-2.5 text-[13px] text-left"
                    style="color:var(--pencil)"
                    phx-click="remove_fact"
                    phx-value-index={i}
                  >
                    Delete
                  </button>
                </nav>
              </details>

              <button
                :if={@panel != "facts"}
                type="button"
                class="field px-3 py-2 text-[13px] dim w-full text-left mt-2"
                phx-click="panel"
                phx-value-panel="facts"
              >
                Add something that's true…
              </button>

              <div :if={@panel == "facts"} class="mt-2">
                <label for={eid(@id, "new-fact")} class="sr-only">Add something that's true</label>
                <div class="flex gap-1.5">
                  <%!-- Owned by its own form, like the bible editor's: this sits inside
                        `#group-form` and a form can't nest, so without it Enter would
                        save the group and lose what was typed. --%>
                  <input
                    id={eid(@id, "new-fact")}
                    form="group-fact-form"
                    type="text"
                    name="statement"
                    autocomplete="off"
                    phx-mounted={JS.focus()}
                    placeholder="They keep the tide bell, and the ledger under it."
                    class="field px-3 py-2.5 text-[13px] flex-1"
                  />
                  <Kit.btn kind={:primary} type="submit" form="group-fact-form">Add</Kit.btn>
                  <Kit.btn kind={:ghost} type="button" phx-click="panel" phx-value-panel="">
                    Cancel
                  </Kit.btn>
                </div>
              </div>
            </div>
          </Kit.sheet>

        </form>

        <form id={eid(@id, "group-fact-form")} phx-submit="add_fact"></form>

        <.tell_panel :if={@telling} {assigns} />

        <Kit.sheet class="m-4" id={eid(@id, "members")}>
          <Kit.row class="px-4 py-2.5 flex items-center justify-between gap-2" style="background:var(--b2)">
            <span class="lbl dim">Members · <%= length(@members) %></span>
          </Kit.row>

          <Kit.row :for={m <- @members} class="px-4 py-2.5 flex items-center gap-2.5">
            <span class="av shrink-0" style={"background:#{m.hue}"}></span>
            <div class="min-w-0 flex-1">
              <.link navigate={~p"/authoring/character/#{m.id}"} class="text-[13.5px] font-semibold">
                <%= m.name %>
              </.link>
            </div>
            <Kit.btn kind={:pen} size={:sm} phx-click="remove_member" phx-value-id={m.id}>
              Remove
            </Kit.btn>
          </Kit.row>

          <%!-- Joining is done from the person's own sheet, where the question "who is
                this?" is already on screen. Two places to do one thing is how they
                drift. --%>
          <Kit.empty :if={@members == []} headline="Nobody is in it yet." class="py-6">
            A character joins from their own sheet. An empty group is still useful —
            it's how you set a trap before anyone walks into it.
          </Kit.empty>
        </Kit.sheet>
      </div>

      <.save_bar dirty={@dirty} saved={@saved} back={back_to(@campaign)} />
    </Kit.frame>
    """
  end

  defp tell_panel(assigns) do
    assigns = assign(assigns, :fact, Enum.at(assigns.facts, assigns.telling))

    ~H"""
    <Kit.sheet :if={@fact} class="mx-4 mb-4" style="border-color:var(--lamp)">
      <Kit.row class="px-4 py-3" style="background:var(--b2)">
        <span class="ttl text-[15px] font-semibold">Tell the members</span>
      </Kit.row>
      <div class="px-4 py-3">
        <p class="text-[13px] leading-relaxed mb-2">“<%= @fact.statement %>”</p>
        <p class="text-[12px] leading-relaxed dim mb-3">
          <%= length(@members) %> member(s) each get this as a proposal, plus one against
          the group itself. Nothing changes until you accept it, and refusing one is how
          you write the person who didn't go along with it.
        </p>
        <div class="flex gap-1.5">
          <Kit.btn kind={:primary} size={:sm} type="button" phx-click="tell_members" phx-value-index={@telling}>
            Propose it
          </Kit.btn>
          <Kit.btn kind={:ghost} size={:sm} type="button" phx-click="cancel_tell">Cancel</Kit.btn>
        </div>
      </div>
    </Kit.sheet>
    """
  end

  # Same bar as the other two editors, for the same reason: this is one long scroll and
  # a Save at the foot of it is a Save you have to go and find. The prose autosaves, so
  # the line says that rather than claiming there is unsaved work.
  attr(:dirty, :boolean, default: false)
  attr(:saved, :boolean, default: false)
  attr(:back, :string, default: nil)

  defp save_bar(assigns) do
    ~H"""
    <div
      class="shrink-0 px-4 py-3 flex items-center gap-2"
      style="background:var(--b2);border-top:1px solid var(--rule)"
    >
      <div class="min-w-0 flex-1">
        <div :if={@dirty} class="text-[12px] dim" role="status">Saving…</div>
        <div
          :if={not @dirty and @saved}
          class="text-[12px]"
          style="color:var(--ok)"
          role="status"
        >
          ✓ Saved
        </div>
        <div :if={not @dirty and not @saved} class="text-[12px] dim">
          Everything here is saved as you write.
        </div>
      </div>

      <Kit.btn kind={:primary} type="submit" form="group-form" class="shrink-0">Save</Kit.btn>
    </div>
    """
  end

  # A group belongs to a world, and a world belongs to one campaign (attaching copies),
  # so the campaign is a lookup rather than a guess. Groups written outside one — or
  # before a world was attached — keep the library.

  defp secrets(facts), do: Enum.count(facts, & &1.concealed)

  # ── Render ────────────────────────────────────────────────────────────────────

  defp prose_specs, do: @prose_specs

  defp stops, do: @stops

  # The campaign arrives as `%{id, name}` — unwrapping a library payload is a read, and
  # a screen may not do one. The LiveView already had the entry in hand.
  defp back_label(nil), do: "Back to library"
  defp back_label(%{name: n}) when is_binary(n) and n != "", do: "Back to #{n}"
  defp back_label(_campaign), do: "Back to the campaign"

  defp back_to(nil), do: ~p"/library"
  defp back_to(campaign), do: ~p"/campaigns/#{campaign.id}"
end

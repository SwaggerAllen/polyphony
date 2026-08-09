defmodule PolyphonyWeb.ArcReviewLive do
  @moduledoc """
  Arc review, ported from `ux/polyphony-arc.html` — *what play made of them*.

  A scene closes and the engine proposes what changed, about the people in it and
  about the world. **Nothing is true until you say so**, and nothing is lost if you
  don't: a proposal left alone stays a proposal.

  ## Every proposal says what, from what, and why

  The design's argument for the *Because* line is that it is what makes accepting
  quick — you can check the reasoning without going back and rereading the scene. A
  revision also shows what it changes *from*, struck through, because a replacement
  you can't compare is one you have to take on trust.

  ## Tabs are per subject, and the world is one of them

  Wren, Ilias, Corrigan, Saltmarch — a scene's proposals sorted by who they're about,
  because reviewing is per-person work and a flat list makes you re-orient on every
  card. A tab with nothing pending still shows, at zero, so its absence never reads as
  *not extracted yet*.

  ## Accept-all is the intended fast path, and the only one

  The gate exists to keep state consistent, not to force careful reading. Someone in a
  hurry taps once and still gets sheets that match their story; there is no second
  escape hatch, because one tap is already as cheap as an escape hatch gets.

  ## Groups collapse

  A group of twelve would flood the queue, so a fan-out is one card with one fast
  path, expandable when it matters (`Polyphony.Authoring.GroupArc`). The expansion is
  where dissent lives: accept the group's change, refuse one member's, and you have
  written the person who didn't go along with it.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.{Groups, Library, Repo}
  alias Polyphony.Authoring.{ArcAccept, ArcEntry, Effective, WorldArcEntry}
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Owner
  alias Polyphony.ReadModels.ArcEntry, as: ArcEntryRepo
  alias Polyphony.Permissions
  alias PolyphonyWeb.{Guard, Screens, Voice}

  def mount(%{"campaign_id" => id}, _session, socket) do
    entry = Library.get(id)

    # Accepting an arc proposal writes to the campaign's characters, so this screen is
    # an editing surface wearing a review's clothes — it takes the same gate.
    if Permissions.can_edit?(entry, socket.assigns.current_user) do
      mount_review(id, entry, socket)
    else
      Guard.refuse(socket, entry, "Campaign", socket.assigns.current_user)
    end
  end

  defp mount_review(id, entry, socket) do
    campaign = Library.payload(entry)

    {:ok,
     socket
     |> assign(
       page_title: "Review",
       campaign_id: id,
       campaign_name: campaign_name(campaign),
       cast: cast(campaign),
       editing: nil,
       authoring: nil,
       drawer: false
     )
     |> load()}
  end

  def handle_params(params, _uri, socket) do
    socket = assign(socket, tab: params["tab"] || default_tab(socket))

    # A cast row's expansion links here with ?authoring=<kind> — the character and
    # the scene are known from where the row was tapped, so the form opens filled in.
    case params["authoring"] do
      kind when is_binary(kind) and kind != "" and is_nil(socket.assigns.authoring) ->
        {:noreply, assign(socket, authoring: new_authoring(socket, kind))}

      _ ->
        {:noreply, socket}
    end
  end

  # Character arc is keyed by the character's **library id** — the same identity the
  # cast enters a scene under and extraction files against (§5.2). Names ride along
  # only to label the proposals; before the mint flip this had to resolve ids to
  # names to find anything, and that dance is what a rename used to break.
  defp cast(nil), do: []

  defp cast(campaign) do
    (campaign[:character_ids] || [])
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      case Library.get(id) do
        nil ->
          []

        entry ->
          sheet = Library.payload(entry) || %{}
          [%{id: to_string(entry.id), name: Map.get(sheet, :name) || to_string(id), sheet: sheet}]
      end
    end)
  end

  defp campaign_name(nil), do: "Campaign"
  defp campaign_name(campaign), do: campaign[:name] || "Campaign"

  defp load(socket) do
    per_character =
      Map.new(socket.assigns.cast, &{&1.id, ArcEntryRepo.list_proposed(Repo, &1.id)})

    world = ArcEntryRepo.list_proposed_world(Repo, socket.assigns.campaign_id)

    groups =
      for g <- Groups.list(Owner.of(socket.assigns.current_user)),
          pending = Polyphony.Authoring.GroupArc.pending(g.id),
          pending.group != [] or pending.members != [] do
        %{
          id: to_string(g.id),
          name: group_name(g),
          counts: Polyphony.Authoring.GroupArc.counts(g.id),
          pending: pending
        }
      end

    assign(socket, per_character: per_character, world: world, groups: groups)
  end

  defp group_name(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> "A group"
    end
  end

  # Open on the first subject that actually has something waiting — the reason you
  # came here — rather than on whoever happens to be first in the cast.
  defp default_tab(socket) do
    case Enum.find(socket.assigns.cast, &(socket.assigns.per_character[&1.id] != [])) do
      %{id: id} ->
        id

      _ ->
        cond do
          socket.assigns.world != [] -> "world"
          match?([%{id: _} | _], socket.assigns.cast) -> hd(socket.assigns.cast).id
          true -> "world"
        end
    end
  end

  # ── Reviewing ─────────────────────────────────────────────────────────────────

  # Through `ArcAccept` rather than the read model directly: a proposal can name
  # somebody who doesn't exist yet, and accepting it is what makes them real.
  def handle_event("accept", %{"id" => id}, socket),
    do:
      act(socket, &ArcAccept.accept(&1, Owner.of(socket.assigns.current_user)), id, "Made true.")

  def handle_event("reject", %{"id" => id}, socket),
    do: act(socket, &ArcEntryRepo.reject(Repo, &1), id, "Left as it was.")

  # Accept everything for one subject — the row's own fast path, and what the scene
  # gate's "accept all and carry on" resolves to.
  def handle_event("accept_all", %{"subject" => subject}, socket) do
    safe(socket, fn ->
      type = if subject == socket.assigns.campaign_id, do: "world", else: "character"
      count = ArcAccept.accept_all(subject, type, Owner.of(socket.assigns.current_user))

      {:noreply, socket |> put_flash(:info, made_true(count)) |> load()}
    end)
  end

  def handle_event("accept_group", %{"id" => id}, socket) do
    safe(socket, fn ->
      count = Polyphony.Authoring.GroupArc.accept_all(id)
      {:noreply, socket |> put_flash(:info, made_true(count)) |> load()}
    end)
  end

  def handle_event("edit", %{"id" => id}, socket),
    do: {:noreply, assign(socket, editing: String.to_integer(id))}

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("save_edit", %{"entry_id" => id} = params, socket) do
    safe(socket, fn ->
      attrs = %{statement: params["statement"]}

      attrs =
        if params["scope"] in [nil, ""], do: attrs, else: Map.put(attrs, :scope, params["scope"])

      ArcEntryRepo.edit(Repo, String.to_integer(id), attrs)

      {:noreply, socket |> assign(editing: nil) |> put_flash(:info, "Updated.") |> load()}
    end)
  end

  def handle_event("drawer", _params, socket),
    do: {:noreply, assign(socket, drawer: not socket.assigns.drawer)}

  # Who knows a world fact is an audience, and common knowledge is one of its values
  # — so this changes the proposal and leaves the decision about whether it is true
  # to the ordinary actions.
  def handle_event("set_audience", %{"id" => id, "who" => who}, socket),
    do: act(socket, &ArcEntryRepo.set_audience(Repo, &1, who_atom(who)), id, audience_line(who))

  # ── Authoring (STR-62) ────────────────────────────────────────────────────────
  #
  # The author can propose too, and their proposals are the same object: an entry
  # written here joins the pending list and is accepted or refused like any other.

  def handle_event("authoring_open", _params, socket),
    do: {:noreply, assign(socket, authoring: new_authoring(socket, default_kind(socket)))}

  def handle_event("authoring_cancel", _params, socket),
    do: {:noreply, assign(socket, authoring: nil)}

  def handle_event("authoring_change", params, socket) do
    case socket.assigns.authoring do
      nil ->
        {:noreply, socket}

      a ->
        a =
          if params["kind"] && params["kind"] != a.kind,
            do: new_authoring(socket, params["kind"]),
            else: a

        {:noreply,
         assign(socket,
           authoring: %{
             a
             | statement: Map.get(params, "statement", a.statement),
               because: Map.get(params, "because", a.because),
               until: Map.get(params, "until", a.until),
               and_then: Map.get(params, "and_then", a.and_then),
               target: Map.get(params, "target", a.target),
               scene_id: presence(Map.get(params, "scene_id", a.scene_id)),
               target_known: target_known?(socket, Map.get(params, "target", a.target))
           }
         )}
    end
  end

  def handle_event("authoring_op", %{"op" => op}, socket),
    do: update_authoring(socket, &%{&1 | op: op, picked: nil, was: nil, statement: ""})

  def handle_event("authoring_timing", %{"timing" => timing}, socket),
    do: update_authoring(socket, &%{&1 | timing: timing})

  def handle_event("authoring_never", %{"never" => never}, socket),
    do: update_authoring(socket, &%{&1 | never: never == "true"})

  def handle_event("authoring_who", %{"who" => who}, socket),
    do: update_authoring(socket, &%{&1 | who: who})

  def handle_event("authoring_core", _params, socket),
    do: update_authoring(socket, &%{&1 | core: not &1.core})

  def handle_event("authoring_pick", %{"key" => key}, socket),
    do: update_authoring(socket, &pick(socket, &1, key))

  def handle_event("authoring_propose", params, socket) do
    safe(socket, fn ->
      case socket.assigns.authoring do
        nil ->
          {:noreply, socket}

        a ->
          a = merge_submit(a, params)
          propose(socket, a)

          {:noreply,
           socket
           |> assign(authoring: nil)
           |> put_flash(:info, "Proposed — it's in the list with the rest.")
           |> load()}
      end
    end)
  end

  defp who_atom("there"), do: :there
  defp who_atom(_), do: :everyone

  defp audience_line("there"), do: "Only whoever was there will know it."
  defp audience_line(_), do: "Everyone will come to know it."

  defp update_authoring(socket, fun) do
    case socket.assigns.authoring do
      nil -> {:noreply, socket}
      a -> {:noreply, assign(socket, authoring: fun.(a))}
    end
  end

  # The submit's own params win over the last change event — a fast submit can
  # arrive before the final phx-change round-trips.
  defp merge_submit(a, params) do
    %{
      a
      | statement: Map.get(params, "statement", a.statement),
        because: Map.get(params, "because", a.because),
        until: Map.get(params, "until", a.until),
        and_then: Map.get(params, "and_then", a.and_then),
        target: Map.get(params, "target", a.target),
        scene_id: presence(Map.get(params, "scene_id", a.scene_id))
    }
  end

  # ── Building the authoring state ─────────────────────────────────────────────

  defp default_kind(%{assigns: %{tab: "world"}}), do: "fact"
  defp default_kind(_socket), do: "fact"

  defp new_authoring(socket, kind) do
    world = socket.assigns.tab == "world"
    kind = if world and kind not in ["fact", "rule"], do: "fact", else: kind

    base = %{
      world: world,
      subject_id: if(world, do: socket.assigns.campaign_id, else: socket.assigns.tab),
      subject_name: authoring_subject_name(socket, world),
      colour: authoring_colour(socket, world),
      kind: kind,
      op: default_op(kind),
      items: [],
      picked: nil,
      picker_label: picker_label(kind),
      was: nil,
      statement: "",
      because: "",
      until: "",
      and_then: "",
      never: false,
      timing: "now",
      scene_id: nil,
      scenes: authoring_scenes(socket),
      core: false,
      audience_label: "Nobody",
      audience_secret: false,
      who: "everyone",
      target: "",
      target_known: false,
      satisfied_disabled: false
    }

    %{base | items: items_for(socket, base), was: initial_was(socket, base)}
  end

  defp default_op(kind) when kind in ["temperament", "cover"], do: "change"
  defp default_op(_kind), do: "add"

  defp picker_label(kind) when kind in ["refusal", "compulsion"], do: "Which line"
  defp picker_label("relationship"), do: "Which direction"
  defp picker_label(_), do: "Which one"

  defp authoring_subject_name(socket, true), do: socket.assigns.campaign_name

  defp authoring_subject_name(socket, false) do
    case Enum.find(socket.assigns.cast, &(&1.id == socket.assigns.tab)) do
      %{name: name} -> name
      _ -> "This character"
    end
  end

  defp authoring_colour(_socket, true), do: "var(--bcm)"

  defp authoring_colour(socket, false) do
    case Enum.find(socket.assigns.cast, &(&1.id == socket.assigns.tab)) do
      %{sheet: sheet} -> Voice.of_sheet(sheet)
      _ -> Voice.neutral()
    end
  end

  # Closed scenes for "in a scene" — labelled by position, the way the campaign
  # screen names them.
  defp authoring_scenes(socket) do
    case Library.payload(Library.get(socket.assigns.campaign_id)) do
      %{scenes: scenes} when is_list(scenes) ->
        scenes
        |> Enum.with_index(1)
        |> Enum.map(fn {id, n} -> %{id: to_string(id), label: "Scene #{n}"} end)

      _ ->
        []
    end
  end

  # The list an operation picks from. Everything is read off the *effective* sheet —
  # canon arc applied — because that is the truth an authored change supersedes.
  defp items_for(_socket, %{op: "add"}), do: []

  defp items_for(socket, %{world: true}) do
    Repo
    |> ArcEntryRepo.list_canon(socket.assigns.campaign_id, "world")
    |> Enum.map(&%{key: &1.statement, label: &1.statement})
  end

  defp items_for(socket, %{kind: "fact"}) do
    case effective_sheet(socket) do
      nil -> []
      sheet -> Enum.map(sheet.facts || [], &%{key: &1.statement, label: &1.statement})
    end
  end

  defp items_for(socket, %{kind: kind}) when kind in ["refusal", "compulsion"] do
    case effective_sheet(socket) do
      nil ->
        []

      sheet ->
        for b <- sheet.boundaries || [], to_string(b.direction) == kind do
          %{
            key: b.topic,
            label: b.topic,
            rule: if(kind == "refusal", do: :bound, else: :compel),
            sublabel: if(b.stance == :closed, do: "Never")
          }
        end
    end
  end

  defp items_for(socket, %{kind: "relationship"}) do
    case effective_sheet(socket) do
      nil ->
        []

      sheet ->
        me = authoring_subject_name(socket, false)

        for r <- sheet.relationships || [] do
          %{key: relationship_key(r), label: to_string(r.target), prefix: "#{me} → "}
        end
    end
  end

  defp items_for(_socket, _base), do: []

  defp relationship_key(r), do: to_string(r.target_id || r.target)

  defp initial_was(socket, %{world: false, kind: kind, op: "change"})
       when kind in ["temperament", "cover"] do
    case effective_sheet(socket) do
      nil -> nil
      sheet -> Map.get(sheet, String.to_existing_atom(kind))
    end
  end

  defp initial_was(_socket, _base), do: nil

  defp effective_sheet(socket) do
    case Enum.find(socket.assigns.cast, &(&1.id == socket.assigns.tab)) do
      %{sheet: %CharacterSheet{} = sheet} -> Effective.sheet(sheet, socket.assigns.tab)
      _ -> nil
    end
  end

  # Picking fills in what the pick determines: the struck-through current value, a
  # line's written condition and consequence, whether satisfying it is even possible.
  defp pick(socket, %{kind: kind} = a, key) when kind in ["refusal", "compulsion"] do
    sheet = effective_sheet(socket)
    line = sheet && Enum.find(sheet.boundaries || [], &(&1.topic == key))

    %{
      a
      | picked: key,
        was: if(a.op == "change", do: key),
        statement: if(a.op == "satisfied", do: to_string((line && line.after_release) || "")),
        until: to_string((line && line.condition) || ""),
        and_then: to_string((line && line.after_release) || ""),
        never: (line && line.stance == :closed) || false,
        satisfied_disabled: (line && line.stance == :closed) || false
    }
  end

  defp pick(socket, %{kind: "relationship"} = a, key) do
    sheet = effective_sheet(socket)
    rel = sheet && Enum.find(sheet.relationships || [], &(relationship_key(&1) == key))

    %{
      a
      | picked: key,
        was: rel && to_string(rel.descriptor || ""),
        target: to_string((rel && rel.target) || ""),
        target_known: true
    }
  end

  defp pick(_socket, a, key), do: %{a | picked: key, was: if(a.op == "change", do: key)}

  defp target_known?(socket, target) do
    down = target |> to_string() |> String.trim() |> String.downcase()
    down != "" and Enum.any?(socket.assigns.cast, &(String.downcase(&1.name) == down))
  end

  # ── Writing the proposal ─────────────────────────────────────────────────────

  defp propose(socket, %{world: true} = a) do
    ArcEntryRepo.put_world(
      Repo,
      %WorldArcEntry{
        kind: if(a.op == "change", do: :revision, else: :discovery),
        sheet_field: if(a.kind == "rule", do: "rules"),
        statement: a.statement,
        reason: presence(a.because),
        author: author_name(socket),
        operation: safe_op(a.op),
        timing: timing_atom(a),
        replaces: a.picked,
        source_scene_id: a.scene_id,
        concealed: a.who != "everyone",
        audience: world_audience(a)
      },
      socket.assigns.campaign_id
    )
  end

  defp propose(socket, %{kind: kind} = a) when kind in ["refusal", "compulsion"] do
    entry =
      case a.op do
        # Satisfaction is a change of state, not of value: the consequence was
        # written in advance, and the entry is a release like the ones play files.
        "satisfied" ->
          %ArcEntry{
            kind: :release,
            sheet_field: "boundaries",
            statement: a.statement,
            released_topic: a.picked,
            line_condition: presence(a.until),
            condition_met: true,
            operation: :satisfied
          }

        op ->
          %ArcEntry{
            kind: if(op == "add", do: :discovery, else: :revision),
            sheet_field: "boundaries",
            statement: a.statement,
            replaces: a.picked,
            direction: String.to_existing_atom(kind),
            line_condition: if(a.never, do: nil, else: presence(a.until)),
            after_release: if(a.never, do: nil, else: presence(a.and_then)),
            operation: safe_op(op)
          }
      end

    put_character(socket, %{
      entry
      | reason: presence(a.because),
        author: author_name(socket),
        timing: timing_atom(a),
        source_scene_id: a.scene_id
    })
  end

  defp propose(socket, %{kind: "relationship"} = a) do
    put_character(socket, %ArcEntry{
      kind: if(a.op == "add", do: :discovery, else: :revision),
      sheet_field: "relationships",
      statement: a.statement,
      replaces: a.was,
      target: presence(a.target),
      target_id: if(a.op != "add", do: a.picked),
      reason: presence(a.because),
      author: author_name(socket),
      operation: safe_op(a.op),
      timing: timing_atom(a),
      source_scene_id: a.scene_id
    })
  end

  defp propose(socket, %{kind: "fact"} = a) do
    put_character(socket, %ArcEntry{
      kind: if(a.op == "add", do: :discovery, else: :revision),
      sheet_field: "facts",
      statement: if(a.op == "remove", do: a.picked, else: a.statement),
      replaces: a.picked,
      core: a.core,
      reason: presence(a.because),
      author: author_name(socket),
      operation: safe_op(a.op),
      timing: timing_atom(a),
      source_scene_id: a.scene_id
    })
  end

  # The simple case: a field holding one value, like temperament or cover.
  defp propose(socket, a) do
    put_character(socket, %ArcEntry{
      kind: :revision,
      sheet_field: a.kind,
      statement: a.statement,
      replaces: a.was,
      reason: presence(a.because),
      author: author_name(socket),
      operation: :change,
      timing: timing_atom(a),
      source_scene_id: a.scene_id
    })
  end

  defp put_character(socket, entry),
    do: ArcEntryRepo.put(Repo, entry, socket.assigns.tab)

  defp world_audience(%{who: "there"}), do: %Polyphony.Authoring.Audience{scene: true}
  defp world_audience(_a), do: nil

  defp timing_atom(%{timing: "always"}), do: :always
  defp timing_atom(%{scene_id: id}) when is_binary(id), do: :scene
  defp timing_atom(_), do: :now

  defp safe_op("add"), do: :add
  defp safe_op("change"), do: :change
  defp safe_op("remove"), do: :remove
  defp safe_op("satisfied"), do: :satisfied
  defp safe_op(_), do: nil

  defp presence(nil), do: nil
  defp presence(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)

  defp author_name(socket) do
    case socket.assigns.current_user do
      %{username: username} when is_binary(username) and username != "" -> username
      %{email: email} when is_binary(email) -> email
      _ -> "the author"
    end
  end

  defp act(socket, fun, id, msg) do
    safe(socket, fn ->
      fun.(String.to_integer(id))
      {:noreply, socket |> assign(editing: nil) |> put_flash(:info, msg) |> load()}
    end)
  end

  defp made_true(1), do: "1 change made true."
  defp made_true(n), do: "#{n} changes made true."

  # ── Render ────────────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <Screens.ArcReview.screen
      campaign_id={@campaign_id}
      campaign_name={@campaign_name}
      cast={@cast}
      groups={@groups}
      world={@world}
      per_character={@per_character}
      tab={@tab}
      drawer={@drawer}
      editing={@editing}
      authoring={@authoring}
      current_user={@current_user}
    />
    """
  end
end

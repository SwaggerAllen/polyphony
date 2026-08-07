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
  alias Polyphony.Owner
  alias Polyphony.ReadModels.ArcEntry, as: ArcEntryRepo
  alias Polyphony.Permissions
  alias PolyphonyWeb.{Guard, Screens}

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
       drawer: false
     )
     |> load()}
  end

  def handle_params(params, _uri, socket),
    do: {:noreply, assign(socket, tab: params["tab"] || default_tab(socket))}

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

  def handle_event("accept", %{"id" => id}, socket),
    do: act(socket, &ArcEntryRepo.accept(Repo, &1), id, "Made true.")

  def handle_event("reject", %{"id" => id}, socket),
    do: act(socket, &ArcEntryRepo.reject(Repo, &1), id, "Left as it was.")

  # Accept everything for one subject — the row's own fast path, and what the scene
  # gate's "accept all and carry on" resolves to.
  def handle_event("accept_all", %{"subject" => subject}, socket) do
    safe(socket, fn ->
      type = if subject == socket.assigns.campaign_id, do: "world", else: "character"
      count = ArcEntryRepo.accept_all(Repo, subject, type)

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
      current_user={@current_user}
    />
    """
  end
end

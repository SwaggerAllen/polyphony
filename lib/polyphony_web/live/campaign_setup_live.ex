defmodule PolyphonyWeb.CampaignSetupLive do
  @moduledoc "V8 (campaign setup): name, premise, roster from owned characters, optional bible."
  use PolyphonyWeb, :live_view

  alias Polyphony.{Library, Owner}

  def mount(_params, _session, socket) do
    owner = Owner.of(socket.assigns.current_user)
    chars = Library.list_for_owner(owner) |> Enum.filter(&(&1.kind == "character"))
    bibles = Library.list_for_owner(owner) |> Enum.filter(&(&1.kind == "world_bible"))
    {:ok, assign(socket, page_title: "New campaign", owner: owner, chars: chars, bibles: bibles)}
  end

  def handle_event("create", params, socket) do
    safe(socket, fn ->
      character_ids = params |> Map.get("characters", %{}) |> Map.keys()

      bible_id =
        case params["bible_id"] do
          "" -> nil
          v -> v
        end

      payload = %{
        kind: :campaign,
        name: params["name"],
        premise: params["premise"],
        character_ids: character_ids,
        bible_id: bible_id,
        scenes: []
      }

      entry = Library.put(%{owner: socket.assigns.owner, kind: "campaign", payload: payload})
      {:noreply, redirect(socket, to: ~p"/campaigns/#{entry.id}")}
    end)
  end

  def render(assigns) do
    ~H"""
    <h1>New campaign</h1>
    <div class="card">
      <form phx-submit="create">
        <label>Name</label>
        <input type="text" name="name" required />
        <label>Premise <span class="faint">(what the story is about)</span></label>
        <textarea name="premise"></textarea>

        <label>Cast <span class="faint">(pick from your characters)</span></label>
        <div :if={@chars == []} class="faint">No characters yet — create some in your library first.</div>
        <label :for={c <- @chars} class="row" style="align-items:center;gap:.5rem;font-size:.95rem;">
          <input type="checkbox" name={"characters[#{name(c)}]"} value="1" style="width:auto;" />
          <%= name(c) %>
        </label>

        <label>World bible <span class="faint">(optional)</span></label>
        <select name="bible_id">
          <option value="">— none —</option>
          <option :for={b <- @bibles} value={b.id}><%= name(b) %></option>
        </select>

        <br /><br />
        <button class="btn" type="submit">Create campaign</button>
      </form>
    </div>
    """
  end

  defp name(e) do
    case Library.payload(e) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> "Untitled"
    end
  end
end

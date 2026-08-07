defmodule PolyphonyWeb.CampaignBulkGenLiveTest do
  @moduledoc """
  Bulk-filling pending stubs, driven by the offline Mock.

  It lives on the campaign's cast rather than in the library because characters are
  written *inside* a campaign under the redesigned IA (`ux/polyphony-library.html`
  §00) — the pending ones are that campaign's pending ones, and the button belongs
  next to the pills that say so. Stubs arrive in batches, from other people's
  relationships, so one press beats twenty trips through the editor.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.Library
  alias Polyphony.Owner
  alias Polyphony.Authoring.{CharacterSheet, Stub}

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp stub(user, payload),
    do: Library.put(%{owner: Owner.of(user), kind: "character", payload: payload})

  test "fill-them-in finalizes every stub in the cast, keeping names",
       %{conn: conn, user: user} do
    ghost = stub(user, Stub.new("Ghost", "haunts her"))
    bram = stub(user, Stub.new("Bram", "estranged mentor"))
    # A finalized character is left alone (not pending).
    mira = stub(user, %CharacterSheet{name: "Mira", status: :full})

    campaign =
      Library.put(%{
        owner: Owner.of(user),
        kind: "campaign",
        payload: %{
          kind: :campaign,
          name: "The Salt Line",
          character_ids: [ghost.id, bram.id, mira.id],
          scenes: []
        }
      })

    {:ok, view, html} = live(conn, ~p"/campaigns/#{campaign.id}?tab=cast")
    assert html =~ "2 pending characters"

    view |> element("button[phx-click=generate_pending]") |> render_click()
    generate(view)

    g = Library.payload(Library.get(ghost.id))
    b = Library.payload(Library.get(bram.id))

    # Both finalized with generated content, original names preserved.
    assert g.status == :full and is_binary(g.premise) and g.premise != ""
    assert b.status == :full
    assert g.name == "Ghost" and b.name == "Bram"

    # The banner is gone, because there's nothing left pending.
    refute render(view) =~ "pending character"
  end
end

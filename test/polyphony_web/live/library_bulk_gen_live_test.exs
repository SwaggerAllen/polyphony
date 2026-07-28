defmodule PolyphonyWeb.LibraryBulkGenLiveTest do
  @moduledoc "Bulk-generating pending stubs from the library, driven by the offline Mock."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
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

  test "generate-all-pending fills and finalizes every stub, keeping names",
       %{conn: conn, user: user} do
    ghost = stub(user, Stub.new("Ghost", "haunts her"))
    bram = stub(user, Stub.new("Bram", "estranged mentor"))
    # A finalized character is left alone (not pending).
    stub(user, %CharacterSheet{name: "Mira", status: :full})

    {:ok, view, html} = live(conn, ~p"/library")
    assert html =~ "pending characters"
    assert html =~ ">2</strong>"

    view |> element("button[phx-click=generate_pending]") |> render_click()
    render_async(view)

    g = Library.payload(Library.get(ghost.id))
    b = Library.payload(Library.get(bram.id))

    # Both finalized with generated content, original names preserved.
    assert g.status == :full and is_binary(g.premise) and g.premise != ""
    assert b.status == :full
    assert g.name == "Ghost" and b.name == "Bram"

    # The pending banner is gone.
    refute render(view) =~ "pending character"
  end
end

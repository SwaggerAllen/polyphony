defmodule Polyphony.StubGenTest do
  @moduledoc """
  What it takes to become castable.

  `:full` is a claim `SceneControl` trusts — it is the whole basis on which a character
  is allowed into a scene — and `finalize/2` used to make it on any `{:ok, _}` from the
  provider, including one carrying an empty object. That produced a castable character
  with no premise, no voice and no temperament: somebody the Director would then be
  asked to write turns for, from nothing.

  Found while wiring "✦ Write them in", which walks a freshly-generated walk-on straight
  onto the stage. The screen guards on `:full` before admitting, which is right and was
  no help at all when `:full` was being handed out for a blank answer.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.Library
  alias Polyphony.Owner
  alias Polyphony.Authoring.{CharacterSheet, StubGen}

  setup do
    previous = Application.get_env(:polyphony, :llm)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    %{owner: Owner.of(user_fixture())}
  end

  defp stub(owner, attrs \\ %{}) do
    sheet = struct(%CharacterSheet{name: "The bellman", status: :stub, role: "a walk-on"}, attrs)
    Library.put(%{owner: owner, kind: "character", payload: sheet})
  end

  defp answering(body) do
    Application.put_env(:polyphony, :llm,
      provider: Polyphony.LLM.Stub,
      stub_response: {:ok, body}
    )
  end

  test "a real answer promotes them", %{owner: owner} do
    entry = stub(owner)
    answering(Jason.encode!(%{"premise" => "He rings for the tide.", "voice" => "Clipped."}))

    assert :ok = StubGen.finalize(entry, nil)

    sheet = Library.payload(Library.get(entry.id))
    assert sheet.status == :full
    assert sheet.premise == "He rings for the tide."
  end

  test "an empty answer does not", %{owner: owner} do
    entry = stub(owner)
    answering("{}")

    assert :error = StubGen.finalize(entry, nil)

    # Pending is the failure direction that leaves the author something to open and
    # finish, rather than a castable person with nothing on their sheet.
    assert Library.payload(Library.get(entry.id)).status == :stub
  end

  test "a name alone is not a character", %{owner: owner} do
    entry = stub(owner)
    answering(Jason.encode!(%{"name" => "Halden"}))

    # A stub already had a name — that is what a stub *is*. What makes somebody castable
    # is prose the Director can write turns from.
    assert :error = StubGen.finalize(entry, nil)
    assert Library.payload(Library.get(entry.id)).status == :stub
  end

  test "whatever did come back is still kept", %{owner: owner} do
    entry = stub(owner, %{name: ""})
    answering(Jason.encode!(%{"name" => "Halden"}))

    _ = StubGen.finalize(entry, nil)

    # Refusing to promote is not refusing the work: a retry shouldn't pay twice for the
    # same answer. (A stub that *had* a name keeps it — `keep_or/2`, so a walk-on named
    # by the character who invented them isn't renamed behind their back.)
    assert Library.payload(Library.get(entry.id)).name == "Halden"
  end

  test "prose the stub already had counts — this isn't a re-check of the answer alone",
       %{owner: owner} do
    entry = stub(owner, %{premise: "Somebody wrote this by hand."})
    answering("{}")

    # The question is whether the *sheet* is writable-from, not whether this particular
    # call added to it. A half-written stub finished by hand is castable.
    assert :ok = StubGen.finalize(entry, nil)
    assert Library.payload(Library.get(entry.id)).status == :full
  end

  test "a provider error leaves everything alone", %{owner: owner} do
    entry = stub(owner)

    Application.put_env(:polyphony, :llm,
      provider: Polyphony.LLM.Stub,
      stub_response: {:error, :nope}
    )

    assert :error = StubGen.finalize(entry, nil)
    assert Library.payload(Library.get(entry.id)).status == :stub
  end
end

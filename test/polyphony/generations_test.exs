defmodule Polyphony.GenerationsTest do
  @moduledoc """
  A generation you asked for arrives, whether or not you stayed to watch.

  Every ✦ control ran its provider call in a `start_async` task linked to the socket.
  The calls take seconds — long enough to check a message — and when the socket went, so
  did the task. The author came back to a field that never filled in, a button that looks
  untouched, and a bill for the call.

  What's pinned here is the three states a screen can be in when an answer lands, and
  the two ways this could quietly go wrong instead: applying a result **twice**, and
  applying a **stale** one after the author pressed the button again.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Generations, Library, Owner}
  alias Polyphony.Authoring.WorldBible
  alias Polyphony.ReadModels.GenerationRun
  alias Polyphony.Repo

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)

    user = user_fixture()

    entry =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %WorldBible{name: "Saltmarch"}
      })

    %{user: user, entry: entry}
  end

  defp field_request(f),
    do: %{kind: :world_bible, field: f, current: %{"name" => "Saltmarch"}, opts: []}

  defp drain, do: Oban.drain_queue(queue: :generation)

  describe "an answer that arrives while nobody is watching" do
    test "waits, and is handed over on the next look", %{entry: entry} do
      {:ok, _} =
        Generations.request(entry.id, "setting", "autofill.field", field_request("setting"))

      # The tab is gone: nothing is subscribed, and the job runs anyway.
      assert %{success: 1} = drain()

      assert [{"setting", {:ok, value}}] = Generations.take(entry.id)
      assert is_binary(value) and value != ""
    end

    test "is handed over exactly once", %{entry: entry} do
      {:ok, _} =
        Generations.request(entry.id, "setting", "autofill.field", field_request("setting"))

      drain()

      assert [{"setting", _}] = Generations.take(entry.id)

      # Taking deletes. Two tabs, or one tab reloaded twice, must not each apply the
      # same paragraph — that reads as the generation having run twice.
      assert Generations.take(entry.id) == []
    end

    test "arrives in the order the answers did", %{entry: entry} do
      for f <- ~w(setting tone),
          do: {:ok, _} = Generations.request(entry.id, f, "autofill.field", field_request(f))

      drain()

      assert [{"setting", _}, {"tone", _}] = Generations.take(entry.id)
    end
  end

  describe "an answer that arrives while somebody is" do
    test "is broadcast as well as parked", %{entry: entry} do
      Generations.subscribe(entry.id)

      {:ok, _} = Generations.request(entry.id, "tone", "autofill.field", field_request("tone"))
      drain()

      assert_receive {:generation, "tone", {:ok, _}}
    end
  end

  describe "still running" do
    test "is what a reconnect sees, rather than a button that did nothing",
         %{entry: entry} do
      {:ok, _} =
        Generations.request(entry.id, "setting", "autofill.field", field_request("setting"))

      # Before the drain: the job is enqueued and the row says so, which is the spinner
      # a fresh mount puts back.
      assert Generations.running(entry.id) == ["setting"]

      drain()
      assert Generations.running(entry.id) == []
    end
  end

  describe "pressing it again" do
    test "replaces the claim, and the first answer is dropped", %{entry: entry} do
      {:ok, first} =
        Generations.request(entry.id, "tone", "autofill.field", field_request("tone"))

      {:ok, second} =
        Generations.request(entry.id, "tone", "autofill.field", field_request("tone"))

      # One control, one row — the same thing the spinner has always meant.
      assert second.id != first.id
      assert [%{id: id}] = GenerationRun.list(Repo, entry.id)
      assert id == second.id

      # The superseded job's answer lands on a row nobody is waiting for. Delivering it
      # would overwrite the one the author actually waited for.
      Generations.finish(first.id, {:ok, "the stale one"})
      refute_receive {:generation, "tone", {:ok, "the stale one"}}
    end
  end

  describe "a failure" do
    test "is recorded and delivered rather than swallowed", %{entry: entry} do
      Application.put_env(:polyphony, :llm,
        provider: Polyphony.LLM.Stub,
        stub_response: {:error, :nope}
      )

      Generations.subscribe(entry.id)

      {:ok, _} =
        Generations.request(entry.id, "setting", "autofill.field", field_request("setting"))

      # One retry (`max_attempts: 2`), because a transient 502 on a single call is
      # cheap to redo — unlike a whole Quick Build, which takes none.
      drain()

      assert_receive {:generation, "setting", {:error, _}}
      assert [{"setting", {:error, _}}] = Generations.take(entry.id)
    end

    test "an operation nobody implements is a failure, not a crash", %{entry: entry} do
      {:ok, _} = Generations.request(entry.id, "x", "no.such.op", %{})
      drain()

      assert [{"x", {:error, {:unknown_operation, "no.such.op"}}}] = Generations.take(entry.id)
    end
  end
end

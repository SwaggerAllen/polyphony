defmodule Polyphony.FailuresTest do
  @moduledoc "User-facing failures: record, broadcast, retry, and edit-and-resubmit (§12)."
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Polyphony.Repo

  alias Polyphony.{Repo, Failures, Broadcast}
  alias Polyphony.ReadModels.Failure
  alias Polyphony.Jobs.GeneratePacket

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp record(attrs) do
    Failures.record(
      Keyword.merge(
        [
          worker: GeneratePacket,
          scene_id: "S1",
          beat: 2,
          subject: "mira",
          operation: :packet,
          kind: :refusal,
          reason: "refused",
          args: %{
            "scene_id" => "S1",
            "character_id" => "mira",
            "beat" => 2,
            "messages" => [%{"role" => "user", "content" => "go"}]
          }
        ],
        attrs
      ),
      repo: Repo
    )
  end

  test "record persists a failure and defaults editable from the kind" do
    row = record(kind: :refusal)
    assert %Failure{editable: true, retryable: true, status: "open"} = row

    row2 = record(kind: :transport, editable: false)
    assert row2.editable == false
  end

  test "record broadcasts generation.failed to the omniscient viewer with a failure_id" do
    Phoenix.PubSub.subscribe(Polyphony.PubSub, Broadcast.topic("S1", :omniscient))
    row = record([])

    assert_receive {:polyphony_event, msg}
    assert msg.type == "generation.failed"
    assert msg.failure_id == row.id
    assert msg.editable == true and msg.retryable == true
  end

  test "list_open returns open failures for a scene" do
    record([])
    assert [%Failure{}] = Failures.list_open("S1", repo: Repo)
  end

  test "retry re-enqueues the exact work and resolves the failure" do
    row = record([])

    assert {:ok, %Failure{status: "resolved"}} = Failures.retry(row.id, repo: Repo)
    assert_enqueued(worker: GeneratePacket, args: %{"character_id" => "mira"})
  end

  test "retry_edited merges edits into the re-enqueued args (refusal edit-and-resubmit)" do
    row = record([])
    edited = [%{"role" => "user", "content" => "rephrased, please continue"}]

    assert {:ok, %Failure{status: "resolved"}} =
             Failures.retry_edited(row.id, %{"messages" => edited}, repo: Repo)

    assert_enqueued(worker: GeneratePacket, args: %{"messages" => edited})
  end

  test "retrying an already-resolved failure is rejected" do
    row = record([])
    {:ok, _} = Failures.retry(row.id, repo: Repo)
    assert {:error, :already_resolved} = Failures.retry(row.id, repo: Repo)
  end
end

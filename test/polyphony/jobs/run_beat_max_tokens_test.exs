defmodule Polyphony.Jobs.RunBeatMaxTokensTest do
  @moduledoc "The Director decides with the campaign's LLM settings (thinking off, generous budget)."
  use ExUnit.Case, async: false

  alias Polyphony.{App, Library, Repo}
  alias Polyphony.Commands.{OpenScene, EnterCharacter}
  alias Polyphony.Jobs.RunBeat

  defmodule CapturingDirector do
    @behaviour Polyphony.LLM.Provider

    @decision Jason.encode!(%{
                "control" => "yield_to_user",
                "cast" => [],
                "world_events" => [],
                "proposal_rulings" => []
              })

    @impl true
    def complete(_messages, opts) do
      if pid = Application.get_env(:polyphony, :test_reporter),
        do: send(pid, {:director_opts, opts})

      {:ok, @decision}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: CapturingDirector, models: %{})
    Application.put_env(:polyphony, :test_reporter, self())

    on_exit(fn ->
      Application.put_env(:polyphony, :llm, previous)
      Application.delete_env(:polyphony, :test_reporter)
    end)

    :ok
  end

  test "the Director call carries the campaign's token budget and thinking setting" do
    campaign =
      Library.put(%{
        owner_id: "1",
        kind: "campaign",
        payload: %{llm: %{director_max_tokens: 3000, director_thinking: false}}
      })

    scene = "rbs-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, campaign_id: campaign.id, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "mira", beat: 1})

    Oban.Testing.with_testing_mode(:inline, fn ->
      RunBeat.enqueue(%{"scene_id" => scene, "beat" => 2, "control_hint" => "yield_to_user"})
    end)

    assert_received {:director_opts, opts}
    assert Keyword.get(opts, :max_tokens) == 3000
    assert Keyword.get(opts, :thinking) == false
  end
end

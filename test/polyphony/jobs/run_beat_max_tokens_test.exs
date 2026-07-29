defmodule Polyphony.Jobs.RunBeatMaxTokensTest do
  @moduledoc "The Director decides with a generous output budget (thinking shares it, §3)."
  use ExUnit.Case, async: false

  alias Polyphony.{App, Repo}
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

    Application.put_env(:polyphony, :llm,
      provider: CapturingDirector,
      models: %{},
      director_max_tokens: 3000
    )

    Application.put_env(:polyphony, :test_reporter, self())

    on_exit(fn ->
      Application.put_env(:polyphony, :llm, previous)
      Application.delete_env(:polyphony, :test_reporter)
    end)

    :ok
  end

  test "the Director call carries the configured max_tokens" do
    scene = "rbmt-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "mira", beat: 1})

    Oban.Testing.with_testing_mode(:inline, fn ->
      RunBeat.enqueue(%{"scene_id" => scene, "beat" => 2, "control_hint" => "yield_to_user"})
    end)

    assert_received {:director_opts, opts}
    assert Keyword.get(opts, :max_tokens) == 3000
  end
end

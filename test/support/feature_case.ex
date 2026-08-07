defmodule PolyphonyWeb.FeatureCase do
  @moduledoc """
  Test case for real-browser (Wallaby) feature tests. `use Wallaby.Feature` checks
  out the Ecto sandbox, starts a browser session (passed in as `session`), and wires
  the sandbox metadata so the browser's requests share the test's DB connection.

  Tagged `:feature` and excluded from the default suite (see test/test_helper.exs);
  run with `mix test --only feature`. Requires a Chromium + matching chromedriver
  (configured in config/test.exs).
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.Feature

      import PolyphonyWeb.FeatureCase

      alias Polyphony.App
      alias PolyphonyCore.Commands.{OpenScene, EnterCharacter}
    end
  end

  @doc "Insert a confirmed user directly into the (sandboxed) Repo."
  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      email: "u#{n}@x.io",
      username: "user#{n}",
      role: "user",
      attested_adult_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)
    }

    {:ok, user} =
      defaults
      |> Map.merge(Map.new(attrs))
      |> Polyphony.Accounts.User.registration_changeset()
      |> Polyphony.Repo.insert()

    user
  end

  @doc """
  Sign the browser session in as `user` by visiting a magic-link token URL — the
  same `/auth/verify/:token` route the emailed link uses. Returns the session.
  """
  def sign_in(session, user) do
    token = PolyphonyWeb.Auth.sign_token(user.id)
    Wallaby.Browser.visit(session, "/auth/verify/#{token}")
  end

  @doc "Open a scene with a three-character cast; returns the scene id."
  def scene_with_cast do
    scene = "feat-" <> Integer.to_string(System.unique_integer([:positive]))

    :ok =
      Polyphony.App.dispatch(%PolyphonyCore.Commands.OpenScene{scene_id: scene, opened_beat: 0})

    for c <- ~w(mira otto cara) do
      :ok =
        Polyphony.App.dispatch(%PolyphonyCore.Commands.EnterCharacter{
          scene_id: scene,
          character_id: c,
          beat: 1
        })
    end

    scene
  end
end

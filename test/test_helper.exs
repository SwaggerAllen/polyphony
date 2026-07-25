# Real-browser feature tests (Wallaby) are excluded by default — they need a
# Chromium + chromedriver and are slower. Run them with `mix test --only feature`.
ExUnit.start(exclude: [:feature])

# Only boot Wallaby (which requires chromedriver) when feature tests are actually
# selected — so the default suite and the CI unit job need no browser.
run_features? =
  ExUnit.configuration()
  |> Keyword.get(:include, [])
  |> Enum.any?(fn
    :feature -> true
    {:feature, _} -> true
    _ -> false
  end)

if run_features?, do: {:ok, _} = Application.ensure_all_started(:wallaby)

# DB-backed tests use the SQL sandbox; pure tests (visibility, membership set,
# aggregate) touch neither the Repo nor the Commanded runtime.
Ecto.Adapters.SQL.Sandbox.mode(Polyphony.Repo, :manual)

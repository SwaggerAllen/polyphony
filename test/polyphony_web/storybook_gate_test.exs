defmodule PolyphonyWeb.StorybookGateTest do
  @moduledoc """
  Whether `/storybook` exists on a given deployment, and when that is decided.

  It was decided at **image build**, by `Application.compile_env(:polyphony, :storybook)`
  in the router. `config/config.exs` sets that to `false`, so every release compiled the
  routes out — and `config/runtime.exs` then read `STORYBOOK` and set it `true`, which
  the release's config provider compares against the baked value at boot. The result was
  not a storybook you couldn't reach; it was an app that **would not start**:

      the application :polyphony has a different value set for key :storybook during
      runtime compared to compile time

  No value in a hosting UI could fix it, in either scope, because nothing on the
  compile-time path read the variable. Turning the feature on took the deployment down.

  So the gate is a **request-time** one now, exactly like `/dev/mailbox` — whose own
  comment in the router already made the argument: *a compile-time flag is fixed at
  image build, long before anyone decides to turn it on.*
  """
  use PolyphonyWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:polyphony, :storybook)
    on_exit(fn -> Application.put_env(:polyphony, :storybook, previous) end)
    :ok
  end

  test "on, it serves — and the routes exist to be served", %{conn: conn} do
    Application.put_env(:polyphony, :storybook, true)

    assert get(conn, "/storybook").status in [200, 302]
  end

  test "off, it is a 404 — the catalogue isn't on this deployment", %{conn: conn} do
    Application.put_env(:polyphony, :storybook, false)

    # 404 rather than 403: there is nothing here to be granted access to. Same answer
    # the mailbox gives when it isn't configured.
    assert get(conn, "/storybook").status == 404
  end

  test "and flipping it takes effect without a rebuild", %{conn: conn} do
    Application.put_env(:polyphony, :storybook, false)
    assert get(conn, "/storybook").status == 404

    # The whole point. Under `compile_env` this assertion could not exist: the routes
    # were either in the binary or they weren't, and the running system had no say.
    Application.put_env(:polyphony, :storybook, true)
    assert get(conn, "/storybook").status in [200, 302]
  end

  test "the stories are compiled into the backend, not read off disk at request time" do
    # `phoenix_storybook` is `:eager` outside dev, so the catalogue is baked into
    # `PolyphonyWeb.Storybook` at build time. A missing `storybook/` directory is not an
    # error there — `Entries.content_tree/1` returns `[]` — so a release that failed to
    # copy it would serve an empty catalogue and say nothing. `PolyphonyWeb.Storybook`
    # raises at compile time for that reason; this is the other half, checking the
    # stories actually made it in.
    assert {:ok, _} = PolyphonyWeb.Storybook.load_story("kit/chk")
    assert PolyphonyWeb.Storybook.content_tree() != []
  end
end

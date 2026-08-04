defmodule Polyphony.EndpointConfigTest do
  @moduledoc """
  What `config/runtime.exs` resolves the endpoint's host to.

  Every URL the app generates is built from this one value — including the magic
  link, and sign-in is magic-link only. Getting it wrong is not cosmetic and it is
  not loud: the sign-in page works, the mail arrives, the link points at a machine
  the recipient does not have. That combination is why this is tested against the
  real file rather than trusted to a comment.
  """
  use ExUnit.Case, async: false

  @base %{
    "SECRET_KEY_BASE" => String.duplicate("x", 64),
    "DATABASE_URL" => "postgres://u:p@localhost/db"
  }

  @host_vars ~w(PHX_HOST APP_DOMAIN APP_URL CHECK_ORIGIN)

  # A clean host environment each time: these are process-global, so a value left by
  # a previous case would resolve a host this one never asked for.
  defp read_prod(extra) do
    saved = Map.new(@host_vars ++ Map.keys(@base), &{&1, System.get_env(&1)})
    Enum.each(@host_vars, &System.delete_env/1)
    System.put_env(Map.merge(@base, extra))

    try do
      Config.Reader.read!("config/runtime.exs", env: :prod)
    after
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  defp endpoint(extra), do: read_prod(extra) |> get_in([:polyphony, PolyphonyWeb.Endpoint])

  defp host(extra), do: endpoint(extra)[:url][:host]

  describe "the host every generated URL is built from" do
    test "PHX_HOST, when set" do
      assert host(%{"PHX_HOST" => "polyphony.example.com"}) == "polyphony.example.com"
    end

    test "falls back to the platform's own domain" do
      # App Platform publishes this. Falling back to it can only improve on the
      # alternative, which is `localhost` — always wrong in prod.
      assert host(%{"APP_DOMAIN" => "polyphony-h7sgq.ondigitalocean.app"}) ==
               "polyphony-h7sgq.ondigitalocean.app"
    end

    test "and to the host inside the platform's URL, which is the same fact URL-shaped" do
      assert host(%{"APP_URL" => "https://polyphony-h7sgq.ondigitalocean.app"}) ==
               "polyphony-h7sgq.ondigitalocean.app"
    end

    test "a whole URL pasted where a host belongs is unwrapped" do
      # Left alone this produces `https://https://polyphony.example.com/auth/verify/…`
      # in every link — including the one that is the only way to sign in.
      assert host(%{"PHX_HOST" => "https://polyphony.example.com/"}) == "polyphony.example.com"
    end

    test "blank counts as unset, rather than as an empty host" do
      # `${APP_DOMAIN}` that expanded to nothing arrives as `""`, and `"" || fallback`
      # is `""` in Elixir — so the naive chain keeps it and generates `https:///…`,
      # which is not a URL at all and warns about nothing.
      assert host(%{"PHX_HOST" => "", "APP_DOMAIN" => "  "}) == "localhost"

      assert host(%{"PHX_HOST" => "", "APP_DOMAIN" => "app.ondigitalocean.app"}) ==
               "app.ondigitalocean.app"
    end

    test "PHX_HOST wins over the platform's guess" do
      # A custom domain is the deliberate choice; the platform's `*.ondigitalocean.app`
      # keeps working alongside it, so preferring it would quietly ignore the setting.
      assert host(%{
               "PHX_HOST" => "polyphony.example.com",
               "APP_DOMAIN" => "polyphony-h7sgq.ondigitalocean.app"
             }) == "polyphony.example.com"
    end

    test "localhost is warned about, loudly" do
      warning = ExUnit.CaptureIO.capture_io(fn -> read_prod(%{}) end)

      # The quiet version of this failure is a sign-in page that works, mail that
      # arrives, and a link to nowhere — so the boot log is the only place it can be
      # caught before a person tries to sign in.
      assert warning =~ "WARNING PHX_HOST is unset"
      assert host(%{}) == "localhost"
    end

    test "a resolved host is not warned about" do
      warning =
        ExUnit.CaptureIO.capture_io(fn -> read_prod(%{"PHX_HOST" => "polyphony.example.com"}) end)

      refute warning =~ "PHX_HOST"
    end
  end

  describe "the websocket origin check" do
    test "defaults to the resolved host over both schemes" do
      assert endpoint(%{"PHX_HOST" => "polyphony.example.com"})[:check_origin] ==
               ["https://polyphony.example.com", "http://polyphony.example.com"]
    end

    test "follows the platform fallback too, rather than being left on localhost" do
      # Otherwise the fallback would fix the links and leave every LiveView button
      # dead, which is a worse failure than the one it solved.
      assert endpoint(%{"APP_DOMAIN" => "app.ondigitalocean.app"})[:check_origin] ==
               ["https://app.ondigitalocean.app", "http://app.ondigitalocean.app"]
    end

    test "an explicit list is taken verbatim, trimmed" do
      assert endpoint(%{"CHECK_ORIGIN" => "https://a.example.com, //*.example.com"})[
               :check_origin
             ] == ["https://a.example.com", "//*.example.com"]
    end

    test "can be switched off for bring-up, and back to the framework default" do
      assert endpoint(%{"CHECK_ORIGIN" => "false"})[:check_origin] == false
      assert endpoint(%{"CHECK_ORIGIN" => "true"})[:check_origin] == true
    end
  end
end

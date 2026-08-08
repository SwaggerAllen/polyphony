defmodule Polyphony.CrashTest do
  @moduledoc """
  The reporter seam (STR-55) — that it is wired, that it is off by default, and that it
  can never be the thing that breaks a request.

  What this deliberately doesn't do is send anything. The value of a crash reporter is
  almost entirely in *what is in the payload*, which `Polyphony.RedactTest` covers
  against real tokens; the value here is the three properties that would otherwise only
  be discovered in production, when the app is already broken.
  """
  use ExUnit.Case, async: false

  alias Polyphony.Crash

  describe "off unless a DSN says otherwise" do
    test "no DSN means no reporting" do
      # Test and dev, and any deploy that hasn't configured one. The alternative is a
      # reporter that has to be stubbed in every test touching an error path — and the
      # tests that touch error paths are exactly the ones worth keeping cheap to write.
      assert Application.get_env(:sentry, :dsn) in [nil, ""]
      refute Crash.enabled?()
    end

    test "the switch is the DSN itself, not a flag beside it" do
      # Two settings means a deploy can be configured on with nowhere to send, which
      # looks identical to a working reporter right up until you need one.
      Application.put_env(:sentry, :dsn, "https://public@example.invalid/1")
      assert Crash.enabled?()
    after
      Application.put_env(:sentry, :dsn, nil)
    end

    test "reporting while off is a no-op that still returns :ok" do
      assert Crash.report(%RuntimeError{message: "nope"}) == :ok
    end
  end

  describe "what actually goes over the wire" do
    setup do
      # Collects the assembled event instead of posting it. This is the difference
      # between testing that `Polyphony.Redact` works and testing that it *runs*: a
      # redactor written, tested and never wired in looks exactly like one that works,
      # and no other test in the suite would tell them apart.
      Sentry.Test.start_collecting()
      :ok
    end

    test "a magic link, an invite and an address are all gone from the payload" do
      token = PolyphonyWeb.Auth.sign_token(7)
      invite = "Yy4XkQ2mBvLpNc8TzRw1aHjK"

      Crash.report(
        %RuntimeError{message: "failed following /auth/verify/#{token} for allen@pm.me"},
        extra: %{
          request_url: "https://polyphony.app/auth/verify/#{token}",
          params: %{"invite_token" => invite},
          email: "allen@pm.me"
        }
      )

      [event] = Sentry.Test.pop_sentry_reports()
      payload = inspect(event, limit: :infinity)

      refute payload =~ token
      refute payload =~ invite
      refute payload =~ "allen@pm.me"
      assert payload =~ "a***@pm.me"
    end

    test "and the transcript is still there, which is the decision" do
      # The recorded non-ask. If this ever fails, read `Polyphony.Redact`'s moduledoc
      # before fixing it — a dev is not a character, and a crash report has no audience
      # inside the story.
      Crash.report(%RuntimeError{message: "boom"},
        extra: %{transcript: "Halden doesn't know about the ledger."}
      )

      [event] = Sentry.Test.pop_sentry_reports()
      assert inspect(event, limit: :infinity) =~ "Halden doesn't know about the ledger."
    end

    test "SafeEvent reports the failure it is busy hiding" do
      # The ticket in one test. `safe/2` exists to turn a raise into a flash, which is
      # right for the author and is precisely what made these failures invisible to
      # everybody else.
      socket = %Phoenix.LiveView.Socket{assigns: %{flash: %{}, __changed__: %{}}}

      assert {:noreply, flashed} =
               PolyphonyWeb.SafeEvent.safe(socket, fn -> raise "the button did nothing" end)

      assert flashed.assigns.flash != %{}
      assert [event] = Sentry.Test.pop_sentry_reports()
      assert inspect(event, limit: :infinity) =~ "the button did nothing"
    end

    test "a throw is reported too, not just a raise" do
      # `capture_exception` wants an exception, and a throw or an exit is neither — the
      # two kinds of failure nobody writes a test for are the two that get dropped.
      socket = %Phoenix.LiveView.Socket{assigns: %{flash: %{}, __changed__: %{}}}

      assert {:noreply, _} =
               PolyphonyWeb.SafeEvent.safe(socket, fn -> throw(:no_such_character) end)

      assert [event] = Sentry.Test.pop_sentry_reports()
      assert inspect(event, limit: :infinity) =~ "no_such_character"
    end
  end

  describe "it can never take down what it is reporting on" do
    test "reporting an odd payload is still :ok" do
      # `report/2` rescues its own failures, because a reporter that raises converts one
      # unexpected payload into an outage here — strictly worse than having no reporter.
      #
      # With no DSN this only reaches the guard, so the rescue it is really asserting
      # lives one layer down: `Polyphony.RedactTest` pins that the scrubber survives a
      # term it cannot rebuild, which is where that risk actually is.
      impossible = %{__struct__: NoSuchModule.AnywhereAtAll, field: "x"}

      assert Crash.report(%RuntimeError{message: "x"}, extra: %{bad: impossible}) == :ok
    end
  end

  describe "the wiring" do
    test "the endpoint captures, and the browser pipeline supplies the request" do
      # Both halves, because either one alone reports nothing useful: PlugCapture with
      # no PlugContext gives an error with no request attached, and PlugContext with no
      # capture gives a request nobody reports.
      assert function_exported?(PolyphonyWeb.Endpoint, :call, 2)

      router = File.read!("lib/polyphony_web/router.ex")
      assert router =~ "plug(Sentry.PlugContext)"

      endpoint = File.read!("lib/polyphony_web/endpoint.ex")
      assert endpoint =~ "use Sentry.PlugCapture"
    end

    test "an Oban job that returns an error tuple is reportable" do
      # It never raises, so it produces no crash report and the logger handler never
      # sees it — the telemetry integration is the only thing that would. Off by
      # default in the SDK, which is how a queue of quietly failing jobs happens.
      assert get_in(Application.get_env(:sentry, :integrations), [:oban, :capture_errors])
    end

    test "the scrubber is what the SDK is configured to call" do
      # The payload tests above would still pass if this pointed somewhere else and
      # something *else* happened to redact — this names the actual contract.
      assert Application.get_env(:sentry, :before_send) == {Polyphony.Crash, :before_send}
    end
  end
end

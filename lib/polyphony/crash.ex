defmodule Polyphony.Crash do
  @moduledoc """
  Telling somebody the app broke (STR-55).

  Before this, a failure had three ways to end and none of them reached a person who
  could fix it. `PolyphonyWeb.SafeEvent` turned a raise into a flash — right for the
  author, and it made the failure invisible to everyone else. A LiveView that died
  outright wrote to stdout in a container. An Oban job exhausted its retries in a
  table. So the first anybody heard was when a user said so, if they did.

  ## The seam

  `report/2` is the whole public surface, and it is a **no-op when no DSN is set** —
  which is dev, test, and any deploy that hasn't configured one. That is deliberate:
  the alternative is a reporter that must be stubbed in every test that exercises an
  error path, and the tests that exercise error paths are the ones worth keeping cheap.

  Everything goes through `Polyphony.Redact` on the way out. Read that module before
  changing anything here — it is where the decision about what may leave this box
  lives, including the deliberate one about what may.

  ## What reports, and what doesn't

  Wired: the endpoint (`Sentry.PlugCapture`, uncaught errors in a request), the logger
  handler (any crashing process, which covers LiveView mounts and Oban jobs alike), and
  `SafeEvent`, which reports *and then* flashes.

  Not wired, deliberately: `Polyphony.Failures`. A turn that didn't generate is a
  domain event with a screen of its own — part of the story's state rather than a
  defect — and routing it here would bury real crashes under a provider having a bad
  afternoon. `Polyphony.LLM` retries and gives up loudly in the log; that is the right
  channel for it.
  """
  require Logger

  @doc """
  Report an exception, if reporting is on.

  Always returns `:ok`. A reporter that can fail the thing it is reporting on is worse
  than no reporter, so a failure to send is logged and swallowed here as well as inside
  the HTTP client.
  """
  @spec report(Exception.t() | term(), keyword()) :: :ok
  def report(exception, opts \\ []) do
    {stacktrace, opts} = Keyword.pop(opts, :stacktrace, [])
    extra = opts |> Keyword.get(:extra, %{}) |> Polyphony.Redact.scrub()

    # Deliberately **not** gated on `enabled?/0`. Sentry returns `:ignored` without a
    # DSN, so a guard here would be a second copy of a check the SDK already makes — and
    # the two disagree, because the SDK's DSN can be set per-process, which is how
    # `Sentry.Test` collects events without a network. The first version had the guard,
    # and the effect was that the tests asserting what leaves the box captured nothing
    # at all. One check, owned by the thing that acts on it.
    Sentry.capture_exception(exception,
      stacktrace: stacktrace,
      extra: extra,
      handled: Keyword.get(opts, :handled, true)
    )

    :ok
  rescue
    e ->
      Logger.error("[crash] the crash reporter itself failed: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Is this deploy configured to report?

  Reads the DSN rather than a flag of its own. One thing to set, and no way to be
  configured on with nowhere to send — which is the state that produces a deploy
  everyone believes is reporting.

  For **boot-time wiring only**: whether to attach a logger handler and a telemetry
  handler, decided once, after `runtime.exs` has run, where the application environment
  is the whole truth. `report/2` does not consult it — see the note there.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:sentry, :dsn) not in [nil, ""]

  @doc """
  The last thing that runs before an event leaves the box.

  Sentry assembles the payload out of whatever was in scope — params, headers, cookies,
  the URL, LiveView assigns, the exception's own fields — so this is the one place with
  the whole thing in hand, and therefore the only place a credential can be caught
  regardless of which of those it arrived in. Returning `nil` would drop the event; it
  never does, because a dropped crash report is the problem this ticket is about.
  """
  @spec before_send(Sentry.Event.t()) :: Sentry.Event.t()
  def before_send(%Sentry.Event{} = event), do: Polyphony.Redact.scrub(event)
end

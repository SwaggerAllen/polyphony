defmodule Polyphony.Notifications do
  @moduledoc """
  The notification sending path (§B4) — minimal by design. v1 has exactly one live
  trigger, the admin report alert (§B3), but the path and the preferences surface are
  built so deferred subscription types have a home. **Email only.**

  A delivery flows: resolve the recipient → check preferences (unless `force:`, which
  safety-critical admin alerts use) → render a subject/body for the type → hand to the
  pluggable `Transport` → record a `Notification` row with its status. Everything runs
  offline through the logging transport; real email is a config swap.
  """

  require Logger

  alias Polyphony.{Repo, Accounts}
  alias Polyphony.Accounts.User
  alias Polyphony.Notifications.{Notification, Prefs, Transport}

  @doc """
  Send `type` to `recipient` (a `%User{}`, a user id, or a raw email string). Records
  the outcome and returns `{:ok, notification}`, `{:skipped, :opted_out}`, or
  `{:error, reason}`. Opts: `:force` (bypass preferences — for safety-critical alerts),
  `:transport`, `:repo`.
  """
  @spec deliver(User.t() | term(), atom(), map(), keyword()) ::
          {:ok, Notification.t()} | {:skipped, :opted_out} | {:error, term()}
  def deliver(recipient, type, payload \\ %{}, opts \\ []) do
    {recipient_id, email} = resolve(recipient, opts)
    force = Keyword.get(opts, :force, false)

    # Every branch logs. These three return before `dispatch/6` and so used to leave no
    # trace at all — which reads identically to the send never having been attempted,
    # and "no line in the drawer" is precisely the symptom this trail exists to
    # explain. `:no_email` is the one that would really mislead: an account with a
    # blank address produces silence rather than a reason.
    cond do
      not Prefs.type?(type) ->
        Logger.error("[mail] #{type} → not a known notification type; nothing sent")
        {:error, :unknown_type}

      blank?(email) ->
        Logger.error("[mail] #{type} → account has no email address; nothing sent")
        {:error, :no_email}

      not force and recipient_id && not Prefs.wants?(recipient_id, type, opts) ->
        Logger.info("[mail] #{type} → #{redact(email)} skipped; opted out of this type")
        record(recipient_id, email, type, nil, nil, "skipped_opt_out", opts)
        {:skipped, :opted_out}

      true ->
        {subject, body} = render(type, payload)
        dispatch(recipient_id, email, type, subject, body, opts)
    end
  end

  @doc """
  Fan a `type` out to every admin (the report-alert path). Safety-critical, so it is
  `force:`d past preferences by default. Returns the list of per-admin results.
  """
  @spec notify_admins(atom(), map(), keyword()) :: [term()]
  def notify_admins(type, payload \\ %{}, opts \\ []) do
    opts = Keyword.put_new(opts, :force, true)
    for admin <- Accounts.list_admins(opts), do: deliver(admin, type, payload, opts)
  end

  @doc "A recipient's notification history, newest first."
  def history(recipient_id, opts \\ []),
    do: Notification.list_for_recipient(repo(opts), recipient_id)

  # ── Internals ─────────────────────────────────────────────────────────────────

  # Every delivery is logged, which means it reaches the debug drawer — the whole
  # point being that "no email arrived" is answerable from a phone. The **transport is
  # named** because the single most useful fact is which one ran: `Transport.Log`
  # reports success without sending anything, so a log line saying `via Transport.Log`
  # is the answer to "why is my inbox empty" on its own.
  defp dispatch(recipient_id, email, type, subject, body, opts) do
    transport = transport(opts)

    case transport.deliver_email(email, subject, body) do
      {:ok, receipt} ->
        # The relay's own reply, not just the fact of one. A 250 from an SMTP provider
        # carries their message id — Postmark's is the handle you search their Activity
        # feed by — and that is exactly the question "we sent it, so where is it?"
        # needs answered. Without it the trail stops at our own boundary.
        Logger.info(
          "[mail] #{type} → #{redact(email)} sent via #{inspect(transport)} — #{receipt(receipt)}"
        )

        {:ok, record(recipient_id, email, type, subject, body, "sent", opts)}

      {:error, reason} ->
        Logger.error(
          "[mail] #{type} → #{redact(email)} FAILED via #{inspect(transport)}: #{inspect(reason)}"
        )

        record(recipient_id, email, type, subject, body, "failed", opts)
        {:error, reason}
    end
  end

  defp redact(email), do: Transport.redact(email)

  # Bounded: a relay's reply is short, but it is remote input reaching a log that the
  # debug drawer renders.
  defp receipt(reply) when is_binary(reply), do: reply |> String.trim() |> String.slice(0, 200)
  defp receipt(other), do: inspect(other)

  defp record(recipient_id, email, type, subject, body, status, opts) do
    Notification.put(repo(opts), %{
      recipient_id: recipient_id,
      recipient_email: email,
      type: to_string(type),
      channel: "email",
      subject: subject,
      body: body,
      status: status,
      sent_at: if(status == "sent", do: now(opts))
    })
  end

  # Minimal per-type templates. The one live type is :report_alert; the rest are stubs
  # that keep the preferences surface honest until their features land.
  defp render(:report_alert, payload) do
    {"New content report ##{payload[:report_id]}",
     "A new report (#{payload[:reason]}) needs review."}
  end

  defp render(:owner_warning, payload) do
    {"A note from the moderation team", to_string(payload[:message])}
  end

  defp render(:magic_link, payload) do
    {"Your Polyphony sign-in link", "Sign in: #{payload[:url]}"}
  end

  defp render(type, _payload), do: {"Notification: #{type}", ""}

  defp resolve(%User{id: id, email: email}, _opts), do: {id, email}
  defp resolve(email, _opts) when is_binary(email), do: {nil, email}

  defp resolve(id, opts) when is_integer(id) do
    case Accounts.get(id, opts) do
      %User{email: email} -> {id, email}
      _ -> {id, nil}
    end
  end

  defp resolve(_other, _opts), do: {nil, nil}

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)
  defp transport(opts), do: Keyword.get(opts, :transport, Transport.adapter())

  defp now(opts),
    do:
      Keyword.get_lazy(opts, :now, fn ->
        NaiveDateTime.truncate(NaiveDateTime.utc_now(), :microsecond)
      end)
end

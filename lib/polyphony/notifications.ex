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

    cond do
      not Prefs.type?(type) ->
        {:error, :unknown_type}

      blank?(email) ->
        {:error, :no_email}

      not force and recipient_id && not Prefs.wants?(recipient_id, type, opts) ->
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

  defp dispatch(recipient_id, email, type, subject, body, opts) do
    case transport(opts).deliver_email(email, subject, body) do
      {:ok, _} ->
        {:ok, record(recipient_id, email, type, subject, body, "sent", opts)}

      {:error, reason} ->
        record(recipient_id, email, type, subject, body, "failed", opts)
        {:error, reason}
    end
  end

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

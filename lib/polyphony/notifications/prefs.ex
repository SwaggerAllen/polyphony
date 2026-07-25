defmodule Polyphony.Notifications.Prefs do
  @moduledoc """
  Per-user notification preferences (§B4) — mostly a stub surface in v1, present so
  deferred subscription types have a home. **Opt-out model:** a row exists only for a
  type a user has turned *off*, so the default is opted-in. Safety-critical types
  (admin report alerts) are delivered with `force:` and never consult this.

  The type catalog lists the notifications the system can raise; only `:report_alert`
  is live in v1, the rest are placeholders the preferences UI will expose.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Polyphony.Repo

  @types ~w(report_alert owner_warning subscription comment_reply)a

  schema "notification_prefs" do
    field(:user_id, :id)
    field(:type, :string)
    field(:enabled, :boolean, default: true)
    timestamps(type: :naive_datetime_usec)
  end

  @doc "The notification type catalog (only `:report_alert` is live in v1)."
  @spec types() :: [atom()]
  def types, do: @types

  @doc "Is `type` one the system recognizes?"
  def type?(type), do: to_atom(type) in @types

  @doc "Does `user_id` want `type`? Default-on: only an explicit disabled row opts out."
  @spec wants?(term(), atom() | String.t(), keyword()) :: boolean()
  def wants?(user_id, type, opts \\ []) do
    case repo(opts).get_by(__MODULE__, user_id: user_id, type: to_string(type)) do
      nil -> true
      %__MODULE__{enabled: enabled} -> enabled
    end
  end

  @doc "Set whether `user_id` receives `type`. Upserts the single (user, type) row."
  def set(user_id, type, enabled, opts \\ []) do
    repo = repo(opts)
    type = to_string(type)

    case repo.get_by(__MODULE__, user_id: user_id, type: type) do
      nil ->
        repo.insert!(change(%__MODULE__{}, user_id: user_id, type: type, enabled: enabled))

      row ->
        repo.update!(change(row, enabled: enabled))
    end
  end

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)

  defp to_atom(t) when is_atom(t), do: t
  defp to_atom(t) when is_binary(t), do: Enum.find(@types, &(to_string(&1) == t))
end

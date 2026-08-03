defmodule Polyphony.Moderation.AuditLog do
  @moduledoc """
  The admin audit log (§B3): one append-only row per admin action, attributed to the
  actor. **Especially any access to user content** — the `content_access` action a
  report grants (§C reactive access) is recorded here so proactive/reactive access is
  always logged and attributable. This is a data-layer requirement, not a UI concern.
  """
  use Ecto.Schema
  import Ecto.Query

  schema "admin_audit_logs" do
    field(:actor_id, :id)
    field(:action, :string)
    field(:target_type, :string)
    field(:target_id, :integer)
    field(:metadata, :map, default: %{})
    timestamps(type: :naive_datetime_usec, updated_at: false)
  end

  def put(repo, attrs), do: repo.insert!(struct(__MODULE__, attrs))

  @doc "The audit trail attributed to `actor_id`, newest first."
  def list_for_actor(repo, actor_id) do
    repo.all(
      from(a in __MODULE__, where: a.actor_id == ^actor_id, order_by: [desc: a.inserted_at])
    )
  end

  @doc "Everything done lately, newest first — the admin screen's audit view."
  def list_recent(repo, limit \\ 50) do
    repo.all(from(a in __MODULE__, order_by: [desc: a.inserted_at], limit: ^limit))
  end

  @doc "The audit trail touching a specific target (e.g. a report or a user's content)."
  def list_for_target(repo, target_type, target_id) do
    repo.all(
      from(a in __MODULE__,
        where: a.target_type == ^to_string(target_type) and a.target_id == ^target_id,
        order_by: [desc: a.inserted_at]
      )
    )
  end
end

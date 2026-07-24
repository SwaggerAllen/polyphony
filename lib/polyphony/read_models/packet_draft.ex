defmodule Polyphony.ReadModels.PacketDraft do
  @moduledoc """
  The pending-draft store (§A2): one row per generated-but-uncommitted turn — an
  **assisted**-mode draft awaiting the user's confirmation, or a **suggestion**
  candidate in the composer.

  It is deliberately **not** on the fiction event log: a draft is workflow state,
  not a fact, and keeping it out of the stream is what guarantees `visible_to?`
  can never see it (like `Failures`, this is user/system state). The `packet` is an
  opaque Erlang-term binary — `Polyphony.Drafts` owns the codec.
  """
  use Ecto.Schema
  import Ecto.Query

  schema "packet_drafts" do
    field(:scene_id, :string)
    field(:character_id, :string)
    field(:beat, :integer)
    field(:source, :string, default: "assisted")
    field(:status, :string, default: "pending")
    field(:edited, :boolean, default: false)
    field(:model, :string)
    field(:packet, :binary)
    timestamps(type: :naive_datetime_usec)
  end

  def put(repo, attrs), do: repo.insert!(struct(__MODULE__, attrs))

  def get(repo, id), do: repo.get(__MODULE__, id)

  @doc "Pending drafts for a scene, oldest first."
  def list_open(repo, scene_id) do
    sid = to_string(scene_id)

    repo.all(
      from(d in __MODULE__,
        where: d.scene_id == ^sid and d.status == "pending",
        order_by: [asc: d.inserted_at]
      )
    )
  end

  def update(repo, %__MODULE__{} = row, changes),
    do: row |> Ecto.Changeset.change(changes) |> repo.update!()
end

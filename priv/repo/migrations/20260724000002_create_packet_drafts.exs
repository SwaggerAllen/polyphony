defmodule Polyphony.Repo.Migrations.CreatePacketDrafts do
  use Ecto.Migration

  def change do
    create table(:packet_drafts) do
      add(:scene_id, :string, null: false)
      add(:character_id, :string, null: false)
      add(:beat, :integer)
      add(:source, :string, null: false, default: "assisted")
      add(:status, :string, null: false, default: "pending")
      add(:edited, :boolean, null: false, default: false)
      add(:model, :string)
      # The pending TurnPacket, stored as an Erlang term (lossless — atoms and
      # nested structs round-trip exactly). It is NOT on the fiction event log, so a
      # draft can never reach a character's projection until it is accepted (§A2).
      add(:packet, :binary, null: false)
      timestamps(type: :naive_datetime_usec)
    end

    create(index(:packet_drafts, [:scene_id, :status]))
  end
end

defmodule Polyphony.Repo.Migrations.AddArcReasonAndAudience do
  use Ecto.Migration

  # Two things the arc-review screen needs from every proposal (`ux/polyphony-arc.html`):
  #
  #   * reason   — the "Because" line. What in the scene caused this, which is what
  #                makes accepting quick: you can check the reasoning without going
  #                back and rereading.
  #   * audience — world arc only. A character's arc is theirs; a world's arc is
  #                everyone's, which means it also has to say *who knows*, and that is
  #                the audience picker doing the same job it does on a secret (§3.3).
  #                Stored as the encoded `Polyphony.Authoring.Audience` term.
  #
  # `released_topic` carries the third arc kind: a boundary that gave during play.
  # The gate already resolved it scene-locally; review is where it becomes permanent,
  # so the entry has to name which line broke.
  def change do
    alter table(:arc_entries) do
      add :reason, :text
      add :audience, :binary
      add :released_topic, :string
      add :concealed, :boolean, default: false, null: false
    end
  end
end

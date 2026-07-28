defmodule Polyphony.Costs.Attribution do
  @moduledoc """
  Resolve who a scene's autonomous spend is billed to (§B5).

  The Director loop and the memory embeddings run in Oban jobs / read paths with no
  logged-in user, so they can't attribute to "the current user." Instead spend is
  attributed to the **campaign owner**: the scene's `SceneOpened` carries the
  `campaign_id`, and the campaign's `Library` entry carries the `owner_id`.

  Best-effort and side-effect-free — every field is nil-safe. A scene with no
  campaign, or an org-owned campaign (no user owner), simply yields no `user_id`,
  and the metered call then records nothing rather than failing.
  """
  require Logger

  alias Polyphony.{App, Library}
  alias Polyphony.Events.SceneOpened

  @type t :: %{user_id: term() | nil, campaign_id: term() | nil}

  @doc "The `{user_id, campaign_id}` a scene's autonomous spend is billed to."
  @spec for_scene(term()) :: t()
  def for_scene(scene_id) do
    campaign_id = campaign_id_of(scene_id)
    %{campaign_id: campaign_id, user_id: owner_of(campaign_id)}
  rescue
    e ->
      Logger.warning(
        "[usage] attribution failed for #{inspect(scene_id)}: #{Exception.message(e)}"
      )

      %{campaign_id: nil, user_id: nil}
  end

  # The scene's campaign id from its opening event — the first event on the stream.
  defp campaign_id_of(scene_id) do
    case Commanded.EventStore.stream_forward(App, scene_id, 0, 8) do
      {:error, _} ->
        nil

      stream ->
        Enum.find_value(stream, nil, fn e ->
          match?(%SceneOpened{}, e.data) && e.data.campaign_id
        end)
    end
  rescue
    _ -> nil
  end

  defp owner_of(nil), do: nil

  defp owner_of(campaign_id) do
    case Library.get(campaign_id) do
      %{owner_type: "user", owner_id: owner_id} -> to_user_id(owner_id)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # The ledger's user_id is integer-typed; owner_id is stored as a string. Coerce so
  # the row inserts (a non-numeric owner id — shouldn't happen for a user — yields nil).
  defp to_user_id(id) when is_integer(id), do: id

  defp to_user_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_user_id(_), do: nil
end

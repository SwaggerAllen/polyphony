defmodule PolyphonyWeb.AutofillControls do
  @moduledoc """
  Shared glue for the editor LiveViews' auto-generation buttons (see
  `Polyphony.Authoring.Autofill`). Runs generation in a `start_async` task so the
  form stays responsive with a per-target "generating" indicator, then folds the
  result back into the `:draft` assign.

  The host LiveView must assign `:draft` (a `%{field => string}` map bound to the
  form) and `:generating` (a `MapSet` of in-flight targets — field names, or the
  literal `"all"`). Its `handle_async/3` clauses delegate to `resolve_all/2` and
  `resolve_field/3`.
  """
  import Phoenix.LiveView, only: [start_async: 3, put_flash: 3]
  import Phoenix.Component, only: [assign: 3]

  alias Polyphony.Authoring.Autofill

  @all "all"

  @doc "Is `target` (a field name or \"all\") currently generating?"
  def generating?(generating, target), do: MapSet.member?(generating, to_string(target))

  @doc "Kick off whole-form generation from a free-text brief."
  def start_all(socket, kind, brief) do
    current = socket.assigns.draft
    opts = gen_opts(socket)

    socket
    |> mark(@all, true)
    |> start_async(:autofill_all, fn ->
      Autofill.generate_all(kind, brief, current, opts)
    end)
  end

  @doc "Kick off single-field generation from the other fields + the field's own content."
  def start_field(socket, kind, field) do
    field = to_string(field)
    current = socket.assigns.draft
    opts = gen_opts(socket)

    socket
    |> mark(field, true)
    |> start_async({:autofill_field, field}, fn ->
      Autofill.generate_field(kind, field, current, opts)
    end)
  end

  # World seed + related-character sheets + usage attribution (the signed-in author).
  defp gen_opts(socket) do
    [
      world: Map.get(socket.assigns, :world_context),
      relations: Map.get(socket.assigns, :relations_context),
      usage_kind: "authoring"
    ] ++ user_attribution(socket)
  end

  defp user_attribution(socket) do
    case Map.get(socket.assigns, :current_user) do
      %{id: id} -> [user_id: id]
      _ -> []
    end
  end

  @doc "Fold a whole-form result into the draft (or flash the error)."
  def resolve_all(socket, {:ok, values}) do
    socket
    |> merge_draft(values)
    |> mark(@all, false)
    |> put_flash(:info, "Generated #{map_size(values)} fields — review and Save.")
  end

  def resolve_all(socket, other), do: fail(socket, @all, reason(other))

  @doc "Fold a single-field result into the draft (or flash the error)."
  def resolve_field(socket, field, {:ok, value}) do
    socket
    |> merge_draft(%{to_string(field) => value})
    |> mark(field, false)
  end

  def resolve_field(socket, field, other), do: fail(socket, field, reason(other))

  # ── internals ────────────────────────────────────────────────────────────────

  defp fail(socket, target, reason) do
    socket
    |> mark(target, false)
    |> put_flash(:error, "Generation failed: #{inspect(reason)}")
  end

  # handle_async delivers {:ok, task_return} on success or {:exit, reason} on crash;
  # task_return is Autofill's own {:ok, _} | {:error, reason}.
  defp reason({:error, reason}), do: reason
  defp reason({:exit, reason}), do: reason
  defp reason(other), do: other

  defp mark(socket, target, true),
    do: assign(socket, :generating, MapSet.put(socket.assigns.generating, to_string(target)))

  defp mark(socket, target, false),
    do: assign(socket, :generating, MapSet.delete(socket.assigns.generating, to_string(target)))

  defp merge_draft(socket, values) do
    values = Map.new(values, fn {k, v} -> {to_string(k), v} end)
    assign(socket, :draft, Map.merge(socket.assigns.draft, values))
  end
end

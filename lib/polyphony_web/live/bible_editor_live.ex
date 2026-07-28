defmodule PolyphonyWeb.BibleEditorLive do
  @moduledoc """
  V6 (world bible editor): setting, tone, rules, and starting canon — with the same
  AI assistance as the character editor.

  Every field is edited as **blocks** (`PolyphonyWeb.BlockField`): setting and tone as
  *paragraphs* (joined by blank lines into the stored string), rules and starting
  canon as *items* (one per block, stored as the field's list). Each block can be
  added, removed, regenerated, or the field expanded; the brief fills them all.
  Nothing persists until Save, and blocks fold back into the domain's strings/lists.
  """
  use PolyphonyWeb, :live_view

  require Logger

  import PolyphonyWeb.BlockField

  alias Polyphony.Library
  alias Polyphony.Authoring.{Autofill, WorldBible}

  # {field, label, mode, unit}. mode: :paragraph (→ string) | :line (→ list).
  @field_specs [
    {"setting", "Setting", :paragraph, "paragraph"},
    {"tone", "Tone", :paragraph, "paragraph"},
    {"rules", "Rules / physics", :line, "item"},
    {"starting_canon", "Starting canon", :line, "item"}
  ]
  @block_fields Enum.map(@field_specs, &elem(&1, 0))
  @modes Map.new(@field_specs, fn {f, _l, m, _u} -> {f, m} end)

  defp field_specs, do: @field_specs

  def mount(%{"id" => id}, _session, socket) do
    entry = Library.get(id)

    if entry && entry.kind == "world_bible" do
      bible = Library.payload(entry)

      {:ok,
       assign(socket,
         page_title: "Edit world bible",
         entry: entry,
         bible: bible,
         name: bible.name || "",
         blocks: blocks_from_bible(bible),
         generating: MapSet.new(),
         saved: false
       )}
    else
      {:ok, socket |> put_flash(:error, "World bible not found.") |> redirect(to: ~p"/library")}
    end
  end

  # ── Editing ───────────────────────────────────────────────────────────────────

  def handle_event("sync", params, socket) do
    {:noreply, socket |> assign_form(params) |> assign(:saved, false)}
  end

  def handle_event("save", params, socket) do
    safe(socket, fn ->
      socket = assign_form(socket, params)
      %{name: name, blocks: blocks} = socket.assigns

      bible = %WorldBible{
        socket.assigns.bible
        | name: name,
          setting: to_domain("setting", blocks["setting"]),
          tone: to_domain("tone", blocks["tone"]),
          rules: to_domain("rules", blocks["rules"]),
          starting_canon: to_domain("starting_canon", blocks["starting_canon"])
      }

      {:ok, entry} = Library.update_payload(socket.assigns.entry.id, bible)

      {:noreply,
       assign(socket,
         entry: entry,
         bible: bible,
         name: bible.name || "",
         blocks: blocks_from_bible(bible),
         saved: true
       )}
    end)
  end

  def handle_event("add_block", %{"field" => f}, socket) when f in @block_fields do
    {:noreply, update_blocks(socket, f, &(&1 ++ [""]))}
  end

  def handle_event("remove_block", %{"field" => f, "index" => i}, socket)
      when f in @block_fields do
    {:noreply, update_blocks(socket, f, &drop_block(&1, String.to_integer(i)))}
  end

  # ── Generation ──────────────────────────────────────────────────────────────

  def handle_event("generate_all", %{"brief" => brief}, socket) do
    safe(socket, fn ->
      current = current_values(socket)
      opts = gen_opts(socket)

      {:noreply,
       socket
       |> mark("all", true)
       |> start_async(:gen_all, fn ->
         Autofill.generate_all(:world_bible, brief, current, opts)
       end)}
    end)
  end

  def handle_event("generate_field", %{"field" => f}, socket) when f in @block_fields do
    safe(socket, fn ->
      current = current_values(socket)
      opts = gen_opts(socket)

      {:noreply,
       socket
       |> mark(f, true)
       |> start_async({:gen_field, f}, fn ->
         Autofill.generate_field(:world_bible, f, current, opts)
       end)}
    end)
  end

  def handle_event("expand_field", %{"field" => f}, socket) when f in @block_fields do
    safe(socket, fn ->
      opts = paragraph_opts(socket, f, nil)

      {:noreply,
       socket
       |> mark("#{f}:expand", true)
       |> start_async({:expand, f}, fn -> Autofill.generate_paragraph(:world_bible, f, opts) end)}
    end)
  end

  def handle_event("generate_block", %{"field" => f, "index" => i}, socket)
      when f in @block_fields do
    idx = String.to_integer(i)

    safe(socket, fn ->
      opts = paragraph_opts(socket, f, idx)

      {:noreply,
       socket
       |> mark("#{f}:#{idx}", true)
       |> start_async({:gen_block, f, idx}, fn ->
         Autofill.generate_paragraph(:world_bible, f, opts)
       end)}
    end)
  end

  # ── Async results ─────────────────────────────────────────────────────────────

  def handle_async(:gen_all, {:ok, {:ok, values}}, socket) do
    blocks =
      Enum.reduce(@block_fields, socket.assigns.blocks, fn f, acc ->
        if values[f] in [nil, ""], do: acc, else: Map.put(acc, f, split_generated(f, values[f]))
      end)

    name = if values["name"] in [nil, ""], do: socket.assigns.name, else: values["name"]
    {:noreply, socket |> assign(name: name, blocks: blocks) |> mark("all", false)}
  end

  def handle_async(:gen_all, result, socket), do: {:noreply, gen_failed(socket, "all", result)}

  def handle_async({:gen_field, f}, {:ok, {:ok, value}}, socket) do
    {:noreply, socket |> put_blocks(f, split_generated(f, value)) |> mark(f, false)}
  end

  def handle_async({:gen_field, f}, result, socket),
    do: {:noreply, gen_failed(socket, f, result)}

  def handle_async({:expand, f}, {:ok, {:ok, para}}, socket) do
    {:noreply,
     socket
     |> put_blocks(f, append_paragraph(socket.assigns.blocks[f], para))
     |> mark("#{f}:expand", false)}
  end

  def handle_async({:expand, f}, result, socket),
    do: {:noreply, gen_failed(socket, "#{f}:expand", result)}

  def handle_async({:gen_block, f, idx}, {:ok, {:ok, para}}, socket) do
    blocks = List.replace_at(socket.assigns.blocks[f], idx, para)
    {:noreply, socket |> put_blocks(f, blocks) |> mark("#{f}:#{idx}", false)}
  end

  def handle_async({:gen_block, f, idx}, result, socket),
    do: {:noreply, gen_failed(socket, "#{f}:#{idx}", result)}

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp assign_form(socket, params) do
    name = params["name"] || socket.assigns.name

    blocks =
      Map.new(@block_fields, fn f ->
        {f, param_blocks(params["b_#{f}"], socket.assigns.blocks[f])}
      end)

    assign(socket, name: name, blocks: blocks)
  end

  defp update_blocks(socket, field, fun),
    do: socket |> put_blocks(field, fun.(socket.assigns.blocks[field])) |> assign(:saved, false)

  defp put_blocks(socket, field, blocks),
    do: assign(socket, :blocks, Map.put(socket.assigns.blocks, field, ensure_one(blocks)))

  defp blocks_from_bible(bible) do
    Map.new(@block_fields, fn f ->
      raw = Map.get(bible, String.to_existing_atom(f))
      {f, if(@modes[f] == :line, do: to_line_blocks(raw), else: to_blocks(raw))}
    end)
  end

  # Blocks → the domain value: a blank-line string for prose, a trimmed list for items.
  defp to_domain(field, blocks) do
    if @modes[field] == :line, do: block_list(blocks), else: join_blocks(blocks)
  end

  # Generated text → blocks: split on blank lines (prose) or single lines (items).
  defp split_generated(field, value) do
    if @modes[field] == :line, do: to_line_blocks(value), else: to_blocks(value)
  end

  # The current field text (for generation context): prose joined by blank lines,
  # items joined by single newlines.
  defp field_text(field, blocks) do
    if @modes[field] == :line, do: Enum.join(block_list(blocks), "\n"), else: join_blocks(blocks)
  end

  defp current_values(socket) do
    Map.merge(
      %{"name" => socket.assigns.name},
      Map.new(@block_fields, fn f -> {f, field_text(f, socket.assigns.blocks[f])} end)
    )
  end

  defp paragraph_opts(socket, field, index) do
    [blocks: socket.assigns.blocks[field], index: index, current: current_values(socket)] ++
      gen_opts(socket)
  end

  defp gen_opts(socket) do
    [usage_kind: "authoring"] ++
      case socket.assigns.current_user do
        %{id: id} -> [user_id: id]
        _ -> []
      end
  end

  defp mark(socket, key, true),
    do: assign(socket, :generating, MapSet.put(socket.assigns.generating, key))

  defp mark(socket, key, false),
    do: assign(socket, :generating, MapSet.delete(socket.assigns.generating, key))

  defp gen_failed(socket, key, result) do
    Logger.warning("[authoring] world generation failed (#{key}): #{inspect(result)}")

    socket
    |> mark(key, false)
    |> put_flash(:error, "Generation failed: #{inspect(reason(result))}")
  end

  defp reason({:ok, {:error, r}}), do: r
  defp reason({:exit, r}), do: r
  defp reason(other), do: other

  # ── Render ────────────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <h1>World bible</h1>

    <div class="card gen-brief">
      <form phx-submit="generate_all">
        <label>Describe the world — we'll fill in every field <span class="faint">(builds on anything you've already written)</span></label>
        <textarea
          name="brief"
          rows="2"
          placeholder="e.g. A rain-soaked cyberpunk port city where memory can be bought, sold, and forged."
        ></textarea>
        <button class="btn" type="submit" disabled={busy?(@generating, "all")}>
          <%= if busy?(@generating, "all"), do: "✨ Generating…", else: "✨ Generate all fields" %>
        </button>
      </form>
    </div>

    <div class="card">
      <form id="bible-form" phx-submit="save" phx-change="sync">
        <label class="gen-label"><span>Name</span></label>
        <input type="text" name="name" value={@name} phx-debounce="blur" />

        <.block_field
          :for={{f, label, _mode, unit} <- field_specs()}
          field={f}
          label={label}
          unit={unit}
          blocks={@blocks[f]}
          generating={@generating}
        />

        <div class="row save-row">
          <button class="btn" type="submit">Save</button>
          <span :if={@saved} class="saved-note" role="status">✓ Saved</span>
          <span class="spacer"></span>
          <a class="btn ghost" href={~p"/library"}>Back to library</a>
        </div>
      </form>
    </div>
    """
  end
end

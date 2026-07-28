defmodule PolyphonyWeb.BibleEditorLive do
  @moduledoc """
  V6 (world bible editor): setting, tone, rules, and starting canon — with the same
  AI assistance as the character editor.

  The prose fields (setting, tone) are edited as **blocks** (paragraphs) via
  `PolyphonyWeb.BlockField`: readable, auto-growing, per-paragraph regenerate/expand.
  Rules and starting canon stay **line lists** (one item per line). Generation
  (whole-form brief, per-field, per-paragraph) is metered; nothing persists until
  Save, and blocks join back into plain strings so the domain is unchanged.
  """
  use PolyphonyWeb, :live_view

  require Logger

  import PolyphonyWeb.BlockField

  alias Polyphony.Library
  alias Polyphony.Authoring.{Autofill, WorldBible}

  @block_specs [{"setting", "Setting"}, {"tone", "Tone"}]
  @block_fields Enum.map(@block_specs, &elem(&1, 0))
  @line_specs [{"rules", "Rules / physics"}, {"starting_canon", "Starting canon"}]
  @line_fields Enum.map(@line_specs, &elem(&1, 0))

  defp block_specs, do: @block_specs
  defp line_specs, do: @line_specs

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
         lines: lines_from_bible(bible),
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
      %{name: name, blocks: blocks, lines: lines} = socket.assigns

      bible = %WorldBible{
        socket.assigns.bible
        | name: name,
          setting: join_blocks(blocks["setting"]),
          tone: join_blocks(blocks["tone"]),
          rules: to_lines(lines["rules"]),
          starting_canon: to_lines(lines["starting_canon"])
      }

      {:ok, entry} = Library.update_payload(socket.assigns.entry.id, bible)

      {:noreply,
       assign(socket,
         entry: entry,
         bible: bible,
         name: bible.name || "",
         blocks: blocks_from_bible(bible),
         lines: lines_from_bible(bible),
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

  def handle_event("generate_field", %{"field" => f}, socket)
      when f in @block_fields or f in @line_fields do
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
        if values[f] in [nil, ""], do: acc, else: Map.put(acc, f, to_blocks(values[f]))
      end)

    lines =
      Enum.reduce(@line_fields, socket.assigns.lines, fn f, acc ->
        if values[f] in [nil, ""], do: acc, else: Map.put(acc, f, values[f])
      end)

    name = if values["name"] in [nil, ""], do: socket.assigns.name, else: values["name"]
    {:noreply, socket |> assign(name: name, blocks: blocks, lines: lines) |> mark("all", false)}
  end

  def handle_async(:gen_all, result, socket), do: {:noreply, gen_failed(socket, "all", result)}

  def handle_async({:gen_field, f}, {:ok, {:ok, value}}, socket) when f in @block_fields do
    {:noreply, socket |> put_blocks(f, to_blocks(value)) |> mark(f, false)}
  end

  def handle_async({:gen_field, f}, {:ok, {:ok, value}}, socket) when f in @line_fields do
    {:noreply,
     socket |> assign(:lines, Map.put(socket.assigns.lines, f, value)) |> mark(f, false)}
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

    lines = Map.new(@line_fields, fn f -> {f, params[f] || socket.assigns.lines[f]} end)
    assign(socket, name: name, blocks: blocks, lines: lines)
  end

  defp update_blocks(socket, field, fun),
    do: socket |> put_blocks(field, fun.(socket.assigns.blocks[field])) |> assign(:saved, false)

  defp put_blocks(socket, field, blocks),
    do: assign(socket, :blocks, Map.put(socket.assigns.blocks, field, ensure_one(blocks)))

  defp blocks_from_bible(bible),
    do: %{"setting" => to_blocks(bible.setting), "tone" => to_blocks(bible.tone)}

  defp lines_from_bible(bible) do
    %{
      "rules" => Enum.join(bible.rules || [], "\n"),
      "starting_canon" => Enum.join(bible.starting_canon || [], "\n")
    }
  end

  defp to_lines(nil), do: []

  defp to_lines(text),
    do: text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp current_values(socket) do
    Map.merge(
      %{"name" => socket.assigns.name},
      Map.merge(
        Map.new(@block_fields, fn f -> {f, join_blocks(socket.assigns.blocks[f])} end),
        Map.new(@line_fields, fn f -> {f, socket.assigns.lines[f]} end)
      )
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

  attr(:field, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:generating, :any, required: true)

  defp line_field(assigns) do
    ~H"""
    <div class="field-block">
      <label class="row gen-label">
        <span><%= @label %> <span class="faint">(one per line)</span></span>
        <span class="spacer"></span>
        <button
          type="button"
          class="btn sm ghost"
          phx-click="generate_field"
          phx-value-field={@field}
          disabled={busy?(@generating, @field)}
          title={"Generate #{@label}"}
        >
          <%= if busy?(@generating, @field), do: "✨ …", else: "✨ Generate" %>
        </button>
      </label>
      <textarea name={@field} phx-debounce="blur"><%= @value %></textarea>
    </div>
    """
  end

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
          :for={{f, label} <- block_specs()}
          field={f}
          label={label}
          blocks={@blocks[f]}
          generating={@generating}
        />

        <.line_field
          :for={{f, label} <- line_specs()}
          field={f}
          label={label}
          value={@lines[f]}
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

defmodule PolyphonyWeb.BlockField do
  @moduledoc """
  Shared block-field editor used by the character and world-bible editors (§15).

  A prose field is edited as a stack of **paragraphs**: each is an always-live,
  auto-growing textarea styled to read like prose until focused (no toggle logic —
  the `AutoGrow` hook + focus CSS do it), so long content stays readable. `+` appends
  a paragraph; each has ✨ (rewrite richer) + remove; the field has ✨ Generate (fresh)
  and ➕ Expand (append a paragraph that deepens it).

  Blocks are a *presentation* layer over the plain-string field: `to_blocks/1` splits
  a stored string on blank lines, `join_blocks/1` rejoins on save — so the domain
  struct is unchanged. The host LiveView owns the events (`generate_field`,
  `expand_field`, `generate_block`, `add_block`, `remove_block`) and the async
  results; these are the pure helpers + the render component both share.
  """
  use Phoenix.Component

  @doc "Split a stored field string into paragraph blocks (always at least one)."
  def to_blocks(nil), do: [""]

  def to_blocks(str) when is_binary(str) do
    case str
         |> String.split(~r/\n{2,}/)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == "")) do
      [] -> [""]
      list -> list
    end
  end

  @doc "Join paragraph blocks back into the stored field string (blank-line separated)."
  def join_blocks(blocks),
    do: blocks |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")

  @doc """
  Blocks for a **line-list** field (rules, starting canon), one block per item.
  Accepts the stored list, a newline string (e.g. from generation), or nil.
  """
  def to_line_blocks(list) when is_list(list),
    do: list |> Enum.map(&to_string/1) |> Enum.reject(&(String.trim(&1) == "")) |> ensure_one()

  def to_line_blocks(str) when is_binary(str),
    do:
      str
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> ensure_one()

  def to_line_blocks(nil), do: [""]

  @doc "Line-list blocks back into the stored list (non-empty, trimmed)."
  def block_list(blocks), do: blocks |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  @doc "The blocks a `b_<field>[]` form param carries (falling back to the current ones)."
  def param_blocks(nil, fallback), do: fallback
  def param_blocks([], _fallback), do: [""]
  def param_blocks(list, _fallback) when is_list(list), do: list
  def param_blocks(str, _fallback) when is_binary(str), do: [str]

  def ensure_one([]), do: [""]
  def ensure_one(list), do: list

  def drop_block(list, idx), do: list |> List.delete_at(idx) |> ensure_one()

  @doc """
  Move the item at `idx` by `delta` places, saturating at the ends.

  The design's list item menu carries *Move up* (`ux/polyphony-world.html` §04,
  `polyphony-character.html` §03) because order is authored: rules read as a set of
  laws and canon reads as a chronology, and both are worse shuffled. Saturating
  rather than wrapping means the control is always safe to press — the top item's
  *Move up* does nothing rather than sending it to the bottom.
  """
  def move_block(list, idx, delta) do
    to = idx + delta

    if idx in 0..(length(list) - 1)//1 and to in 0..(length(list) - 1)//1 do
      item = Enum.at(list, idx)
      list |> List.delete_at(idx) |> List.insert_at(to, item)
    else
      list
    end
  end

  @doc "Append a fresh paragraph, dropping any blank placeholder blocks first."
  def append_paragraph(blocks, para), do: Enum.reject(blocks, &(String.trim(&1) == "")) ++ [para]

  @doc "Is `key` currently generating? (`generating` is a MapSet of in-flight keys.)"
  def busy?(generating, key), do: MapSet.member?(generating, key)

  @doc """
  One prose field, as the character sheet and world bible draw it.

  Ported from `ux/polyphony-character.html` §01: a mono label on the left, **✦
  Rewrite** and **+ Expand** on the right, the prose below. Each paragraph is a
  `.field` textarea at the mock's own prose size — the kit's treatment for an
  editable prose value everywhere it appears (§02, §05) — so the field reads
  continuously rather than as a stack of form controls. That's the section's rule:
  *prose first, structure after. The five written fields run continuously like a
  page.*
  """
  attr(:field, :string, required: true)
  attr(:label, :string, required: true)
  attr(:unit, :string, default: "paragraph")
  attr(:blocks, :list, required: true)
  attr(:generating, :any, required: true)
  attr(:id, :string, default: nil)

  def block_field(assigns) do
    ~H"""
    <div class="row px-4 py-3" id={@id || "field-#{@field}"}>
      <div class="flex items-center justify-between gap-2 mb-2">
        <span class="lbl dim"><%= @label %></span>
        <div class="flex gap-1.5 shrink-0">
          <button
            type="button"
            class="btn btn-gh btn-sm"
            phx-click="generate_field"
            phx-value-field={@field}
            disabled={busy?(@generating, @field)}
            title={"Rewrite #{@label} from scratch"}
          >
            <%= if busy?(@generating, @field), do: "✦ …", else: "✦ Rewrite" %>
          </button>
          <button
            type="button"
            class="btn btn-gh btn-sm"
            phx-click="expand_field"
            phx-value-field={@field}
            disabled={busy?(@generating, "#{@field}:expand")}
            title={"Add another #{@unit} to #{@label}"}
          >
            <%= if busy?(@generating, "#{@field}:expand"), do: "+ …", else: "+ Expand" %>
          </button>
        </div>
      </div>

      <div :for={{b, i} <- Enum.with_index(@blocks)} class="flex items-start gap-1.5 mb-1.5">
        <textarea
          id={"ta-#{@field}-#{i}"}
          name={"b_#{@field}[]"}
          class="field px-3 py-2.5 text-[14px] leading-relaxed w-full"
          rows="2"
          phx-hook="AutoGrow"
          phx-debounce="600"
          placeholder={"New #{@unit}…"}
        ><%= b %></textarea>
        <div class="flex flex-col gap-1 shrink-0">
          <button
            type="button"
            class="btn btn-gh btn-sm"
            phx-click="generate_block"
            phx-value-field={@field}
            phx-value-index={i}
            disabled={busy?(@generating, "#{@field}:#{i}")}
            title={"Rewrite this #{@unit}, richer"}
          >
            <%= if busy?(@generating, "#{@field}:#{i}"), do: "…", else: "✦" %>
          </button>
          <button
            type="button"
            class="btn btn-pen btn-sm"
            phx-click="remove_block"
            phx-value-field={@field}
            phx-value-index={i}
            title={"Remove #{@unit}"}
          >
            ✕
          </button>
        </div>
      </div>

      <button
        type="button"
        class="btn btn-gh btn-sm"
        phx-click="add_block"
        phx-value-field={@field}
      >
        + <%= @unit %>
      </button>
    </div>
    """
  end
end

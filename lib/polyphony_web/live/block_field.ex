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

  @doc "Append a fresh paragraph, dropping any blank placeholder blocks first."
  def append_paragraph(blocks, para), do: Enum.reject(blocks, &(String.trim(&1) == "")) ++ [para]

  @doc "Is `key` currently generating? (`generating` is a MapSet of in-flight keys.)"
  def busy?(generating, key), do: MapSet.member?(generating, key)

  attr(:field, :string, required: true)
  attr(:label, :string, required: true)
  attr(:hint, :string, default: nil)
  attr(:unit, :string, default: "paragraph")
  attr(:blocks, :list, required: true)
  attr(:generating, :any, required: true)

  def block_field(assigns) do
    ~H"""
    <div class="field-block">
      <div class="row gen-label">
        <span><%= @label %> <span :if={@hint} class="faint"><%= @hint %></span></span>
        <span class="spacer"></span>
        <button
          type="button"
          class="btn sm ghost"
          phx-click="generate_field"
          phx-value-field={@field}
          disabled={busy?(@generating, @field)}
          title={"Rewrite #{@label} from scratch"}
        >
          <%= if busy?(@generating, @field), do: "✨ …", else: "✨ Generate" %>
        </button>
        <button
          type="button"
          class="btn sm ghost"
          phx-click="expand_field"
          phx-value-field={@field}
          disabled={busy?(@generating, "#{@field}:expand")}
          title={"Add another #{@unit} to #{@label}"}
        >
          <%= if busy?(@generating, "#{@field}:expand"), do: "➕ …", else: "➕ Expand" %>
        </button>
      </div>

      <div :for={{b, i} <- Enum.with_index(@blocks)} class="para" id={"para-#{@field}-#{i}"}>
        <textarea
          id={"ta-#{@field}-#{i}"}
          name={"b_#{@field}[]"}
          class="para-input"
          rows="1"
          phx-hook="AutoGrow"
          phx-debounce="blur"
          placeholder={"New #{@unit}…"}
        ><%= b %></textarea>
        <div class="para-controls">
          <button
            type="button"
            class="btn xs ghost"
            phx-click="generate_block"
            phx-value-field={@field}
            phx-value-index={i}
            disabled={busy?(@generating, "#{@field}:#{i}")}
            title={"Rewrite this #{@unit}, richer"}
          >
            <%= if busy?(@generating, "#{@field}:#{i}"), do: "…", else: "✨" %>
          </button>
          <button
            type="button"
            class="btn xs ghost"
            phx-click="remove_block"
            phx-value-field={@field}
            phx-value-index={i}
            title={"Remove #{@unit}"}
          >
            ✕
          </button>
        </div>
      </div>

      <button type="button" class="btn xs ghost add-para" phx-click="add_block" phx-value-field={@field}>
        + <%= @unit %>
      </button>
    </div>
    """
  end
end

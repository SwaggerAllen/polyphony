defmodule Polyphony.Authoring.Autofill do
  @moduledoc """
  Author-facing generation for the editor forms (§15). Two modes, both provider-
  agnostic (they go through `Polyphony.LLM.Provider`, so Mock/DeepInfra swap by
  config), and both **stateless** — they return field *values* for the form to show;
  nothing is persisted until the author saves.

    * `generate_all/4` — a free-text brief fills **every** field at once. Any fields
      the author already filled in are passed as seed so generation builds on them
      instead of contradicting them.
    * `generate_field/4` — regenerate **one** field from the values of the others,
      seeded by whatever is already in that field (refine-in-place). This is the
      per-field button.

  Unlike `Studio`/`FieldStore` (the review-gated, persisted character pipeline),
  this operates directly on the flat editor structs and covers **both** the
  character sheet and the world bible via a per-kind field spec. Values come back as
  the display strings the form uses (list-typed fields joined by newlines), so the
  existing save path is unchanged.
  """

  alias Polyphony.LLM.Provider

  # {field, type, guidance}. type: :string (a single value) | :lines (one item/line).
  @character [
    {"name", :string, "the character's name (just the name, a few words)"},
    {"premise", :string, "a one-line hook — who they are and what drives them"},
    {"appearance", :string, "how they look and physically carry themselves"},
    {"voice", :string, "how they speak — diction, rhythm, verbal tics"},
    {"temperament", :string, "core disposition and emotional default"},
    {"backstory", :string, "the formative history behind who they are now"}
  ]

  @world_bible [
    {"name", :string, "the world or setting's name (just the name)"},
    {"setting", :string, "the place, era, and situation the stories happen in"},
    {"tone", :string, "the mood and genre register"},
    {"rules", :lines, "the setting's rules / physics that generation must respect"},
    {"starting_canon", :lines, "established facts true at the very start of play"}
  ]

  @type kind :: :character | :world_bible

  @doc "The generatable fields for a kind, as `{name, type, guidance}` tuples."
  @spec fields(kind()) :: [{String.t(), :string | :lines, String.t()}]
  def fields(:character), do: @character
  def fields(:world_bible), do: @world_bible

  @doc """
  Generate a value for every field from a free-text `brief`. `current` is a map of
  `field => display string` already in the form (seed; may be empty). Returns
  `{:ok, %{field => display string}}` for the fields that came back non-empty.

  `opts[:world]` — an optional map of world-bible display fields (`name`, `setting`,
  `tone`, `rules`, `starting_canon`) used to ground the character in a setting.
  """
  @spec generate_all(kind(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate_all(kind, brief, current \\ %{}, opts \\ []) do
    current = stringify(current)
    specs = fields(kind)
    messages = all_messages(kind, brief, current, specs, opts[:world])
    call = [response: :autofill, fields: Enum.map(specs, &elem(&1, 0))]

    with {:ok, text} <- Polyphony.LLM.call(messages, call ++ meter_opts(opts)),
         {:ok, data} <- decode_object(text) do
      values =
        for {name, type, _g} <- specs, present?(v = Map.get(data, name)), into: %{} do
          {name, normalize(type, v)}
        end

      {:ok, values}
    end
  end

  @doc """
  Regenerate a single `field` from the other fields' values (in `current`), seeded
  by that field's own current content if any. Returns `{:ok, display string}`.
  """
  @spec generate_field(kind(), String.t() | atom(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_field(kind, field, current \\ %{}, opts \\ []) do
    field = to_string(field)
    current = stringify(current)

    case Enum.find(fields(kind), fn {name, _t, _g} -> name == field end) do
      nil ->
        {:error, {:unknown_field, field}}

      {^field, type, guidance} ->
        messages = field_messages(kind, field, type, guidance, current, opts[:world])
        call = [response: :field]

        with {:ok, text} <- Polyphony.LLM.call(messages, call ++ meter_opts(opts)) do
          {:ok, normalize(type, text)}
        end
    end
  end

  # ── Prompt building ──────────────────────────────────────────────────────────

  defp all_messages(kind, brief, current, specs, world) do
    keys = specs |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")
    guide = Enum.map_join(specs, "\n", fn {n, _t, g} -> "- #{n}: #{g}" end)

    [
      %{
        role: "system",
        content:
          "You are helping an author create a #{noun(kind)}. Write vivid, specific, " <>
            "internally consistent content that is ready to use. Return ONLY a JSON " <>
            "object with exactly these keys: #{keys}. Field guidance:\n#{guide}\n" <>
            "Keep each value concise; for list-typed fields return an array of short " <>
            "strings. Build on any values the author already provided and never " <>
            "contradict them."
      },
      %{
        role: "user",
        content:
          "Author's brief:\n#{blank_to_dash(brief)}\n\n" <>
            world_block(world) <> seed_block(current, specs) <> "Return the JSON object now."
      }
    ]
  end

  defp field_messages(kind, field, type, guidance, current, world) do
    others =
      current
      |> Map.drop([field])
      |> Enum.reject(fn {_k, v} -> blank?(v) end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{v}" end)

    others_block = if others == "", do: "", else: "The #{noun(kind)} so far:\n#{others}\n\n"

    seed =
      case Map.get(current, field) do
        v when is_binary(v) and v != "" ->
          "Current draft of #{field} (refine and improve this, keep its intent):\n#{v}\n\n"

        _ ->
          ""
      end

    list_hint = if type == :lines, do: " Put one item per line.", else: ""

    [
      %{
        role: "system",
        content:
          "You are helping an author write ONE field of a #{noun(kind)}: " <>
            "\"#{field}\" — #{guidance}. Return ONLY the text for that field: no field " <>
            "name, no quotes, no JSON, no preamble. Keep it consistent with the rest." <>
            list_hint
      },
      %{
        role: "user",
        content: world_block(world) <> others_block <> seed <> "Write the #{field}:"
      }
    ]
  end

  # A compact rendering of the linked world bible, so generation grounds the
  # character in its setting (backstory/voice that fit the world). Absent → "".
  defp world_block(world) when is_map(world) do
    parts =
      [
        kv("World", world["name"]),
        kv("Setting", world["setting"]),
        kv("Tone", world["tone"]),
        kv("Rules", world["rules"]),
        kv("Starting canon", world["starting_canon"])
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] ->
        ""

      ps ->
        "World context — this character belongs to the following setting; keep them " <>
          "consistent with it:\n" <> Enum.join(ps, "\n") <> "\n\n"
    end
  end

  defp world_block(_), do: ""

  defp kv(_label, v) when v in [nil, ""], do: nil
  defp kv(label, v), do: "#{label}: #{v}"

  defp noun(:character), do: "role-play character"
  defp noun(:world_bible), do: "world bible for a role-play setting"

  defp seed_block(current, specs) do
    filled =
      for {name, _t, _g} <- specs, v = Map.get(current, name), not blank?(v) do
        "- #{name}: #{v}"
      end

    case filled do
      [] -> ""
      lines -> "Already provided (keep and build on these):\n" <> Enum.join(lines, "\n") <> "\n\n"
    end
  end

  # ── Normalizing model output to the form's display strings ────────────────────

  defp normalize(:string, v) when is_list(v),
    do: v |> Enum.map_join(" ", &to_string/1) |> String.trim()

  defp normalize(:string, v), do: v |> to_string() |> String.trim()

  defp normalize(:lines, v) when is_list(v),
    do: v |> Enum.map(&String.trim(to_string(&1))) |> Enum.reject(&(&1 == "")) |> Enum.join("\n")

  defp normalize(:lines, v),
    do:
      v
      |> to_string()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

  # ── JSON extraction (models sometimes wrap objects in prose / code fences) ─────

  defp decode_object(text) do
    cleaned = text |> strip_fences() |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      _ ->
        with sub when is_binary(sub) <- slice_object(cleaned),
             {:ok, map} when is_map(map) <- Jason.decode(sub) do
          {:ok, map}
        else
          _ -> {:error, :invalid_json}
        end
    end
  end

  defp strip_fences(text) do
    text
    |> String.replace(~r/```(?:json)?/i, "")
    |> String.replace("```", "")
  end

  defp slice_object(text) do
    with a when a != nil <- index_of(text, "{"),
         b when b != nil <- last_index_of(text, "}"),
         true <- b > a do
      binary_part(text, a, b - a + 1)
    else
      _ -> nil
    end
  end

  defp index_of(text, char) do
    case :binary.match(text, char) do
      {pos, _} -> pos
      :nomatch -> nil
    end
  end

  defp last_index_of(text, char) do
    case :binary.matches(text, char) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?([]), do: false
  defp present?(_), do: true

  defp blank?(nil), do: true
  defp blank?(v) when is_binary(v), do: String.trim(v) == ""
  defp blank?([]), do: true
  defp blank?(_), do: false

  defp blank_to_dash(nil), do: "(no brief — invent something evocative)"
  defp blank_to_dash(""), do: "(no brief — invent something evocative)"
  defp blank_to_dash(text), do: text

  # Options handed to the metered LLM call: the provider + heavy model, usage
  # attribution (user/campaign/kind), and the test `:respond_with` passthrough.
  defp meter_opts(opts) do
    [provider: Keyword.get(opts, :provider) || Provider.default(), model: model(opts)] ++
      Keyword.take(opts, [:respond_with, :user_id, :campaign_id, :usage_kind])
  end

  defp model(opts) do
    Keyword.get(opts, :model) ||
      get_in(Application.get_env(:polyphony, :llm, []), [:models, :heavy])
  end
end

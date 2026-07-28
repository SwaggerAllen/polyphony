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
    messages = all_messages(kind, brief, current, specs, context(opts))
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
        messages = field_messages(kind, field, type, guidance, current, context(opts))
        call = [response: :field]

        with {:ok, text} <- Polyphony.LLM.call(messages, call ++ meter_opts(opts)) do
          {:ok, normalize(type, text)}
        end
    end
  end

  @doc """
  Generate a single paragraph of `field`. With `opts[:index]` set, rewrites that
  paragraph (richer, same role); with `:index` nil, writes a NEW paragraph that
  deepens the field without repeating it (the "expand" action). `opts[:blocks]` is
  the field's current paragraphs, `:current` the other fields, plus the usual
  `:world` / `:relations` context. Returns `{:ok, paragraph}`.
  """
  @spec generate_paragraph(kind(), String.t() | atom(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_paragraph(kind, field, opts \\ []) do
    field = to_string(field)

    case Enum.find(fields(kind), fn {name, _t, _g} -> name == field end) do
      nil ->
        {:error, {:unknown_field, field}}

      {^field, type, guidance} ->
        messages =
          paragraph_messages(
            kind,
            field,
            type,
            guidance,
            opts[:blocks] || [],
            opts[:index],
            stringify(opts[:current] || %{}),
            context(opts)
          )

        with {:ok, text} <- Polyphony.LLM.call(messages, [response: :field] ++ meter_opts(opts)) do
          {:ok, String.trim(text)}
        end
    end
  end

  @doc """
  Propose relationships for a character from its fields + context. Returns
  `{:ok, [%{"target" => name, "descriptor" => how_they_regard_them}]}`. The caller
  decides which to accept (and new names stub on save, like a typed relationship).

  `opts[:existing]` — the character's current relationships (maps or `%Relationship{}`
  structs). They're shown to the model as "already present, don't repeat", and any
  suggestion matching one (or the character itself) is filtered out — so re-running
  never re-proposes a relationship the character already has.
  """
  @spec suggest_relationships(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def suggest_relationships(current, opts \\ []) do
    current = stringify(current)
    existing = normalize_existing(opts[:existing] || [])
    self_name = to_string(current["name"] || "")

    messages = [
      %{
        role: "system",
        content:
          "You are helping an author populate a role-play character's relationships. " <>
            "Propose 3–5 people this character would plausibly know. Do NOT propose anyone " <>
            "already listed, and do not propose the character themselves. Return ONLY a JSON " <>
            "array of objects, each with keys \"target\" (the other person's name) and " <>
            "\"descriptor\" (how THIS character regards them — a short phrase)."
      },
      %{
        role: "user",
        content:
          context_block(context(opts)) <>
            character_block(current) <> existing_block(existing, self_name)
      }
    ]

    with {:ok, text} <-
           Polyphony.LLM.call(messages, [response: :relationships] ++ meter_opts(opts)),
         {:ok, list} <- decode_array(text) do
      excluded =
        [self_name | Enum.map(existing, & &1["target"])]
        |> Enum.map(&normalize_name/1)
        |> Enum.reject(&(&1 == ""))
        |> MapSet.new()

      suggestions =
        list
        |> Enum.filter(&is_map/1)
        |> Enum.map(fn item ->
          %{
            "target" => String.trim(to_string(item["target"] || "")),
            "descriptor" => String.trim(to_string(item["descriptor"] || ""))
          }
        end)
        |> Enum.reject(
          &(&1["target"] == "" or MapSet.member?(excluded, normalize_name(&1["target"])))
        )
        |> Enum.uniq_by(&normalize_name(&1["target"]))

      {:ok, suggestions}
    end
  end

  defp normalize_name(name), do: name |> to_string() |> String.trim() |> String.downcase()

  defp normalize_existing(list) do
    for item <- list, t = existing_target(item), present?(t) do
      %{"target" => to_string(t), "descriptor" => to_string(existing_descriptor(item) || "")}
    end
  end

  defp existing_target(%{"target" => t}), do: t
  defp existing_target(%{target: t}), do: t
  defp existing_target(_), do: nil

  defp existing_descriptor(%{"descriptor" => d}), do: d
  defp existing_descriptor(%{descriptor: d}), do: d
  defp existing_descriptor(_), do: nil

  defp existing_block([], _self_name), do: ""

  defp existing_block(existing, _self_name) do
    lines = Enum.map_join(existing, "\n", fn e -> "- #{e["target"]}: #{e["descriptor"]}" end)

    "\nAlready has these relationships (do NOT propose these people again):\n" <> lines <> "\n"
  end

  # ── Prompt building ──────────────────────────────────────────────────────────

  defp paragraph_messages(kind, field, type, guidance, blocks, index, current, ctx) do
    others =
      current
      |> Map.drop([field])
      |> Enum.reject(fn {_k, v} -> blank?(v) end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{v}" end)

    others_block = if others == "", do: "", else: "The #{noun(kind)} so far:\n#{others}\n\n"
    nonempty = Enum.reject(blocks, &blank?/1)
    unit = if type == :lines, do: "item", else: "paragraph"

    instruction =
      cond do
        is_integer(index) and index < length(blocks) ->
          numbered =
            blocks |> Enum.with_index() |> Enum.map_join("\n", fn {b, i} -> "#{i + 1}. #{b}" end)

          "The #{field} so far, #{unit} by #{unit}:\n#{numbered}\n\nRewrite #{unit} " <>
            "#{index + 1} to be richer and more specific — keep its role and stay consistent " <>
            "with the rest. Return only that #{unit}."

        nonempty == [] ->
          "Write the opening #{unit} of the #{field}."

        true ->
          "The #{field} so far:\n#{Enum.join(nonempty, "\n\n")}\n\nWrite a NEW #{unit} that " <>
            "deepens the #{field} — add fresh, specific detail; do not repeat what's already " <>
            "there. Return only the new #{unit}."
      end

    shape =
      if type == :lines,
        do: "Write ONE concise item — a single line, not a paragraph.",
        else: "Write ONE vivid paragraph of prose."

    [
      %{
        role: "system",
        content:
          "You are helping an author write the \"#{field}\" of a #{noun(kind)} — #{guidance}. " <>
            "#{shape} Return only the #{unit}: no label, no numbering, no quotes, no JSON."
      },
      %{role: "user", content: context_block(ctx) <> others_block <> instruction}
    ]
  end

  defp character_block(current) do
    case for {k, v} <- current, not blank?(v), do: "#{k}: #{v}" do
      [] -> "The character has no details yet — invent evocative, specific connections.\n"
      lines -> "The character:\n" <> Enum.join(lines, "\n") <> "\n"
    end
  end

  defp all_messages(kind, brief, current, specs, ctx) do
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
            context_block(ctx) <> seed_block(current, specs) <> "Return the JSON object now."
      }
    ]
  end

  defp field_messages(kind, field, type, guidance, current, ctx) do
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
        content: context_block(ctx) <> others_block <> seed <> "Write the #{field}:"
      }
    ]
  end

  # The generation context (world bible + related character sheets + a former stub's
  # inherited role), pulled from opts.
  defp context(opts),
    do: %{world: opts[:world], relations: opts[:relations], role: opts[:role]}

  defp context_block(%{} = ctx),
    do: role_block(ctx[:role]) <> world_block(ctx[:world]) <> relations_block(ctx[:relations])

  defp context_block(_), do: ""

  # A character stubbed from another's relationships carries a one-line `role` (how
  # that source character described them, e.g. "estranged mentor"). Feed it into
  # generation so the seed the author already committed to survives — the generated
  # sheet realizes that role rather than inventing an unrelated person. Absent → "".
  defp role_block(role) when is_binary(role) and role != "" do
    "This character was introduced through another character as their \"#{role}\". " <>
      "Honor that role — the generated details should realize it, not contradict it.\n\n"
  end

  defp role_block(_), do: ""

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

  # Compact sheets of this character's immediate relationships, so generated
  # backstory/voice fit the people they're connected to. Each entry is one line.
  defp relations_block(relations) when is_list(relations) and relations != [] do
    lines =
      Enum.map_join(relations, "\n", fn r ->
        facets =
          [
            kv("premise", r["premise"]),
            kv("voice", r["voice"]),
            kv("temperament", r["temperament"]),
            kv("backstory", r["backstory"])
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" | ")

        regard = if r["descriptor"] in [nil, ""], do: "", else: " (#{r["descriptor"]})"
        "- #{r["name"]}#{regard}: #{facets}"
      end)

    "Related characters — this character's connections; keep them consistent with " <>
      "these people:\n" <> lines <> "\n\n"
  end

  defp relations_block(_), do: ""

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

  defp decode_array(text) do
    cleaned = text |> strip_fences() |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, list} when is_list(list) ->
        {:ok, list}

      _ ->
        with a when a != nil <- index_of(cleaned, "["),
             b when b != nil <- last_index_of(cleaned, "]"),
             true <- b > a,
             {:ok, list} when is_list(list) <- Jason.decode(binary_part(cleaned, a, b - a + 1)) do
          {:ok, list}
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

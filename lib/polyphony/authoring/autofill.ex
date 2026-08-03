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
    {"pronouns", :string,
     "the pronouns they go by, as a pair like \"she / her\", \"he / him\" or " <>
       "\"they / them\" — write what suits the character, and don't assume from the name"},
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

  @doc """
  Propose **pressures** (§A3 — played as scene beats, never filters) from the
  character's fields + context. Returns
  `{:ok, [%{"topic","stance","direction","condition","on_pressure","after_release","category"}]}`;
  `:existing` topics are shown as "don't repeat" and filtered out. `stance` ∈
  closed|conditional|open; `direction` ∈ refusal|compulsion; `category` ∈
  sexual|graphic_violence|other|"" (blank ⇒ pure characterization).

  Both directions are asked for, and roughly evenly: the thing a character *can't
  stop* doing is the same gate with the sign flipped and is usually the better story
  engine, so a suggester that only proposed refusals would quietly halve what the
  feature is for.
  """
  @spec suggest_boundaries(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def suggest_boundaries(current, opts \\ []) do
    current = stringify(current)

    existing_topics =
      opts[:existing] |> List.wrap() |> Enum.map(&boundary_topic/1) |> Enum.reject(&(&1 == ""))

    messages = [
      %{
        role: "system",
        content:
          "You are helping an author populate the places a role-play character can be " <>
            "pushed. These are played as scene beats, never as a content filter. Propose 2–4 " <>
            "**conditional** ones: things that hold FOR NOW but that the right story " <>
            "development could change — slow burns, not permanent absolutes. Mix the two " <>
            "DIRECTIONS roughly evenly: a \"refusal\" is something they won't do; a " <>
            "\"compulsion\" is something they can't stop doing (covering for someone, signing " <>
            "whatever is put in front of them, going back to a place). A compulsion is often " <>
            "the more dramatic of the two — propose at least one. Choose topics that " <>
            "plausibly shift with the story (intimacy, trust, loyalty, opening up, using " <>
            "violence, revealing a secret, protecting someone), NOT absolute taboos. TWO " <>
            "RULES: (1) The topic and its condition must share the same scope. If it is about " <>
            "a SPECIFIC person, name them in the topic (e.g. \"Physical intimacy with Jack\") " <>
            "— never gate a broad, everyone topic on one person's arc. If the topic is " <>
            "general, keep the condition general too. (2) The condition must be ONE concrete " <>
            "development the story can clearly reach — a single checkable event, not several " <>
            "bundled together (avoid \"and\"/\"both\"), and not a vague mood. Return ONLY a " <>
            "JSON array of objects, each with keys \"topic\" (what it is about), " <>
            "\"direction\" (\"refusal\" or \"compulsion\"), \"condition\" (REQUIRED, " <>
            "non-empty — the one thing that must happen first), \"on_pressure\" (how they " <>
            "react when pushed against it, optional), \"after_release\" (what they are like " <>
            "once it turns, optional), and \"category\" (\"sexual\", \"graphic_violence\", " <>
            "\"other\", or \"\" for pure characterization). Do NOT repeat a topic already listed."
      },
      %{
        role: "user",
        content:
          context_block(context(opts)) <>
            character_block(current) <> existing_boundaries_block(existing_topics)
      }
    ]

    with {:ok, text} <-
           Polyphony.LLM.call(messages, [response: :boundaries] ++ meter_opts(opts)),
         {:ok, list} <- decode_array(text) do
      excluded = existing_topics |> Enum.map(&normalize_name/1) |> MapSet.new()

      boundaries =
        list
        |> Enum.filter(&is_map/1)
        |> Enum.map(&normalize_boundary/1)
        # A generated boundary must carry a topic AND a condition — a conditional line
        # with nothing to earn is meaningless, so drop it rather than persist a blank.
        |> Enum.reject(
          &(&1["topic"] == "" or &1["condition"] == "" or
              MapSet.member?(excluded, normalize_name(&1["topic"])))
        )
        |> Enum.uniq_by(&normalize_name(&1["topic"]))

      {:ok, boundaries}
    end
  end

  @categories ~w(sexual graphic_violence other)

  defp normalize_boundary(item) do
    category = item["category"] |> to_string() |> String.trim() |> String.downcase()
    direction = item["direction"] |> to_string() |> String.trim() |> String.downcase()

    %{
      "topic" => String.trim(to_string(item["topic"] || "")),
      # Generated pressures are always **conditional** slow-burns (§A3) — an auto-proposed
      # hard line or "open" non-boundary isn't worth surfacing; the author sets those by
      # hand in the editor, where every stance is available.
      "stance" => "conditional",
      # Anything the model didn't say plainly is a refusal: it's the reading that can
      # only make a character less likely to act, which is the direction to fail in.
      "direction" => if(direction == "compulsion", do: "compulsion", else: "refusal"),
      "condition" => String.trim(to_string(item["condition"] || "")),
      "on_pressure" => String.trim(to_string(item["on_pressure"] || "")),
      "after_release" => String.trim(to_string(item["after_release"] || "")),
      "category" => if(category in @categories, do: category, else: "")
    }
  end

  defp boundary_topic(%{topic: t}), do: to_string(t || "")
  defp boundary_topic(%{"topic" => t}), do: to_string(t || "")
  defp boundary_topic(_), do: ""

  defp existing_boundaries_block([]), do: ""

  defp existing_boundaries_block(topics),
    do: "\n\nAlready has boundaries about (do not repeat): " <> Enum.join(topics, ", ") <> "."

  @doc """
  Generate the **reciprocal** of each relationship — how the *other* person regards
  the source character, given how the source regards them. Relationships are usually
  asymmetrical (a "mentor" is regarded back as a "student"), so a stub seeded from a
  source character's relationship needs its own regard generated, not the source's
  descriptor copied.

  `source` is the source character's fields (for context); `pairs` is a list of
  `%{"target" => name, "descriptor" => how_source_regards_them}`. Returns
  `{:ok, %{target => reciprocal_descriptor}}` — only the pairs that came back
  non-empty. An empty `pairs` list short-circuits without a provider call.
  """
  @spec reciprocal_roles(map(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def reciprocal_roles(_source, [], _opts), do: {:ok, %{}}

  def reciprocal_roles(source, pairs, opts) do
    source = stringify(source)
    self_name = to_string(source["name"] || "this character")
    listed = Enum.map_join(Enum.with_index(pairs, 1), "\n", &pair_line(&1, self_name))

    messages = [
      %{
        role: "system",
        content:
          "You are helping an author with character relationships. For each numbered pair " <>
            "you are told how #{self_name} regards another person. Write how THAT person " <>
            "would regard #{self_name} in return — the reciprocal. It is usually NOT the " <>
            "same (a \"mentor\" is regarded back as a \"student\"; a \"captor\" as a " <>
            "\"prisoner\"). Return ONLY a JSON array of short strings — one reciprocal per " <>
            "pair, in the SAME order, no names, no keys."
      },
      %{
        role: "user",
        content:
          source_block(source) <>
            "Pairs (how #{self_name} regards each person):\n" <>
            listed <> "\n\nReturn the JSON array."
      }
    ]

    call = [response: :reciprocals, count: length(pairs)]

    with {:ok, text} <- Polyphony.LLM.call(messages, call ++ meter_opts(opts)),
         {:ok, list} <- decode_array(text) do
      recips =
        pairs
        |> Enum.zip(list ++ List.duplicate(nil, max(length(pairs) - length(list), 0)))
        |> Enum.reduce(%{}, fn {pair, raw}, acc ->
          case String.trim(to_string(raw || "")) do
            "" -> acc
            r -> Map.put(acc, to_string(pair["target"]), r)
          end
        end)

      {:ok, recips}
    end
  end

  @doc """
  Generate how `source` regards each of the named `targets` — the directional
  descriptor for a relationship (`source → target`). Used by Quick Build to cross-link
  a freshly-built cast: each character gets a one-line regard toward every other. Returns
  `{:ok, %{target_name => descriptor}}`, only the targets that came back non-empty. An
  empty `targets` list short-circuits without a provider call.
  """
  @spec regard_map(map(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def regard_map(_source, [], _opts), do: {:ok, %{}}

  def regard_map(source, targets, opts) do
    source = stringify(source)
    self_name = to_string(source["name"] || "this character")
    listed = Enum.map_join(targets, "\n", &"- #{&1}")

    messages = [
      %{
        role: "system",
        content:
          "You are helping an author connect a role-play cast. For each person listed, " <>
            "write how #{self_name} regards them — a short phrase (\"old rival\", \"the sister " <>
            "she failed\", \"a debt she can't repay\"), true to the character and the setting. " <>
            "Return ONLY a JSON object mapping each person's EXACT name to that phrase, e.g. " <>
            "{\"Jack\": \"old rival\", \"Mara\": \"trusted lieutenant\"}. Every listed person " <>
            "must appear as a key; do not add anyone else."
      },
      %{
        role: "user",
        content:
          source_block(source) <>
            "People #{self_name} knows:\n" <> listed <> "\n\nReturn the JSON object."
      }
    ]

    # An OBJECT keyed by name (not an ordered array) — this is what DeepInfra's forced
    # `json_object` mode actually returns, so it parses cleanly, and matching by name is
    # robust to the model reordering or renaming. `:targets` lets the Mock echo the keys.
    call = [response: :regards, targets: targets]

    with {:ok, text} <- Polyphony.LLM.call(messages, call ++ meter_opts(opts)),
         {:ok, obj} when is_map(obj) <- decode_object(text) do
      by_name = Map.new(obj, fn {k, v} -> {normalize_name(k), v} end)

      map =
        for target <- targets,
            r = String.trim(to_string(Map.get(by_name, normalize_name(target)) || "")),
            r != "",
            into: %{},
            do: {to_string(target), r}

      {:ok, map}
    end
  end

  @doc """
  Generate (or expand) a **campaign premise** — the one-paragraph pitch of what the
  story is about — grounded in the campaign's world and cast. With `opts[:current]`
  set to an existing premise, it *deepens* that premise instead of replacing it (the
  ✨ Expand action); otherwise it writes a fresh one. `opts[:world]` is the world-bible
  display map; `opts[:cast]` a list of `%{"name","premise"}` maps. Returns `{:ok, text}`.
  """
  @spec generate_campaign_premise(keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate_campaign_premise(opts \\ []) do
    world = opts[:world]
    cast = opts[:cast] || []
    current = opts[:current]

    instruction =
      case current do
        s when is_binary(s) and s != "" ->
          "The premise so far:\n#{s}\n\nDeepen and sharpen it — raise the stakes and make " <>
            "the central tension concrete, without contradicting what's there. Return the " <>
            "revised premise as one paragraph."

        _ ->
          "Write the premise: one vivid paragraph naming the central tension and what's at " <>
            "stake for this cast. Return only the paragraph."
      end

    messages = [
      %{
        role: "system",
        content:
          "You are helping an author frame a role-play campaign. Write a premise — what the " <>
            "story is about — grounded in the world and cast below. Return only the prose: no " <>
            "title, no label, no quotes, no JSON."
      },
      %{
        role: "user",
        content: world_block(world) <> campaign_cast_block(cast) <> instruction
      }
    ]

    with {:ok, text} <- Polyphony.LLM.call(messages, [response: :field] ++ meter_opts(opts)) do
      {:ok, String.trim(text)}
    end
  end

  defp campaign_cast_block([]), do: ""

  defp campaign_cast_block(cast) do
    lines =
      Enum.map_join(cast, "\n", fn c ->
        premise = c["premise"] || c[:premise]
        regard = if premise in [nil, ""], do: "", else: " — #{premise}"
        "- #{c["name"] || c[:name]}#{regard}"
      end)

    "The cast:\n" <> lines <> "\n\n"
  end

  @doc """
  Generate (or expand) a **scene premise** — the immediate situation as *this* scene
  opens (§2.3). Distinct from `generate_campaign_premise/1`: it's scene-aware,
  grounded in where the scene takes place and what's happened before it, so the
  Director gets the author's intent for this scene rather than inferring it.

  Opts: `opts[:world]` (world display map), `opts[:cast]` (`[%{"name","premise"}]`),
  `opts[:location]` (the authored setting), `opts[:campaign_premise]` (the campaign's
  overall pitch, for grounding), `opts[:recent]` (previous-scene summaries, `[text]`,
  newest last), and `opts[:current]` (an existing scene premise to deepen — the ✨
  Expand action). Returns `{:ok, text}`, one paragraph.
  """
  @spec generate_scene_premise(keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate_scene_premise(opts \\ []) do
    instruction =
      case opts[:current] do
        s when is_binary(s) and s != "" ->
          "The scene premise so far:\n#{s}\n\nDeepen and sharpen it — make the immediate " <>
            "situation and what's at stake concrete, without contradicting it or the story so " <>
            "far. Return the revised scene premise as one paragraph."

        _ ->
          "Write the scene premise: one vivid paragraph naming the immediate situation as the " <>
            "scene opens and what's in the air for the characters present. Return only the paragraph."
      end

    messages = [
      %{
        role: "system",
        content:
          "You are helping an author set up the next scene of a role-play campaign. Write a " <>
            "**scene** premise — the immediate situation as this scene opens, not the whole " <>
            "campaign — grounded in the world, cast, setting, and what's happened so far below. " <>
            "Return only the prose: no title, no label, no quotes, no JSON."
      },
      %{
        role: "user",
        content:
          world_block(opts[:world]) <>
            campaign_premise_block(opts[:campaign_premise]) <>
            location_block(opts[:location]) <>
            campaign_cast_block(opts[:cast] || []) <>
            story_so_far_block(opts[:recent] || []) <>
            instruction
      }
    ]

    with {:ok, text} <- Polyphony.LLM.call(messages, [response: :field] ++ meter_opts(opts)) do
      {:ok, String.trim(text)}
    end
  end

  defp campaign_premise_block(p) when is_binary(p) and p != "",
    do: "The campaign is about:\n#{p}\n\n"

  defp campaign_premise_block(_), do: ""

  defp location_block(loc) when is_binary(loc) and loc != "", do: "Location: #{loc}\n\n"
  defp location_block(_), do: ""

  defp story_so_far_block([]), do: ""

  defp story_so_far_block(recent),
    do:
      "The story so far (earlier scenes):\n" <> Enum.map_join(recent, "\n", &"- #{&1}") <> "\n\n"

  @doc """
  Extract the proper names of **people/characters** mentioned in `texts` (a scene's
  committed prose) — not places, objects, or groups. Returns `{:ok, [name]}`, de-duped
  case-insensitively. Empty input short-circuits without a provider call. The caller
  filters out characters that already exist and stubs the rest (§B8 mention-stubbing).
  """
  @spec extract_mentions([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def extract_mentions(texts, opts \\ []) do
    joined = texts |> List.wrap() |> Enum.reject(&blank?/1) |> Enum.join("\n\n")

    if String.trim(joined) == "" do
      {:ok, []}
    else
      messages = [
        %{
          role: "system",
          content:
            "List the proper names of PEOPLE / characters mentioned in the passage — not " <>
              "places, objects, or groups, and not the narrator. Return ONLY a JSON array of " <>
              "names (strings); an empty array if none."
        },
        %{role: "user", content: joined}
      ]

      with {:ok, text} <- Polyphony.LLM.call(messages, [response: :mentions] ++ meter_opts(opts)),
           {:ok, list} <- decode_array(text) do
        names =
          list
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq_by(&String.downcase/1)

        {:ok, names}
      end
    end
  end

  defp pair_line({pair, i}, self_name),
    do: "#{i}. #{self_name} regards #{pair["target"]} as \"#{pair["descriptor"]}\"."

  defp source_block(source) do
    case for(f <- ~w(name premise temperament), v = source[f], not blank?(v), do: "#{f}: #{v}") do
      [] -> ""
      lines -> "The character:\n" <> Enum.join(lines, "\n") <> "\n\n"
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

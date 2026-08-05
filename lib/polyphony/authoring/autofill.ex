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
    {"backstory", :string, "the formative history behind who they are now"},
    # A list, like a world's rules: each is one statement an author can mark secret
    # on its own. Last in the order deliberately — these are read off the character
    # the fields above have already established, not invented alongside them.
    {"facts", :lines,
     "things that are true about them right now — circumstances, ties, what they " <>
       "owe or are owed, what they are hiding; one statement per line"}
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

  `opts[:ensemble]` — the people **already written into this story**, as
  `%{"name","premise","voice","temperament"}` maps. Distinct from `opts[:relations]`,
  which is who a character is *connected to* and asks for consistency with them; this
  one asks for continuity of world detail and **distinctness of person**. A blank brief
  makes the difference load-bearing — with nothing else in the prompt, "be consistent
  with these people" writes them again.

  `opts[:cast_seeds]` — one-line seeds for characters *about to be written* into what
  is being generated. Quick Build writes the world first, so without these it writes
  it blind: a world that needs a harbour-master invents and names one, and the cast
  then names the same seed somebody else. The block tells the model the roles may be
  needed and the people are not its to name.
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
  Propose **facts** — short, flat statements that are true about the character.

  `ux/polyphony-character.html` §03 defines them and what they're for: *what she'd
  never contradict, so keep them to things you'd defend rather than things you'd
  like.* Returns `{:ok, [%{"statement","core","concealed"}]}`; `:existing` statements
  are shown as "don't repeat" and filtered out.

  The model may flag a fact **core** (always resident) or **concealed** (a secret),
  and is told to be sparing with the first: the drawer's own nudge is that *a few is
  right*, because always-in-mind is context every turn of every scene and twenty of
  them is a quality problem.
  """
  @spec suggest_facts(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def suggest_facts(current, opts \\ []) do
    current = stringify(current)

    existing =
      opts[:existing] |> List.wrap() |> Enum.map(&fact_statement/1) |> Enum.reject(&(&1 == ""))

    messages = [
      %{
        role: "system",
        content:
          "You are helping an author populate the facts on a role-play character sheet. A " <>
            "fact is a SHORT, FLAT statement that is simply true about them — the kind of " <>
            "thing they would never contradict. Concrete and defensible, not aspirational " <>
            "and not a mood. Propose 4–6. For each, two independent flags: \"core\" (true " <>
            "if it is something they would never stop being aware of — be sparing, a few " <>
            "at most) and \"concealed\" (true if nobody else starts out knowing it). The " <>
            "two are orthogonal: someone can have a secret they rarely think about. Return " <>
            "ONLY a JSON array of objects with keys \"statement\", \"core\" and " <>
            "\"concealed\". Do NOT repeat anything already listed."
      },
      %{
        role: "user",
        content:
          context_block(context(opts)) <>
            character_block(current) <> existing_facts_block(existing)
      }
    ]

    with {:ok, text} <- Polyphony.LLM.call(messages, [response: :facts] ++ meter_opts(opts)),
         {:ok, list} <- decode_array(text) do
      excluded = existing |> Enum.map(&normalize_name/1) |> MapSet.new()

      facts =
        list
        |> Enum.filter(&is_map/1)
        |> Enum.map(fn item ->
          %{
            "statement" => String.trim(to_string(item["statement"] || "")),
            "core" => truthy?(item["core"]),
            "concealed" => truthy?(item["concealed"])
          }
        end)
        |> Enum.reject(
          &(&1["statement"] == "" or MapSet.member?(excluded, normalize_name(&1["statement"])))
        )
        |> Enum.uniq_by(&normalize_name(&1["statement"]))

      {:ok, facts}
    end
  end

  defp fact_statement(%{statement: s}), do: to_string(s || "")
  defp fact_statement(%{"statement" => s}), do: to_string(s || "")
  defp fact_statement(_), do: ""

  defp existing_facts_block([]), do: ""

  defp existing_facts_block(statements),
    do:
      "\n\nAlready true of them (do not repeat):\n" <> Enum.map_join(statements, "\n", &"- #{&1}")

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

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

  **Every other key flips with the direction**, and the prompt has to say so per
  direction or half the results come out inverted. A refusal's `condition` is what makes
  her *willing*; a compulsion's is what finally lets her *stop*. `on_pressure` is being
  pushed to do it, versus someone trying to stop her — which is exactly how
  `Context.boundary_line/1` renders the two (`"When pushed:"` / `"When someone tries to
  stop you:"`). The domain and the renderer had the flip from the start; the prompt
  described all three keys in refusal-only language, so a generated compulsion arrived
  with a condition meaning *what would make her start* and was then rendered as *what
  would make her stop*.
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
            "DIRECTIONS roughly evenly; a compulsion is often the more dramatic of the two, " <>
            "so propose at least one.\n\n" <>
            "THE TWO DIRECTIONS ARE MIRRORS, AND EVERY OTHER FIELD FLIPS WITH THEM. Write " <>
            "each one from its own side or it will read backwards:\n\n" <>
            "* \"refusal\" — something they WON'T DO. The topic is the thing they hold back " <>
            "from, as a noun phrase (\"Physical intimacy with Jack\", \"Naming her source\"). " <>
            "\"condition\" is what would make them WILLING. \"on_pressure\" is how they react " <>
            "when someone pushes them TO DO IT. \"after_release\" is what they are like once " <>
            "they will.\n" <>
            "* \"compulsion\" — something they CAN'T STOP DOING. The topic is the thing they " <>
            "keep doing, as an action (\"Covering for her father\", \"Going back to the " <>
            "quay\", \"Signing whatever is put in front of her\") — never a bare quality like " <>
            "\"Trust\" or \"Loyalty\", which cannot be stopped doing. \"condition\" is what " <>
            "would finally let them STOP — the opposite of a refusal's. \"on_pressure\" is " <>
            "how they react when someone tries to STOP THEM. \"after_release\" is what they " <>
            "are like once they have broken it.\n\n" <>
            "Choose topics that plausibly shift with the story, NOT absolute taboos — for a " <>
            "refusal, things like intimacy, trust, opening up, using violence, revealing a " <>
            "secret; for a compulsion, the habits and loyalties they keep returning to. TWO " <>
            "RULES: (1) The topic and its condition must share the same scope. If it is about " <>
            "a SPECIFIC person, name them in the topic (e.g. \"Physical intimacy with Jack\") " <>
            "— never gate a broad, everyone topic on one person's arc. If the topic is " <>
            "general, keep the condition general too. (2) The condition must be ONE concrete " <>
            "development the story can clearly reach — a single checkable event, not several " <>
            "bundled together (avoid \"and\"/\"both\"), and not a vague mood. Return ONLY a " <>
            "JSON array of objects, each with keys \"topic\", \"direction\" (\"refusal\" or " <>
            "\"compulsion\"), \"condition\" (REQUIRED, non-empty), \"on_pressure\" " <>
            "(optional), \"after_release\" (optional), and \"category\" (\"sexual\", " <>
            "\"graphic_violence\", \"other\", or \"\" for pure characterization). Do NOT " <>
            "repeat a topic already listed."
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

  @doc """
  Name the campaign and write its premise, in one call.

  Quick Build's, and the reason it isn't two: a title is a *read* on the premise — the
  phrase that says what the story is about once you know what it's about. Asked for on
  its own it has only the world seed to go on and returns the setting's name back; asked
  for beside the premise it can name the tension. Everything else Quick Build writes it
  writes for you, and a campaign called "Untitled campaign" in the library is the one
  gap the author has to close by hand before anything reads as theirs.

  Same grounding as `generate_campaign_premise/1` — `opts[:world]` display map,
  `opts[:cast]` a list of `%{"name","premise"}`. Returns
  `{:ok, %{"name" => String.t(), "premise" => String.t()}}`; the caller decides whether
  the name is wanted, and Quick Build only takes it when the author left theirs blank.
  """
  @spec generate_campaign_opening(keyword()) :: {:ok, map()} | {:error, term()}
  def generate_campaign_opening(opts \\ []) do
    messages = [
      %{
        role: "system",
        content:
          "You are helping an author frame a role-play campaign. Give it a **name** and a " <>
            "**premise**, grounded in the world and cast below.\n\n" <>
            "The name is a title for this story — two to four words, the kind of phrase that " <>
            "sits on a spine. It names the tension, not the setting: the world already has a " <>
            "name and repeating it says nothing. No subtitle, no colon, no quotes, no article " <>
            "unless it earns one.\n\n" <>
            "The premise is one vivid paragraph naming the central tension and what is at " <>
            "stake for this cast. It says what the story is *about*; it does not decide how " <>
            "it ends.\n\n" <>
            "Return ONLY a JSON object with exactly these keys: name, premise."
      },
      %{
        role: "user",
        content: world_block(opts[:world]) <> campaign_cast_block(opts[:cast] || [])
      }
    ]

    with {:ok, text} <-
           Polyphony.LLM.call(
             messages,
             [response: :autofill, fields: ["name", "premise"]] ++ meter_opts(opts)
           ),
         {:ok, data} <- decode_object(text) do
      {:ok,
       %{
         "name" => String.trim(to_string(Map.get(data, "name") || "")),
         "premise" => String.trim(to_string(Map.get(data, "premise") || ""))
       }}
    end
  end

  @doc """
  The **collectives this world already names**, and who in the cast belongs to them.

  A world bible full of crews, households and orders is a world where half the cast
  should start out sharing what that crew knows — and the group is exactly the thing
  the design provides for it: *written like a character, used as a starting point for
  others, and somewhere for a secret to point* (`Group`). Written by hand it is a
  chore nobody does; and a cast written without them each invents their own private
  version of the same institution.

  **One call, groups and membership together**, because the model naming "the
  Tidewatch" is the one best placed to say which of these seeds are in it — it has both
  in front of it. A second call would be asked to re-derive the reasoning that produced
  the first.

  `opts[:world]` is the world display map; `opts[:cast_seeds]` the character briefs, in
  order — `members` comes back as **indexes into that list**, so a blank seed can be
  placed as easily as a described one.

  Facts carry `concealed`, unlike the flat lists elsewhere. A group with no secrets is
  a group with nothing to point at: `Group.secrets/1` exists, the design's own row
  reads *"6 members · 2 secrets"*, and knowing them is what belonging is defined to
  mean. Marking one secret is also the safe direction under default-deny — an
  over-marked fact makes a character know too little, never too much.

  Returns `{:ok, [%{"name", "premise", "appearance", "temperament", "backstory",
  "facts" => [%{"statement", "concealed"}], "members" => [index]}]}`.
  """
  @spec suggest_groups(keyword()) :: {:ok, [map()]} | {:error, term()}
  def suggest_groups(opts \\ []) do
    seeds = opts[:cast_seeds] |> List.wrap() |> Enum.map(&to_string/1)

    messages = [
      %{
        role: "system",
        content:
          "You are helping an author set up a role-play campaign. Find the **collectives** " <>
            "this world names or clearly implies — a crew, a household, an order, a watch, a " <>
            "firm — and write each one as a shared starting point for the people in it.\n\n" <>
            "Propose 1–3. Only ones this world actually supports; two good ones beat four " <>
            "invented to fill a list, and none at all is a valid answer for a world that " <>
            "names no institutions.\n\n" <>
            "A group is character-shaped but collective: `premise` is what it is and what it " <>
            "wants, `appearance` how its people are recognised, `temperament` how it behaves " <>
            "under pressure, `backstory` where it came from.\n\n" <>
            "`facts` are what belonging *gets you*: 2–4 flat statements a member would take " <>
            "as given. Mark `concealed` true on the ones outsiders do not know — a group " <>
            "whose facts are all public is a label rather than a membership, and the secrets " <>
            "are the reason it is worth writing.\n\n" <>
            "`members` lists the indexes of the cast briefs below that plainly belong to it. " <>
            "Leave it empty rather than forcing a fit; a character can be in no group, and a " <>
            "group can exist with nobody in it yet. Nobody belongs to two.\n\n" <>
            "Return ONLY a JSON array of objects with keys: name, premise, appearance, " <>
            "temperament, backstory, facts (array of {statement, concealed}), members " <>
            "(array of integers)."
      },
      %{
        role: "user",
        content: world_block(opts[:world]) <> seed_index_block(seeds)
      }
    ]

    with {:ok, text} <- Polyphony.LLM.call(messages, [response: :facts] ++ meter_opts(opts)),
         {:ok, list} <- decode_array(text) do
      {:ok, for(item <- list, is_map(item), g = normalize_group(item, length(seeds)), g, do: g)}
    end
  end

  defp seed_index_block([]), do: "There is no cast yet — return groups with empty members.\n\n"

  defp seed_index_block(seeds) do
    lines =
      seeds
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {seed, i} ->
        "#{i}: #{if String.trim(seed) == "", do: "(no brief — anyone this story needs)", else: seed}"
      end)

    "The cast about to be written, by index:\n" <> lines <> "\n\n"
  end

  # A group with no name is not a group. Everything else may be blank, and `members` is
  # clamped to real indexes — a hallucinated index would otherwise seed a character who
  # does not exist, or crash the walk.
  defp normalize_group(item, seed_count) do
    name = String.trim(to_string(item["name"] || ""))

    if name == "" do
      nil
    else
      %{
        "name" => name,
        "premise" => trimmed(item["premise"]),
        "appearance" => trimmed(item["appearance"]),
        "temperament" => trimmed(item["temperament"]),
        "backstory" => trimmed(item["backstory"]),
        "facts" => group_facts(item["facts"]),
        "members" =>
          item["members"]
          |> List.wrap()
          |> Enum.filter(&is_integer/1)
          |> Enum.filter(&(&1 >= 0 and &1 < seed_count))
          |> Enum.uniq()
      }
    end
  end

  defp group_facts(list) do
    for f <- List.wrap(list),
        is_map(f),
        statement = String.trim(to_string(f["statement"] || "")),
        statement != "",
        do: %{"statement" => statement, "concealed" => truthy?(f["concealed"])}
  end

  defp trimmed(value), do: String.trim(to_string(value || ""))

  @doc """
  Propose where the next scene happens and what is at stake in it.

  **One call for both**, because they are one creative act: a location is only worth
  choosing if it puts these people somewhere something can happen, and a premise written
  without knowing where nobody is standing is a mood. Splitting them into two buttons
  would let an author keep a quay and a premise set in a counting-house.

  Grounded in the world, the cast who will actually be *in* this scene, and what has
  already happened — `opts[:so_far]` is a list of earlier scene lines, so the fifth
  scene doesn't open on the same quay as the first. `opts[:current]` deepens what is
  already typed rather than replacing it, the way ✦ Expand does everywhere else.

  Returns `{:ok, %{"location" => String.t(), "premise" => String.t()}}`.
  """
  @spec generate_scene_opening(keyword()) :: {:ok, map()} | {:error, term()}
  def generate_scene_opening(opts \\ []) do
    current = stringify(opts[:current] || %{})

    instruction =
      case {current["location"], current["premise"]} do
        {l, p} when l in [nil, ""] and p in [nil, ""] ->
          "Propose the opening: somewhere concrete in this world, and the situation " <>
            "waiting there for these people."

        {l, p} ->
          "The author has started:\n" <>
            "location: #{blank_to_dash(l)}\npremise: #{blank_to_dash(p)}\n\n" <>
            "Sharpen what is there and fill what isn't, without contradicting it."
      end

    messages = [
      %{
        role: "system",
        content:
          "You are helping an author open the next scene of a role-play campaign. Give " <>
            "it a **place** and a **situation**.\n\n" <>
            "The location is a specific spot with a time or a condition attached — \"The " <>
            "quay, after the second bell\", not \"the harbour\" — because the Director " <>
            "opens there and it grounds what everyone can see.\n\n" <>
            "The premise is what is *already true and unresolved* as the scene opens: one " <>
            "or two sentences naming the pressure on these particular people. It is not a " <>
            "summary of the campaign and it must not decide what happens — a scene that " <>
            "arrives with its ending written leaves the cast nothing to do. Do not name " <>
            "an outcome, a revelation or a resolution.\n\n" <>
            "Return ONLY a JSON object with exactly these keys: location, premise."
      },
      %{
        role: "user",
        content:
          world_block(opts[:world]) <>
            campaign_cast_block(opts[:cast] || []) <>
            so_far_block(opts[:so_far] || []) <> instruction
      }
    ]

    with {:ok, text} <-
           Polyphony.LLM.call(
             messages,
             [response: :autofill, fields: ["location", "premise"]] ++ meter_opts(opts)
           ),
         {:ok, data} <- decode_object(text) do
      {:ok,
       %{
         "location" => String.trim(to_string(Map.get(data, "location") || "")),
         "premise" => String.trim(to_string(Map.get(data, "premise") || ""))
       }}
    end
  end

  # What has already happened, so the next scene isn't the last one again.
  defp so_far_block([]), do: ""

  defp so_far_block(lines) do
    "Scenes so far, oldest first:\n" <>
      Enum.map_join(lines, "\n", &"- #{&1}") <>
      "\n\nOpen somewhere this story has not " <>
      "already been, unless returning is the point.\n\n"
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
    do: %{
      world: opts[:world],
      relations: opts[:relations],
      ensemble: opts[:ensemble],
      role: opts[:role],
      cast_seeds: opts[:cast_seeds]
    }

  defp context_block(%{} = ctx),
    do:
      role_block(ctx[:role]) <>
        world_block(ctx[:world]) <>
        relations_block(ctx[:relations]) <>
        ensemble_block(ctx[:ensemble]) <> cast_seeds_block(ctx[:cast_seeds])

  # The people **already written into this story**, as opposed to `relations` — which is
  # who a character is connected to, and says "keep them consistent with these people".
  #
  # Quick Build was passing its cast-so-far through `relations`, and the wording did the
  # damage. For a slot with a blank brief the only substantial content in the prompt was
  # another character's whole sheet under an instruction to be *consistent with* it, so
  # the model did the reasonable thing and wrote them again. Two blank slots produced two
  # of the same person.
  #
  # Both jobs are real and they pull opposite ways: continuity of *world* detail (so the
  # cast doesn't each invent a different landlord for the same building) and distinctness
  # of *person*. Saying both explicitly is the only way to get both.
  defp ensemble_block(cast) when is_list(cast) and cast != [] do
    lines =
      Enum.map_join(cast, "\n", fn c ->
        facets =
          [
            kv("premise", c["premise"]),
            kv("voice", c["voice"]),
            kv("temperament", c["temperament"])
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" | ")

        "- #{c["name"]}: #{facets}"
      end)

    "Already written into this story — this character is somebody ELSE:\n" <>
      lines <>
      "\n\nUse them for CONTINUITY: shared places, institutions, events and world " <>
      "detail should line up with what these people establish. Do NOT reuse a name, a " <>
      "role, a premise, a voice or a backstory that is already on that list — this is a " <>
      "different person with a different function in the story. If the author's brief " <>
      "above is blank, the gap in this ensemble *is* the brief: write the person this " <>
      "story still needs and does not yet have.\n\n"
  end

  defp ensemble_block(_), do: ""

  # People who are **about to be written into this world** — the character seeds a
  # Quick Build is holding while it generates the world first.
  #
  # Without them the world is written blind, and a world that needs a harbour-master
  # invents one, names her, and writes her into `starting_canon`. Then the cast
  # generation names the same person something else from the same seed, and the
  # campaign opens with two harbour-masters — or one whose own world calls her by a
  # name she has never had. Naming is the specific failure, so the instruction is
  # specific about it: the role may be needed, the person is not yours.
  defp cast_seeds_block(seeds) when is_list(seeds) do
    case Enum.filter(seeds, &(is_binary(&1) and String.trim(&1) != "")) do
      [] ->
        ""

      lines ->
        "The author is about to write these characters into this world, from these " <>
          "one-line seeds:\n" <>
          Enum.map_join(lines, "\n", &"- #{String.trim(&1)}") <>
          "\n\nThey do not exist yet and they are not yours to write. Do not name them, " <>
          "do not describe them, and write nothing that contradicts them. Where the " <>
          "setting needs their role, refer to the role and leave the person unnamed — " <>
          "the character sheets name them, and a name invented here is a name they will " <>
          "have to be renamed away from.\n\n"
    end
  end

  defp cast_seeds_block(_), do: ""

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

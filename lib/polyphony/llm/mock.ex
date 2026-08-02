defmodule Polyphony.LLM.Mock do
  @moduledoc """
  A network-free provider that emits **lorem-ipsum** structured output — the
  dev/offline default, so the whole loop (Director → serial cast → beat close)
  runs without hitting DeepInfra.

  It is a real `Provider` implementation, selected by config like any other. It
  branches on the `:response` opt the callers set (`Generation` →
  `:turn_packet`, `Director` → `:decision`) and returns schema-valid JSON:

    * `:turn_packet` — a lorem thought plus a spoken line and a self-state.
    * `:decision` — casts `:cast_hint` (the members the runner passes) and echoes
      `:control_hint` (default `:yield_to_user`, so a mock loop terminates).

  Output is deterministic — varied by hashing the messages, never by
  `Math.random`/`Date` (unavailable and replay-hostile) — so tests are stable.
  """
  @behaviour Polyphony.LLM.Provider

  @lorem ~w(lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod
            tempor incididunt ut labore et dolore magna aliqua enim ad minim veniam)

  @impl true
  def complete(messages, opts \\ []) do
    case Keyword.get(opts, :response, :turn_packet) do
      :decision -> {:ok, decision_json(opts)}
      :summary -> {:ok, summary_text(messages)}
      :arc -> {:ok, arc_json(messages)}
      :world_arc -> {:ok, world_arc_json(messages)}
      :sheet -> {:ok, sheet_json(messages)}
      :autofill -> {:ok, autofill_json(messages, opts)}
      :relationships -> {:ok, relationships_json(messages)}
      :boundaries -> {:ok, boundaries_json(messages)}
      :reciprocals -> {:ok, reciprocals_json(messages, opts)}
      :regards -> {:ok, regards_json(messages, opts)}
      :mentions -> {:ok, mentions_json(messages)}
      :field -> {:ok, summary_text(messages)}
      :gate -> {:ok, gate_answer(messages)}
      _ -> {:ok, turn_packet_json(messages)}
    end
  end

  # ── Lorem generators ─────────────────────────────────────────────────────────

  # A plain-text lorem summary (not JSON) — the summarizer takes the raw text.
  defp summary_text(messages) do
    seed = :erlang.phash2(messages)
    capitalize(lorem(seed, 10)) <> "."
  end

  # A lorem arc-extraction result: a couple of proposed discoveries.
  defp arc_json(messages) do
    seed = :erlang.phash2(messages)

    Jason.encode!(%{
      entries: [
        %{kind: "discovery", statement: capitalize(lorem(seed, 5)) <> ".", sheet_field: nil}
      ]
    })
  end

  # A lorem world-arc result: one global durable world fact.
  defp world_arc_json(messages) do
    seed = :erlang.phash2(messages)

    Jason.encode!(%{
      entries: [
        %{kind: "discovery", scope: "global", statement: capitalize(lorem(seed, 5)) <> "."}
      ]
    })
  end

  defp turn_packet_json(messages) do
    seed = :erlang.phash2(messages)

    Jason.encode!(%{
      moves: [
        %{seq: 1, type: "thought", content: capitalize(lorem(seed, 3)) <> "."},
        %{
          seq: 2,
          type: "speech",
          content: capitalize(lorem(seed + 7, 6)) <> ".",
          addressed_to: [],
          audibility: "normal"
        }
      ],
      self_state: %{
        mood_felt: lorem(seed + 1, 1),
        demeanor: lorem(seed + 2, 1),
        intention: lorem(seed + 3, 2)
      }
    })
  end

  # A full lorem character sheet (Authoring.Studio's review-gated generation).
  defp sheet_json(messages) do
    seed = :erlang.phash2(messages)

    Jason.encode!(%{
      premise: capitalize(lorem(seed, 6)) <> ".",
      appearance: capitalize(lorem(seed + 2, 5)) <> ".",
      voice: lorem(seed + 4, 3),
      temperament: lorem(seed + 6, 2),
      backstory: capitalize(lorem(seed + 8, 8)) <> "."
    })
  end

  # A lorem value for each requested authoring field (Authoring.Autofill, mode 1):
  # one JSON object keyed by the field names the caller passes in `:fields`.
  defp autofill_json(messages, opts) do
    seed = :erlang.phash2(messages)

    opts
    |> Keyword.get(:fields, [])
    |> Enum.with_index()
    |> Map.new(fn {field, i} -> {to_string(field), capitalize(lorem(seed + i * 5, 4)) <> "."} end)
    |> Jason.encode!()
  end

  # A couple of lorem relationship suggestions (Authoring.Autofill.suggest_relationships).
  defp relationships_json(messages) do
    seed = :erlang.phash2(messages)

    Jason.encode!(
      for i <- 0..2 do
        %{target: capitalize(lorem(seed + i * 4, 1)), descriptor: lorem(seed + i * 4 + 1, 2)}
      end
    )
  end

  # A couple of lorem boundaries (Authoring.suggest_boundaries): both conditional with a
  # condition (the generation contract — §A3 slow burns), one categorized.
  defp boundaries_json(messages) do
    seed = :erlang.phash2(messages)

    Jason.encode!([
      %{
        topic: lorem(seed, 2),
        condition: capitalize(lorem(seed + 1, 4)) <> ".",
        on_pressure: lorem(seed + 2, 3),
        category: ""
      },
      %{
        topic: lorem(seed + 3, 2),
        condition: capitalize(lorem(seed + 4, 4)) <> ".",
        on_pressure: "",
        category: "other"
      }
    ])
  end

  # `count` lorem reciprocal descriptors, in order (Authoring.reciprocal_roles). The
  # count is passed by the caller since the Mock can't see how many pairs there are.
  defp reciprocals_json(messages, opts) do
    seed = :erlang.phash2(messages)
    count = Keyword.get(opts, :count, 3)

    Jason.encode!(for i <- 0..(max(count, 1) - 1), do: lorem(seed + i * 3, 2))
  end

  # A lorem regard object keyed by each target's name (Authoring.regard_map). The names
  # are passed via `:targets` since the Mock builds the object from the exact keys.
  defp regards_json(messages, opts) do
    seed = :erlang.phash2(messages)

    opts
    |> Keyword.get(:targets, [])
    |> Enum.with_index()
    |> Map.new(fn {name, i} -> {to_string(name), lorem(seed + i * 3, 2)} end)
    |> Jason.encode!()
  end

  # A couple of lorem "mentioned character" names (Authoring.extract_mentions).
  defp mentions_json(messages) do
    seed = :erlang.phash2(messages)
    Jason.encode!([capitalize(lorem(seed, 1)), capitalize(lorem(seed + 3, 1))])
  end

  defp decision_json(opts) do
    cast = Keyword.get(opts, :cast_hint, []) |> Enum.map(&%{character_id: to_string(&1)})
    control = opts |> Keyword.get(:control_hint, :yield_to_user) |> to_string()
    introductions = opts |> Keyword.get(:introduce_hint, []) |> Enum.map(&introduction/1)

    Jason.encode!(%{
      control: control,
      cast: cast,
      world_events: [],
      proposal_rulings: [],
      introductions: introductions
    })
  end

  defp introduction({name, reason}), do: %{name: to_string(name), reason: to_string(reason)}
  defp introduction(name), do: %{name: to_string(name), reason: "arrives"}

  # A deterministic boundary-gate judgment (§A3): yes/no by hash, so a dev run
  # exercises both released and gated conditionals.
  defp gate_answer(messages), do: if(rem(:erlang.phash2(messages), 2) == 0, do: "yes", else: "no")

  # ── Deterministic lorem helpers ──────────────────────────────────────────────

  defp lorem(seed, count) do
    start = rem(abs(seed), length(@lorem))

    0..(count - 1)
    |> Enum.map(fn i -> Enum.at(@lorem, rem(start + i, length(@lorem))) end)
    |> Enum.join(" ")
  end

  defp capitalize(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp capitalize(other), do: other
end

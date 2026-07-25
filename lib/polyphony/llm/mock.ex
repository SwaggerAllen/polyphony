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
      :sheet -> {:ok, sheet_json(messages)}
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

  defp decision_json(opts) do
    cast = Keyword.get(opts, :cast_hint, []) |> Enum.map(&%{character_id: to_string(&1)})
    control = opts |> Keyword.get(:control_hint, :yield_to_user) |> to_string()

    Jason.encode!(%{control: control, cast: cast, world_events: [], proposal_rulings: []})
  end

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

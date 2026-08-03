defmodule Polyphony.Authoring.Cover do
  @moduledoc """
  Generates a **cover** — the outward blurb on a character or a world
  (`ux/polyphony-world.html` §Cover, `backend-backlog.md` §2.12).

  The cover is the only part strangers see before they take your world or your
  character: a short piece of written prose, not an image. It is written *from*
  everything below it, **secrets included**, under instruction to give none of them
  away.

  ## Why this doesn't live in `Autofill`'s field spec

  Every other generated field is a fold over what the author has typed into the
  form. This one is not: its input deliberately includes concealed material, and
  it can only be written once the thing it covers exists. Putting it in the
  `generate_all/4` spec would have it written from a brief, before there was
  anything to cover and before there were any secrets to keep — a blurb for a
  character who doesn't exist yet.

  ## The inversion, and the guard

  Everywhere else, the engine solves *what must not be said* structurally: a
  character is never **told** what they cannot know, so they cannot leak it
  (`Polyphony.Visibility`, default-deny). Here that is impossible by construction —
  the secrets are the input, and the constraint lives in the prompt.

  So a prompt-level obligation gets a mechanical backstop. `generate/3` checks the
  returned prose against the secrets it was given, retries once with a sharper
  instruction, and returns `{:error, :leaked}` rather than a spoiler cover if the
  second attempt leaks too. **A missing cover is a recoverable state; a published
  one that gives away the twist is not.**

  The check catches **verbatim regurgitation only** — the whole statement, or a run
  of six or more consecutive words from it. That is quotation, not coincidence, and
  it is the failure mode a model actually has when a secret is sitting in its
  context. A secret the model *paraphrases* gets through, and no string check will
  catch that; the prompt remains the real defense, and the author reads the cover
  before publishing. This is a floor, not a ceiling, and it is worth having because
  the floor is where the cheap failures land.
  """

  alias Polyphony.Authoring.{CharacterSheet, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.Fact
  alias Polyphony.LLM.Provider

  # Long enough that a shared run is a quotation rather than an idiom. Five words
  # of ordinary English recur by accident ("at the end of the"); six carrying the
  # nouns of a secret do not.
  @run_length 6

  @doc """
  Write the cover for a character sheet or world bible.

  `opts[:secrets]` adds statements that must not appear — world arc, a group's
  concealed facts, anything the caller knows is hidden that the struct itself
  doesn't carry. A character's own `concealed` facts are found automatically.

  Returns `{:ok, prose}`, `{:error, :leaked}` when two attempts both quoted a
  secret, or whatever the provider errored with.
  """
  @spec generate(CharacterSheet.t() | WorldBible.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate(subject, opts \\ []) do
    secrets = secrets_of(subject) ++ extra_secrets(opts)
    attempt(subject, secrets, opts, false)
  end

  @doc """
  The statements a subject's cover must not give away.

  For a character, the facts flagged `concealed` — the same flag that keeps them
  out of other characters' context. A world bible carries no concealment flag of
  its own yet (its hidden material is world arc, which lives in `arc_entries`), so
  callers pass those through `opts[:secrets]`.
  """
  @spec secrets_of(CharacterSheet.t() | WorldBible.t()) :: [String.t()]
  def secrets_of(%CharacterSheet{facts: facts}) do
    for %Fact{concealed: true, statement: s} <- facts || [], present?(s), do: s
  end

  def secrets_of(%WorldBible{}), do: []

  @doc """
  Does `prose` quote any of `secrets`?

  True when it contains a whole statement, or a run of #{@run_length} consecutive
  words from one. Comparison is on lowercased, punctuation-stripped words, so
  casing and a stray comma don't let a quotation through.
  """
  @spec leaks?(String.t(), [String.t()]) :: boolean()
  def leaks?(prose, secrets) do
    said = words(prose)
    said_runs = runs(said)

    Enum.any?(secrets, fn secret ->
      case words(secret) do
        [] -> false
        w when length(w) <= @run_length -> contains_run?(said, w)
        w -> Enum.any?(runs(w), &MapSet.member?(said_runs, &1))
      end
    end)
  end

  # ── Generation ───────────────────────────────────────────────────────────────

  defp attempt(subject, secrets, opts, retried?) do
    messages = messages(subject, secrets, retried?)

    with {:ok, text} <- Polyphony.LLM.call(messages, [response: :field] ++ meter_opts(opts)) do
      prose = String.trim(text)

      cond do
        not leaks?(prose, secrets) -> {:ok, prose}
        retried? -> {:error, :leaked}
        true -> attempt(subject, secrets, opts, true)
      end
    end
  end

  defp messages(subject, secrets, retried?) do
    [
      %{role: "system", content: system(subject, secrets, retried?)},
      %{role: "user", content: body(subject) <> secrets_block(secrets) <> "Write the cover now."}
    ]
  end

  defp system(subject, secrets, retried?) do
    base =
      "You are writing the **cover** for a role-play #{noun(subject)} — the short blurb a " <>
        "stranger reads before they decide to take it on. Two or three sentences of prose: " <>
        "evocative, concrete, and inviting. Return only the prose — no title, no label, no " <>
        "quotes, no JSON."

    base <> secret_rule(secrets) <> retry_rule(retried?)
  end

  defp secret_rule([]), do: ""

  defp secret_rule(_) do
    " You are being shown material that is SECRET. It is there so the cover can be true to " <>
      "what is really going on — the mood, the weight, the sense that something is under the " <>
      "surface. You must NOT give any of it away: do not state a secret, do not restate it in " <>
      "other words, and do not hint at it specifically enough that a reader could guess it. " <>
      "Promise the reader a story; do not tell them how it turns out."
  end

  defp retry_rule(false), do: ""

  defp retry_rule(true) do
    " Your previous attempt quoted the secret material directly. Write a new cover that draws " <>
      "ONLY on the public material above the secrets, and says nothing traceable to them."
  end

  defp noun(%CharacterSheet{}), do: "character"
  defp noun(%WorldBible{}), do: "world"

  defp body(%CharacterSheet{} = s) do
    lines =
      [
        kv("Name", s.name),
        kv("Pronouns", s.pronouns),
        kv("Premise", s.premise),
        kv("Appearance", s.appearance),
        kv("Voice", s.voice),
        kv("Temperament", s.temperament),
        kv("Backstory", s.backstory),
        kv("Known about them", open_facts(s))
      ]
      |> Enum.reject(&is_nil/1)

    "The character:\n" <> Enum.join(lines, "\n") <> "\n\n"
  end

  defp body(%WorldBible{} = w) do
    lines =
      [
        kv("World", w.name),
        kv("Setting", w.setting),
        kv("Tone", w.tone),
        kv("Rules", w.rules),
        kv("Starting canon", w.starting_canon)
      ]
      |> Enum.reject(&is_nil/1)

    "The world:\n" <> Enum.join(lines, "\n") <> "\n\n"
  end

  defp open_facts(%CharacterSheet{facts: facts}) do
    for %Fact{concealed: false, statement: s} <- facts || [], present?(s), do: s
  end

  defp secrets_block([]), do: ""

  defp secrets_block(secrets) do
    "SECRET — informs the mood, must not be given away:\n" <>
      Enum.map_join(secrets, "\n", &"- #{&1}") <> "\n\n"
  end

  defp kv(_label, nil), do: nil
  defp kv(_label, []), do: nil
  defp kv(label, list) when is_list(list), do: "#{label}: " <> Enum.join(list, "; ")

  defp kv(label, value) do
    case String.trim(to_string(value)) do
      "" -> nil
      v -> "#{label}: #{v}"
    end
  end

  defp extra_secrets(opts),
    do: opts |> Keyword.get(:secrets, []) |> List.wrap() |> Enum.filter(&present?/1)

  defp present?(v), do: is_binary(v) and String.trim(v) != ""

  # The same shape `Autofill` passes: provider + heavy model, usage attribution, and
  # the test `:respond_with` passthrough — so a cover meters against the same ledger
  # as every other authoring generation.
  defp meter_opts(opts) do
    [provider: Keyword.get(opts, :provider) || Provider.default(), model: model(opts)] ++
      Keyword.take(opts, [:respond_with, :user_id, :campaign_id, :usage_kind])
  end

  defp model(opts) do
    Keyword.get(opts, :model) ||
      get_in(Application.get_env(:polyphony, :llm, []), [:models, :heavy])
  end

  # ── Verbatim-run comparison ──────────────────────────────────────────────────

  defp words(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split(~r/\s+/u, trim: true)
  end

  defp runs(words) when length(words) < @run_length, do: MapSet.new()

  defp runs(words) do
    words
    |> Enum.chunk_every(@run_length, 1, :discard)
    |> MapSet.new()
  end

  # A secret shorter than a run is matched whole — it can't have a run to share.
  defp contains_run?(said, needle) do
    said
    |> Enum.chunk_every(length(needle), 1, :discard)
    |> Enum.any?(&(&1 == needle))
  end
end

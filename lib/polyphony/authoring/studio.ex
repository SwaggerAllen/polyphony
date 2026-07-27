defmodule Polyphony.Authoring.Studio do
  @moduledoc """
  The authoring surface (§15, build-order slice 9): generate a character, then
  refine it **field by field** with a review gate.

  * `generate_sheet/3` — one heavy-model call (§3) producing a full draft; each
    field is stored `:draft` with provenance.
  * `regenerate_field/3` — regenerate **one** field with a single-field
    generation (so metadata can't leak into the schema, §15), passing every other
    field as context plus that field's accumulated feedback. **Locked fields are
    never touched**, and accepted/locked fields *are* the context — so refining
    one field makes the character converge rather than drift.
  * `accept_field/3` / `lock_field/3` / `add_feedback/4` — the review gate.
  * `to_sheet/2` — fold the stored fields into a `CharacterSheet`.

  The generation prompt carries field *values* and *feedback* only; status, lock
  flags, and provenance stay in `FieldStore`, never in the schema the model sees.
  """

  require Logger

  alias Polyphony.Repo
  alias Polyphony.LLM.Provider
  alias Polyphony.Authoring.{FieldStore, DraftSchema, CharacterSheet}

  @doc "Generate a full character draft from a seed and store its fields as drafts."
  @spec generate_sheet(term(), String.t(), keyword()) ::
          {:ok, [FieldStore.t()]} | {:error, term()}
  def generate_sheet(subject_id, seed, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    provider = provider(opts)
    model = model(opts)

    messages = [
      %{
        role: "system",
        content: "Generate a character sheet from the seed. Fields: #{field_list()}."
      },
      %{role: "user", content: seed}
    ]

    with {:ok, text} <-
           Polyphony.LLM.call(
             messages,
             [provider: provider] ++ call_opts(opts, :sheet, model) ++ attribution(opts)
           ),
         {:ok, data} <- Jason.decode(text),
         {:ok, values} <- DraftSchema.parse(data) do
      hash = prompt_hash(messages)

      for {field, value} <- values do
        FieldStore.put(repo, subject_id, field, value, model: model, prompt_hash: hash)
      end

      {:ok, FieldStore.list(repo, subject_id)}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_draft}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @doc """
  Regenerate one field. Refuses if the field is `:locked`. The other fields
  (including accepted/locked ones) and this field's feedback are the context.
  """
  @spec regenerate_field(term(), term(), keyword()) :: {:ok, FieldStore.t()} | {:error, term()}
  def regenerate_field(subject_id, field, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    field = to_string(field)
    rows = FieldStore.list(repo, subject_id)
    current = Enum.find(rows, &(&1.field == field))

    if current && current.status == "locked" do
      {:error, :locked}
    else
      do_regenerate(subject_id, field, rows, current, opts)
    end
  end

  defp do_regenerate(subject_id, field, rows, current, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    provider = provider(opts)
    model = model(opts)
    others = Enum.reject(rows, &(&1.field == field))
    feedback = (current && current.feedback) || []
    messages = regen_messages(field, others, feedback)

    with {:ok, value} <-
           Polyphony.LLM.call(
             messages,
             [provider: provider] ++ call_opts(opts, :field, model) ++ attribution(opts)
           ) do
      row =
        FieldStore.put(repo, subject_id, field, String.trim(value),
          model: model,
          prompt_hash: prompt_hash(messages),
          feedback: feedback
        )

      {:ok, row}
    end
  end

  @doc "Accept a field (review gate: draft → accepted)."
  def accept_field(subject_id, field, opts \\ []),
    do: FieldStore.set_status(Keyword.get(opts, :repo, Repo), subject_id, field, "accepted")

  @doc "Lock a field so regeneration never touches it."
  def lock_field(subject_id, field, opts \\ []),
    do: FieldStore.set_status(Keyword.get(opts, :repo, Repo), subject_id, field, "locked")

  @doc "Attach feedback to a field for its next regeneration."
  def add_feedback(subject_id, field, text, opts \\ []),
    do: FieldStore.add_feedback(Keyword.get(opts, :repo, Repo), subject_id, field, text)

  @doc "Fold the stored fields into a `CharacterSheet` (with the given name)."
  def to_sheet(subject_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    fields =
      repo
      |> FieldStore.list(subject_id)
      |> Map.new(&{String.to_existing_atom(&1.field), &1.value})

    struct(%CharacterSheet{name: Keyword.get(opts, :name)}, fields)
  end

  # ── Prompt building ──────────────────────────────────────────────────────────

  # Only field VALUES and FEEDBACK go into the prompt — never status/lock/hash.
  defp regen_messages(field, others, feedback) do
    context =
      others
      |> Enum.map(fn r -> "#{r.field}: #{r.value}" end)
      |> Enum.join("\n")

    feedback_block =
      case feedback do
        [] -> ""
        list -> "\n\nFeedback to address:\n" <> Enum.map_join(list, "\n", &"- #{&1}")
      end

    [
      %{
        role: "system",
        content:
          "Refine one field of a character. Regenerate ONLY the '#{field}'. Keep it " <>
            "consistent with the rest of the character; do not restate other fields."
      },
      %{
        role: "user",
        content: "Character so far:\n#{context}#{feedback_block}\n\nWrite the #{field}:"
      }
    ]
  end

  defp field_list, do: DraftSchema.fields() |> Enum.map_join(", ", &to_string/1)

  # Provider call opts: the response-shape hint + model, plus any test passthrough.
  defp call_opts(opts, response, model) do
    [response: response, model: model] ++ Keyword.take(opts, [:respond_with])
  end

  defp provider(opts), do: Keyword.get(opts, :provider) || Provider.default()

  # Usage attribution forwarded to the metered LLM call (Polyphony.LLM).
  defp attribution(opts), do: Keyword.take(opts, [:user_id, :campaign_id, :usage_kind])

  defp model(opts) do
    Keyword.get(opts, :model) ||
      get_in(Application.get_env(:polyphony, :llm, []), [:models, :heavy])
  end

  defp prompt_hash(messages) do
    :crypto.hash(:sha256, :erlang.term_to_binary(messages)) |> Base.encode16(case: :lower)
  end
end

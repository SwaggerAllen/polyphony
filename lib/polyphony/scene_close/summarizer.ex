defmodule Polyphony.SceneClose.Summarizer do
  @moduledoc """
  Scene summarization (§8 fix #1): at scene close, generate **N+1 summaries** —
  one omniscient (the user's table of contents) and one per participant, each
  built from *that viewer's filtered event stream*.

  This is the fix for the summary leak: an omniscient summary handed to a
  character would return, in prose, every whisper and offscreen move the
  visibility projection carefully withheld. Because the per-character summary is
  generated only from `Visibility.project(events, viewer)`, it *structurally
  cannot* contain what the character never witnessed.
  """

  alias Polyphony.LLM.Provider
  alias PolyphonyCore.{Visibility, EventText}

  @doc "Summarize `events` from `viewer`'s filtered perspective. Returns `{:ok, text}`."
  @spec summarize(Enumerable.t(), Visibility.viewer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def summarize(events, viewer, opts \\ []) do
    provider = Keyword.get(opts, :provider) || Provider.default()
    filtered = Visibility.project(events, viewer)

    messages = [
      %{role: "system", content: system_prompt(viewer)},
      %{role: "user", content: EventText.render(filtered)}
    ]

    call_opts = Keyword.merge(Keyword.take(opts, [:respond_with, :model]), response: :summary)

    Polyphony.LLM.call(
      messages,
      [provider: provider] ++
        call_opts ++ Keyword.take(opts, [:user_id, :campaign_id, :usage_kind])
    )
  end

  defp system_prompt(:omniscient),
    do: "Summarize this scene concisely for a table of contents. You see everything."

  defp system_prompt({:character, id}),
    do:
      "Summarize this scene as #{id} would remember it — only what #{id} witnessed. " <>
        "Do not include anything #{id} could not have known."
end

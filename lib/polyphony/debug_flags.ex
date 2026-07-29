defmodule Polyphony.DebugFlags do
  @moduledoc """
  Runtime debug toggles — bring-up aids flipped from the debug drawer and **broadcast**
  so any open LiveView (the drawer isn't the only one that cares) reacts immediately.

  Values live in the application env so plain, non-LiveView code can read them directly
  (`Polyphony.LLM.call` reads `:force_heavy_model` at call time). `set/2`/`toggle/1`
  additionally fan the change out over PubSub; a LiveView subscribes with `subscribe/0`
  and handles `{:debug_flag, flag, value}`.

  Flags:

    * `:force_heavy` — route every chat generation to the heavy model (§9).
    * `:events` — swap the play view's scene pane to the raw event/beat-boundary stream.
    * `:trace` — capture the actual LLM requests/responses (`Polyphony.DebugTap`) and
      show them in the play view's debug pane.

  Debug-only; keep the drawer off in public prod (see `Polyphony.DebugLog`).
  """
  @topic "debug:flags"
  @flags %{force_heavy: :force_heavy_model, events: :debug_events, trace: :debug_trace}

  @doc "Current value of a flag (defaults to false)."
  def get(flag), do: Application.get_env(:polyphony, key!(flag), false)

  @doc "Flip a flag and broadcast the change."
  def toggle(flag), do: set(flag, not get(flag))

  @doc "Set a flag and broadcast the change."
  def set(flag, value) do
    Application.put_env(:polyphony, key!(flag), value)
    Phoenix.PubSub.broadcast(Polyphony.PubSub, @topic, {:debug_flag, flag, value})
    value
  end

  @doc "Subscribe the calling process to flag changes."
  def subscribe, do: Phoenix.PubSub.subscribe(Polyphony.PubSub, @topic)

  defp key!(flag), do: Map.fetch!(@flags, flag)
end

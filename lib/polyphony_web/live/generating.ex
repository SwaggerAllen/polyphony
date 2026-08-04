defmodule PolyphonyWeb.Generating do
  @moduledoc """
  The editor side of `Polyphony.Generations`: ask for a generation, get it back.

  Replaces `start_async` at every ✦ control. The screen's job is unchanged — it still
  decides what a result *means*, which is the part worth keeping in one place (a
  suggestion appends, a whole-form generation fills only the blanks, a leaked cover is
  refused). What changes is that the work no longer belongs to the socket, so leaving
  the page for a minute stops throwing the answer away.

  ## Using it

  Assign `:gen_subject` (the library entry the generations belong to) and `:generating`
  (the `MapSet` of in-flight keys) at mount, then:

      socket |> Generating.restore() |> ...        # in mount, once connected

      Generating.request(socket, "cover", "cover", %{subject: bible, opts: opts})

      def handle_info({:generation, key, result}, socket), do: ...

  `restore/1` does two things a reconnect needs: it puts back the spinners for whatever
  is still running, and it re-delivers anything that finished while nobody was
  listening, as ordinary `{:generation, key, result}` messages — so the screen has one
  code path whether it was watching or not.

  Keys are strings rather than tuples, because a key is a database column now. Where a
  control is per-field the convention is `"control:field"`, which pattern-matches as a
  binary just as neatly (`"gen_field:" <> field`).
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  alias Polyphony.Generations

  @doc """
  Mark the control busy and enqueue the work.

  The mark is local; the truth is the run row, which is what `restore/1` reads. Both
  exist because the spinner has to appear on this render, before any round-trip.
  """
  def request(socket, key, op, request) do
    key = to_string(key)
    Generations.request(socket.assigns.gen_subject, key, op, request)
    mark(socket, key, true)
  end

  @doc """
  Restore what a reconnect can't see: the spinners still turning, and the answers that
  arrived while the page was closed.
  """
  def restore(socket) do
    if connected?(socket) do
      subject = socket.assigns.gen_subject
      Generations.subscribe(subject)

      # Delivered as messages rather than applied here, so the screen's own handler is
      # the only thing that knows how to fold a result in — whether it arrived live or
      # an hour late.
      for {key, result} <- Generations.take(subject),
          do: send(self(), {:generation, key, result})

      assign(socket, :generating, MapSet.new(Generations.running(subject)))
    else
      socket
    end
  end

  @doc "Is this control generating?"
  def generating?(generating, key), do: MapSet.member?(generating, to_string(key))

  @doc """
  Set or clear a control's spinner.

  Clearing also **forgets the run**, and that is load-bearing rather than tidiness: a
  result delivered live would otherwise stay parked, and `restore/1` would hand it back
  on the next mount and apply it a second time. Whoever applies a result is the one who
  consumes it, and every result path ends by turning its spinner off.
  """
  def mark(socket, key, true),
    do: assign(socket, :generating, MapSet.put(socket.assigns.generating, to_string(key)))

  def mark(socket, key, false) do
    Generations.forget(socket.assigns.gen_subject, to_string(key))
    assign(socket, :generating, MapSet.delete(socket.assigns.generating, to_string(key)))
  end
end

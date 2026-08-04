defmodule PolyphonyWeb.Autosave do
  @moduledoc """
  Saving on your behalf, so there is nothing to lose.

  ## Why

  The long-form editors kept an author's edits in the socket and wrote them only when
  Save was pressed. That is fine on a desktop and wrong everywhere else: a phone
  backgrounds the tab, the WebSocket closes, the LiveView process ends, and the next
  visit re-mounts from the database with every unwritten paragraph gone. Nothing was
  broken — the work was simply never anywhere it could survive.

  The tempting fix is to persist the *buffer* somewhere (a local store, a drafts table)
  and restore it on mount. That keeps the unsaved-work concept alive and adds a second
  copy of every sheet that can disagree with the first. These are the author's own
  private entries and `Library.update_payload/2` versions each write, so the simpler
  answer is available: **stop having unsaved work.** Every mutation already routes
  through `touch/1` to flip the dirty flag; that same call now schedules the write.

  ## Shape

  Debounced, not per-keystroke: a burst of edits coalesces into one write a beat after
  typing stops, so a paragraph is one version rather than forty. The explicit Save
  button stays — it flushes immediately, it is where a validation gate belongs (a
  world's name clash), and a control that says the work is safe is worth having even
  when it is always already true.

  `flush/1` on `terminate/2` closes the last gap: the tab going away is exactly the
  case this exists for, and the pending timer would die with the process.

  ## Using it

      def handle_event("sync", params, socket),
        do: {:noreply, socket |> assign_form(params) |> Autosave.touch()}

      def handle_info(:autosave, socket), do: {:noreply, Autosave.saved(persist(socket))}
      def terminate(_reason, socket), do: Autosave.flush(socket, &persist/1)

  `persist/1` must be free of side effects beyond writing the entry — no stub creation,
  no generation, no promotion. Those belong to a deliberate Save, because an autosave
  fires while the author is still mid-thought.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1]

  # Long enough that a sentence is one write, short enough that leaving the page a
  # moment after typing still keeps it. Inputs carry `phx-debounce="600"`, so the true
  # worst case is about two seconds of exposure — against, previously, all of it.
  @quiet_ms 1_200

  @doc "Mark the socket dirty and schedule a save once the author pauses."
  def touch(socket), do: socket |> assign(saved: false, dirty: true) |> schedule()

  @doc """
  (Re)start the quiet timer, cancelling any pending one.

  Only on a connected socket: the first, static render has no process to deliver to.
  """
  def schedule(socket) do
    if connected?(socket) do
      cancel_timer(socket)
      assign(socket, autosave_ref: Process.send_after(self(), :autosave, @quiet_ms))
    else
      socket
    end
  end

  @doc "Record a completed write: clean, and with no timer outstanding."
  def saved(socket) do
    cancel_timer(socket)
    assign(socket, saved: true, dirty: false, autosave_ref: nil)
  end

  @doc """
  Drop any pending save — for an explicit Save, which is about to write anyway, and
  for a refusal, which must not be undone a second later by the timer it raced.
  """
  def cancel(socket) do
    cancel_timer(socket)
    assign(socket, autosave_ref: nil)
  end

  @doc """
  Write now if there is anything outstanding. Safe to call from `terminate/2`, where
  a raise would be noise and the socket may be half torn down.
  """
  def flush(socket, persist) when is_function(persist, 1) do
    if socket.assigns[:dirty], do: persist.(socket)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp cancel_timer(socket) do
    case socket.assigns[:autosave_ref] do
      nil -> :ok
      ref -> Process.cancel_timer(ref)
    end

    :ok
  end
end

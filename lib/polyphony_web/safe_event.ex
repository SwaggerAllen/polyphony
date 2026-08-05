defmodule PolyphonyWeb.SafeEvent do
  @moduledoc """
  Turn a raised/thrown error inside a LiveView event into a **visible flash + a log
  line**, instead of a silent process crash that looks to the user like the button
  did nothing.

  Wrap an event body:

      def handle_event("register", params, socket) do
        safe(socket, fn ->
          ... # returns {:noreply, socket} | {:reply, map, socket} | {:noreply, redirect(...)}
        end)
      end

  On success the body's return value is passed through unchanged. On failure the
  full error — stacktrace included — goes to the log, and the user gets a flash: the
  exception's **banner line** when `:show_error_details` is on (bring-up), a generic
  "check the logs" message otherwise.

  The banner rather than `Exception.format/3`, which was the whole formatted error
  including the stacktrace. A toast is a sentence with a dot on it (the kit's own
  rule: *name the action that produced it*); handed forty lines it becomes a
  fixed-position wall taller than the viewport, sitting over the screen it is
  reporting on. The stack was never lost — `Logger.error` below has always had it, and
  the debug drawer is where you read it from a phone.
  """
  require Logger
  import Phoenix.LiveView, only: [put_flash: 3]

  @spec safe(Phoenix.LiveView.Socket.t(), (-> term())) :: term()
  def safe(socket, fun) when is_function(fun, 0) do
    fun.()
  rescue
    e -> flash_error(socket, :error, e, __STACKTRACE__)
  catch
    kind, reason -> flash_error(socket, kind, reason, __STACKTRACE__)
  end

  defp flash_error(socket, kind, reason, stack) do
    Logger.error("LiveView event failed:\n" <> Exception.format(kind, reason, stack))
    {:noreply, put_flash(socket, :error, message(kind, reason, stack))}
  end

  defp message(kind, reason, _stack) do
    if Application.get_env(:polyphony, :show_error_details, false) do
      "Error: " <> truncate(Exception.format_banner(kind, reason))
    else
      "Something went wrong — the error was logged. Try again, or contact support."
    end
  end

  # A banner can still run long — a protocol error names every type implementing it.
  # The point of showing it at all is recognising *which* error, and that is the front.
  @limit 300
  defp truncate(text) do
    text = text |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(text) > @limit, do: String.slice(text, 0, @limit) <> "…", else: text
  end
end

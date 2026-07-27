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
  full error is logged, and the user gets a flash — the full exception when
  `:show_error_details` is on (bring-up), a generic "check the logs" message
  otherwise.
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

  defp message(kind, reason, stack) do
    if Application.get_env(:polyphony, :show_error_details, false) do
      "Error: " <> Exception.format(kind, reason, stack)
    else
      "Something went wrong — the error was logged. Try again, or contact support."
    end
  end
end

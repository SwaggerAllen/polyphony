defmodule PolyphonyWeb.SafeEventTest do
  @moduledoc """
  What a caught event failure puts on the screen.

  It used to be `Exception.format/3` — the whole error *including the stacktrace* —
  poured into a toast. A toast is a sentence with a dot on it (the kit: *name the action
  that produced it*); handed forty lines it becomes a fixed-position wall taller than the
  viewport, over the screen it is reporting on. Nothing was lost by trimming it: the log
  line below has always carried the full thing, and the debug drawer is how you read that
  from a phone.
  """
  use ExUnit.Case, async: false

  import PolyphonyWeb.SafeEvent

  defp with_details(value, fun) do
    previous = Application.get_env(:polyphony, :show_error_details, false)
    Application.put_env(:polyphony, :show_error_details, value)

    try do
      fun.()
    after
      Application.put_env(:polyphony, :show_error_details, previous)
    end
  end

  defp socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

  defp flash_message(sock) do
    {:noreply, out} = safe(sock, fn -> raise ArgumentError, String.duplicate("boom ", 200) end)
    Phoenix.Flash.get(out.assigns.flash, :error)
  end

  test "a raise becomes a flash rather than a crash" do
    with_details(false, fn ->
      assert flash_message(socket()) =~ "Something went wrong"
    end)
  end

  test "with details on, it names the error and stops there" do
    with_details(true, fn ->
      msg = flash_message(socket())

      # Recognising *which* error is the whole point of the flag; the trace is the log's.
      assert msg =~ "ArgumentError"
      refute msg =~ "safe_event.ex"
      refute msg =~ "(elixir"
    end)
  end

  test "and it is bounded, because a banner can still run long" do
    with_details(true, fn ->
      msg = flash_message(socket())

      # A protocol error names every type implementing the protocol — that banner alone
      # was most of the wall. Truncated at the front, which is the part that identifies it.
      assert String.length(msg) < 400
      assert String.ends_with?(msg, "…")
      # Collapsed to one line: a toast lays out as a sentence, not as a document.
      refute msg =~ "\n"
    end)
  end
end

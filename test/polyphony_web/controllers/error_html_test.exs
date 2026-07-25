defmodule PolyphonyWeb.ErrorHTMLTest do
  @moduledoc """
  The error page surfaces the real exception + stacktrace on 5xx when
  `:show_error_details` is on, and stays terse (status only) when it's off — the
  operator-visibility knob behind `SHOW_ERROR_DETAILS`.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  defp render(template, assigns) do
    PolyphonyWeb.ErrorHTML.render(template, assigns) |> rendered_to_string()
  end

  defp with_details(bool, fun) do
    prev = Application.get_env(:polyphony, :show_error_details)
    Application.put_env(:polyphony, :show_error_details, bool)

    try do
      fun.()
    after
      Application.put_env(:polyphony, :show_error_details, prev)
    end
  end

  test "500 with details on shows the exception type, message, and stacktrace" do
    with_details(true, fn ->
      html =
        render("500.html", %{
          kind: :error,
          reason: %RuntimeError{message: "kaboom in the beat loop"},
          stack: [{Foo, :bar, 1, [file: ~c"lib/foo.ex", line: 42]}]
        })

      assert html =~ "500"
      assert html =~ "kaboom in the beat loop"
      assert html =~ "RuntimeError"
      assert html =~ "lib/foo.ex"
    end)
  end

  test "500 with details off hides the exception, keeps the status" do
    with_details(false, fn ->
      html =
        render("500.html", %{
          kind: :error,
          reason: %RuntimeError{message: "kaboom in the beat loop"},
          stack: []
        })

      assert html =~ "Internal Server Error"
      refute html =~ "kaboom in the beat loop"
      refute html =~ "RuntimeError"
    end)
  end

  test "404 shows the friendly status, never a stacktrace" do
    with_details(true, fn ->
      html = render("404.html", %{kind: :error, reason: :not_found, stack: []})
      assert html =~ "Not Found"
      refute html =~ "stacktrace"
    end)
  end
end

defmodule PolyphonyWeb.ErrorHTMLTest do
  @moduledoc """
  The error page surfaces the real exception + stacktrace on 5xx when
  `:show_error_details` is on, and stays terse when it's off — the operator-visibility
  knob behind `SHOW_ERROR_DETAILS`. Copy per state is `docs/behaviors/error.md`: a 404
  assigns no blame, a 500 admits fault, and a 403 is the one status allowed to read
  the session — signed out it offers the door, signed in it says whose door it is.
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

  defp conn_signed(user), do: %Plug.Conn{assigns: %{current_user: user}}

  test "500 with details on shows the exception type, message, and stacktrace" do
    with_details(true, fn ->
      html =
        render("500.html", %{
          kind: :error,
          reason: %RuntimeError{message: "kaboom in the beat loop"},
          stack: [{Foo, :bar, 1, [file: ~c"lib/foo.ex", line: 42]}]
        })

      assert html =~ "500"
      assert html =~ "That one&#39;s on us"
      assert html =~ "kaboom in the beat loop"
      assert html =~ "RuntimeError"
      assert html =~ "lib/foo.ex"
    end)
  end

  test "500 with details off hides the exception, admits fault, points at the id" do
    with_details(false, fn ->
      html =
        render("500.html", %{
          kind: :error,
          reason: %RuntimeError{message: "kaboom in the beat loop"},
          stack: []
        })

      assert html =~ "That one&#39;s on us"
      assert html =~ "Quote the id above"
      refute html =~ "kaboom in the beat loop"
      refute html =~ "RuntimeError"
    end)
  end

  test "404 says what happened, assigns no blame, never a stacktrace" do
    with_details(true, fn ->
      html = render("404.html", %{kind: :error, reason: :not_found, stack: []})
      assert html =~ "Nothing here"
      assert html =~ "doesn&#39;t lead anywhere"
      refute html =~ "went wrong"
      refute html =~ "stacktrace"
    end)
  end

  test "403 signed in says whose it is and offers no sign-in" do
    html =
      render("403.html", %{
        kind: :error,
        reason: :forbidden,
        stack: [],
        conn: conn_signed(%{id: 1})
      })

    assert html =~ "This isn&#39;t yours"
    refute html =~ "/login"
  end

  test "403 signed out offers the door without promising it opens" do
    html =
      render("403.html", %{
        kind: :error,
        reason: :forbidden,
        stack: [],
        conn: conn_signed(nil)
      })

    assert html =~ "This one&#39;s private"
    assert html =~ "/login"
    refute html =~ "you&#39;ll have access"
  end

  test "a conn that never reached auth reads as signed out" do
    html = render("403.html", %{kind: :error, reason: :forbidden, stack: []})
    assert html =~ "This one&#39;s private"
  end
end

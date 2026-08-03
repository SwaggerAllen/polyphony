defmodule PolyphonyWeb.SecurityHeadersTest do
  @moduledoc """
  The browser pipeline's security headers, pinned.

  This app renders **other people's prose** — a published story is authored by a
  stranger and read by anyone — so the CSP is doing real work, and the directive that
  does most of it is `script-src 'self'`: no `unsafe-inline`, no nonce, because nothing
  in the layout is an inline script. A future inline `<script>` would silently not run
  rather than quietly widening the policy, and this test is what says so.

  The real-browser check that the policy doesn't *break* the app (LiveView's socket,
  the font stylesheet, the kit's inline `style=` attributes) is the Wallaby feature
  test — a policy that forbids the WebSocket passes every in-process test here and
  fails the moment a browser loads it.
  """
  use PolyphonyWeb.ConnCase, async: true

  defp csp(conn) do
    conn
    |> get(~p"/")
    |> get_resp_header("content-security-policy")
    |> List.first()
  end

  test "a CSP is set on browser responses", %{conn: conn} do
    assert csp(conn) =~ "default-src 'self'"
  end

  test "scripts are same-origin only — the directive the policy exists for", %{conn: conn} do
    policy = csp(conn)

    assert policy =~ "script-src 'self'"
    # Narrow assertion: `style-src` legitimately carries 'unsafe-inline', so asserting
    # the policy nowhere contains that string would fail for the wrong reason.
    refute policy =~ ~r/script-src[^;]*unsafe-inline/
    refute policy =~ ~r/script-src[^;]*unsafe-eval/
  end

  test "the app's own needs are allowed, and nothing wider", %{conn: conn} do
    policy = csp(conn)

    # The kit computes per-character token colours into inline `style=` attributes.
    assert policy =~ ~r/style-src[^;]*'unsafe-inline'/
    # LiveView's socket. `'self'` alone is not read as covering ws:// everywhere.
    assert policy =~ ~r/connect-src[^;]*ws:/
    assert policy =~ "frame-ancestors 'none'"
    assert policy =~ "object-src 'none'"
  end

  # Passing a map to `put_secure_browser_headers/2` replaces only the CSP it would
  # otherwise set (a much laxer `frame-ancestors 'self'`), so the rest must survive.
  # Phoenix 1.8 no longer sends `x-frame-options` — `frame-ancestors`, asserted above,
  # is what replaced it.
  test "the usual headers are still set alongside it", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "x-permitted-cross-domain-policies") == ["none"]
    assert get_resp_header(conn, "referrer-policy") == ["strict-origin-when-cross-origin"]
  end
end

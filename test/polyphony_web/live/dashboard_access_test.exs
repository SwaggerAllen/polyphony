defmodule PolyphonyWeb.DashboardAccessTest do
  @moduledoc """
  Who can reach LiveDashboard, and whether it can actually run once there.

  This is the largest exposure the app serves: it lists processes, reads ETS, and
  shows the environment. Every other admin surface leaks a decision; this one leaks
  runtime state. So access is gated on the **role**, in every environment — a build
  flag protects a dev machine, `require_admin` protects the deployment.

  The second half is less obvious and would otherwise be found by hand: the page ships
  inline `<script>`, which the app's own `script-src 'self'` refuses. It would render
  and then do nothing at all, with the reason only visible in a browser console.
  """
  use PolyphonyWeb.ConnCase, async: false

  describe "who gets in" do
    test "a signed-out visitor is turned away", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin/dashboard")
      refute to =~ "dashboard"
    end

    test "an ordinary signed-in user is turned away too" do
      %{conn: conn} = register_and_log_in_user(%{conn: Phoenix.ConnTest.build_conn()})

      # The interesting case: being logged in is not the bar. Process lists and ETS
      # are not "signed-in" information.
      assert {:error, {:redirect, _}} = live(conn, ~p"/admin/dashboard")
    end

    test "an admin gets the dashboard" do
      # The dashboard live_redirects to its own home page. That redirect is itself the
      # proof of admission: a rejected visitor is redirected *away*, to sign-in.
      assert {:error, {:live_redirect, %{to: "/admin/dashboard/home"}}} =
               live(admin_conn(), ~p"/admin/dashboard")

      {:ok, _view, html} = live(admin_conn(), ~p"/admin/dashboard/home")

      assert html =~ "Metrics"
    end
  end

  describe "the content security policy" do
    test "the dashboard route names a nonce, so its inline script can run" do
      conn = get(admin_conn(), ~p"/admin/dashboard")
      [csp] = get_resp_header(conn, "content-security-policy")

      # Without this the page loads and silently does nothing.
      assert csp =~ ~r/script-src[^;]*'nonce-/
      # And the nonce is an addition, not a licence: no blanket inline scripts.
      refute csp =~ ~r/script-src[^;]*'unsafe-inline'/
    end

    test "a fresh nonce per request" do
      conn = admin_conn()

      first = nonce_of(get(conn, ~p"/admin/dashboard"))
      second = nonce_of(get(conn, ~p"/admin/dashboard"))

      # A reused nonce is a constant, and a constant nonce is `unsafe-inline` wearing
      # a hat.
      assert first != second
    end

    test "the rest of the app keeps the stricter policy", %{conn: conn} do
      [csp] = conn |> get(~p"/") |> get_resp_header("content-security-policy")

      refute csp =~ "nonce-"
      assert csp =~ "script-src 'self'"
    end
  end

  describe "the metrics it renders" do
    test "every metric names an event something actually emits" do
      # A permanently empty chart reads as "nothing is happening" rather than "nothing
      # is measured", which is worse than no chart. Each prefix here is something that
      # demonstrably publishes: the first three out of the box, `polyphony.llm` from
      # the span in `LLM.call/2` (pinned by Polyphony.LLMTelemetryTest).
      emitters = ~w(oban polyphony.repo phoenix vm polyphony.llm)

      for metric <- PolyphonyWeb.Telemetry.metrics() do
        name = Enum.map_join(metric.name, ".", &to_string/1)

        assert Enum.any?(emitters, &String.starts_with?(name, &1)),
               "#{name} has no emitter — it would render as an empty chart"
      end
    end

    test "there are enough of them to be worth a tab" do
      assert length(PolyphonyWeb.Telemetry.metrics()) > 8
    end
  end

  defp nonce_of(conn) do
    [csp] = get_resp_header(conn, "content-security-policy")
    [_, nonce] = Regex.run(~r/script-src[^;]*'nonce-([^']+)'/, csp)
    nonce
  end

  # `register_and_log_in_user/1` hands back the user separately: the conn's assigns
  # are only populated once a request runs through the plug.
  defp admin_conn do
    %{conn: conn, user: user} =
      register_and_log_in_user(%{conn: Phoenix.ConnTest.build_conn()})

    user |> Ecto.Changeset.change(role: "admin") |> Polyphony.Repo.update!()
    conn
  end
end

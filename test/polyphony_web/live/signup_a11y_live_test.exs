defmodule PolyphonyWeb.SignupA11yLiveTest do
  @moduledoc """
  The two controls that decide whether an account can exist, and the rule for the one
  field that can be wrong in a way you can't guess.

  **The boxes were not checkboxes.** They were `<span class="chk">` with a `phx-click`:
  no `role`, no accessible name, not in the tab order, and dependent on a live socket to
  change at all. Somebody on a keyboard could fill the whole form and never reach the
  attestation; a screen reader was read the words beside a thing it had nothing to say
  about. Of every control in the app to draw as a picture of itself, these two are the
  worst pair — one of them is a legal attestation and the other is consent.

  **The username rule was only ever stated by the failure**, and the failure said
  *Taken. Try something else.* for every username error — including the format and
  length ones, which are not about somebody else having it. So the one time you were
  told anything, you were told the wrong thing about a name that was fine.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.Accounts
  alias Polyphony.Accounts.User

  defp signup(conn), do: live(conn, ~p"/signup")

  describe "the consent boxes" do
    test "are real checkboxes, named, and inside the form", %{conn: conn} do
      {:ok, _view, html} = signup(conn)

      for {name, label} <- [
            {"attest", "I&#39;m 18 or over"},
            {"consent", "I&#39;ve read the terms and the privacy notice"}
          ] do
        assert html =~ ~s(type="checkbox" name="#{name}")
        assert html =~ ~s(aria-label="#{label}")
      end

      # And nothing is left pretending to be one.
      refute html =~ ~s(phx-click="toggle")
    end

    test "they carry their own state on submit, with no round trip to set it",
         %{conn: conn} do
      # The whole point of a real input: a browser with no live socket still posts both
      # boxes, and the account gets made. The old span could not be checked at all
      # without the server answering first.
      Accounts.count()
      {:ok, view, _html} = signup(conn)

      result =
        view
        |> form("form[phx-submit=register]", %{
          email: "boss@x.io",
          username: "bossuser",
          attest: "true",
          consent: "true"
        })
        |> render_submit()

      assert {:error, {:redirect, %{to: "/auth/verify/" <> _}}} = result
      assert Accounts.get_by_username("bossuser")
    end

    test "an unchecked box is an absent field, which is what a browser posts",
         %{conn: conn} do
      user_fixture()
      {:ok, view, _html} = signup(conn)

      html =
        view
        |> form("form[phx-submit=register]", %{
          email: "x@x.io",
          username: "xuser",
          consent: "true"
        })
        |> render_submit()

      # Unchecked attestation still ends the signup rather than limiting it.
      assert html =~ "Polyphony is for adults"
    end

    test "a rejected submit comes back with the boxes as they were left",
         %{conn: conn} do
      user_fixture()
      {:ok, view, _html} = signup(conn)

      html =
        view
        |> form("form[phx-submit=register]", %{
          email: "x@x.io",
          username: "xuser",
          attest: "true",
          consent: "true",
          invite_token: "nope"
        })
        |> render_submit()

      # Re-ticking two boxes to correct an invite code is the kind of thing that makes
      # a form feel like it is fighting you.
      assert html =~ "Invites work once"
      assert length(Regex.scan(~r/type="checkbox"[^>]*checked/, html)) == 2
    end
  end

  describe "the username rule" do
    test "is on the page before anything has gone wrong", %{conn: conn} do
      {:ok, _view, html} = signup(conn)

      assert html =~ User.username_rule()
      assert html =~ ~s(id="username-rule")
      assert html =~ ~s(aria-describedby="username-rule")
      # And the browser is told it too, so a bad name never needs a round trip.
      assert html =~ ~s(pattern="#{User.username_pattern()}")
    end

    test "and settings says the same sentence, from the same place", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ User.username_rule()
      assert html =~ ~s(pattern="#{User.username_pattern()}")
    end

    test "a name that breaks the rule is told the rule, not that it is taken",
         %{conn: conn} do
      user_fixture()
      _ = Polyphony.Accounts.Roles.roles()
      admin = user_fixture(%{role: "superadmin"})
      {:ok, invite} = Accounts.create_invite(admin)

      {:ok, view, _html} = signup(conn)

      html =
        view
        |> form("form[phx-submit=register]", %{
          email: "x@x.io",
          username: "no spaces please",
          attest: "true",
          consent: "true",
          invite_token: invite.token
        })
        |> render_submit()

      assert html =~ User.username_rule()
      refute html =~ "Taken. Try something else."
    end

    test "and a name somebody has is still told it is taken", %{conn: conn} do
      user_fixture()
      _ = Polyphony.Accounts.Roles.roles()
      admin = user_fixture(%{role: "superadmin", username: "theboss"})
      {:ok, invite} = Accounts.create_invite(admin)

      {:ok, view, _html} = signup(conn)

      html =
        view
        |> form("form[phx-submit=register]", %{
          email: "new@x.io",
          username: "theboss",
          attest: "true",
          consent: "true",
          invite_token: invite.token
        })
        |> render_submit()

      assert html =~ "Taken. Try something else."
    end

    test "the sentence and the validation cannot drift apart" do
      # The rule is one statement — the changeset, the `pattern`, and both forms read it
      # from `User`. This is what stops the copy being right about a rule the code no
      # longer enforces.
      {min, max} = User.username_length()

      assert User.username_rule() =~ to_string(min)
      assert User.username_rule() =~ to_string(max)

      short = String.duplicate("a", min - 1)
      ok = String.duplicate("a", min)

      assert {:username, _} =
               List.keyfind(
                 User.registration_changeset(%{username: short, email: "a@b.io"}).errors,
                 :username,
                 0
               )

      refute List.keyfind(
               User.registration_changeset(%{username: ok, email: "a@b.io"}).errors,
               :username,
               0
             )
    end
  end
end

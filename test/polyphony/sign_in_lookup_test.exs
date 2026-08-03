defmodule Polyphony.SignInLookupTest do
  @moduledoc """
  Finding the account a sign-in link is meant for.

  Sign-in is magic-link only and the login screen says the same thing whether or not
  an address matched — a deliberate refusal to be an enumeration oracle. The cost is
  that a failed lookup is *completely* silent: no email, no error, no log. So the two
  things that make it fail have to be pinned here.

  The first is normalisation. `get_by_email/2` lower-cased but did not trim, while the
  login screen trimmed the address it *displayed* and the resend path looked up that
  trimmed value — so a trailing space made the first send do nothing and a resend
  work, which is close to the least debuggable behaviour available.

  The second is that the attempt is logged at all. Without it, "no account matched" is
  indistinguishable from "the form was never submitted" — which is exactly how this
  presented, as a login that produced no log lines whatsoever.
  """
  use PolyphonyWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias Polyphony.Accounts

  defp user_with_email(email) do
    {:ok, user} =
      %{
        email: email,
        username: "user#{System.unique_integer([:positive])}",
        role: "user",
        attested_adult_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)
      }
      |> Accounts.User.registration_changeset()
      |> Polyphony.Repo.insert()

    user
  end

  describe "normalising an address" do
    test "trims as well as lower-cases" do
      assert Accounts.normalize_email("  Allen@Example.COM ") == "allen@example.com"
    end

    test "survives a non-binary without raising" do
      # It is fed straight from form params, which are not guaranteed to be anything.
      assert Accounts.normalize_email(nil) == ""
    end
  end

  describe "looking an account up" do
    test "a trailing space still finds the account" do
      user = user_with_email("allen@example.com")

      # The failure that locked an account out: a phone keyboard leaves this behind on
      # an autocompleted address, and nothing downstream said so.
      assert %{id: id} = Accounts.get_by_email("allen@example.com ")
      assert id == user.id
    end

    test "leading space and mixed case too" do
      user = user_with_email("allen@example.com")

      assert Accounts.get_by_email("  Allen@Example.com").id == user.id
    end

    test "an address stored with whitespace is stored canonically" do
      # The other half: normalising the lookup is no use if the row itself is untrimmed,
      # which is what the accompanying migration repairs for existing rows.
      user = user_with_email("  Spacey@Example.com  ")

      assert user.email == "spacey@example.com"
      assert Accounts.get_by_email("spacey@example.com").id == user.id
    end

    test "a genuinely unknown address is still a miss" do
      # The trimming must not turn into fuzzy matching.
      refute Accounts.get_by_email("nobody@example.com")
      refute Accounts.get_by_email("allen@example.co")
    end
  end

  describe "signing in by username" do
    test "the handle finds the account the email lookup could not" do
      user = user_with_email("someone@example.com")
      handle = user.username

      # The case this exists for: sign-in moved to email-only, which locks out anyone
      # whose account predates that and who remembers a handle instead.
      refute Accounts.get_by_email(handle)
      assert Accounts.get_by_login(handle).id == user.id
    end

    test "email still wins, and still works" do
      user = user_with_email("someone@example.com")

      assert Accounts.get_by_login("someone@example.com").id == user.id
    end

    test "a phone's autocapitalised handle still finds you" do
      user = user_with_email("caps@example.com")
      shouty = String.upcase(user.username)

      # A text input is autocapitalised by default on iOS, which is enough to make
      # your own handle miss. The input sets autocapitalize="none"; this is the belt.
      assert Accounts.get_by_username(shouty).id == user.id
      assert Accounts.get_by_username(" #{user.username} ").id == user.id
    end

    test "an ambiguous case-insensitive match answers nobody" do
      # Usernames are stored case-sensitively, so two rows can differ only by case.
      # Guessing between them would sign someone into the wrong account.
      a = user_with_email("a@example.com")

      {:ok, _b} =
        %{
          email: "b@example.com",
          username: String.upcase(a.username),
          role: "user",
          attested_adult_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)
        }
        |> Accounts.User.registration_changeset()
        |> Polyphony.Repo.insert()

      # Each exact form still resolves; only the *ambiguous* lookup is refused.
      assert Accounts.get_by_username(a.username).id == a.id
      assert Accounts.get_by_username(String.capitalize(a.username)) == nil
    end

    test "the username form sends a link and says which account matched" do
      user = user_with_email("handle@example.com")

      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        capture_log(fn ->
          {:ok, view, _html} =
            Phoenix.LiveViewTest.live(Phoenix.ConnTest.build_conn(), "/login")

          view
          |> Phoenix.LiveViewTest.form("#login-username-form", %{username: user.username})
          |> Phoenix.LiveViewTest.render_submit()
        end)

      assert log =~ "[mail] sign-in requested for #{user.username}"
      assert log =~ "matched @#{user.username}"
      # The link itself goes to the account's email, so the mail line names that.
      assert log =~ "h***@example.com"
    end
  end

  describe "the sign-in attempt is logged either way" do
    setup do
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)
      :ok
    end

    test "a match says so" do
      user_with_email("allen@example.com")

      log =
        capture_log(fn ->
          {:ok, view, _html} =
            Phoenix.LiveViewTest.live(Phoenix.ConnTest.build_conn(), "/login")

          view
          |> Phoenix.LiveViewTest.form("#login-form", %{email: "allen@example.com"})
          |> Phoenix.LiveViewTest.render_submit()
        end)

      assert log =~ "[mail] sign-in requested"
      assert log =~ "matched @"
      # Masked, because the drawer this reaches is readable by any visitor.
      assert log =~ "a***@example.com"
    end

    test "and so does a miss — the line that was missing entirely" do
      log =
        capture_log(fn ->
          {:ok, view, _html} =
            Phoenix.LiveViewTest.live(Phoenix.ConnTest.build_conn(), "/login")

          view
          |> Phoenix.LiveViewTest.form("#login-form", %{email: "nobody@example.com"})
          |> Phoenix.LiveViewTest.render_submit()
        end)

      assert log =~ "[mail] sign-in requested"
      assert log =~ "no account"
    end
  end
end

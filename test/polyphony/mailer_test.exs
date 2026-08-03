defmodule Polyphony.MailerTest do
  @moduledoc """
  Real email delivery (§B4), and the two guarantees around it that matter more than
  the sending itself.

  **Sign-in is magic-link only, so mail is the front door.** For most of this app's
  life the transport logged the *subject* and returned `{:ok, :logged}` — so every
  notification row said `"sent"`, nothing was ever delivered, and nobody could log in
  to an environment without the on-screen fallback.

  The second guarantee is that fallback's off switch. `LoginLive` prints the link on
  the page when `:expose_magic_link` is on, which must never be true in prod: it hands
  a working 15-minute session to anyone who types a known address. The version this
  replaced asked `Application.get_env(:polyphony, :env) == :prod` about a key nothing
  set, so the guard failed open. The prod-config assertion below is the regression
  test for that, and it reads the real config file rather than trusting a comment.
  """
  # Not async: these set application env (`:mail_from`, `:mail_headers`), which is
  # global — a concurrent module would see a vendor header it never configured.
  use ExUnit.Case, async: false

  import Swoosh.TestAssertions

  alias Polyphony.Notifications.Transport

  setup do
    Application.put_env(:polyphony, :mail_from, "hello@polyphony.test")
    on_exit(fn -> Application.delete_env(:polyphony, :mail_from) end)
  end

  describe "the email transport" do
    test "sends the address, subject and body it was handed" do
      assert {:ok, _} =
               Transport.Email.deliver_email(
                 "reader@example.com",
                 "Your Polyphony sign-in link",
                 "Sign in: https://polyphony.test/auth/verify/abc123"
               )

      assert_email_sent(fn email ->
        assert email.to == [{"", "reader@example.com"}]
        assert email.subject == "Your Polyphony sign-in link"
        # The link is the entire point of the mail — assert it survives, not just
        # that something was sent.
        assert email.text_body =~ "https://polyphony.test/auth/verify/abc123"
        # Plain text only: no HTML part to be filtered on, and nothing to leak.
        assert email.html_body == nil
      end)
    end

    test "sends from the configured address, with a display name" do
      Application.put_env(:polyphony, :mail_from_name, "Polyphony")

      assert {:ok, _} = Transport.Email.deliver_email("r@example.com", "Subject", "Body")

      assert_email_sent(fn email ->
        assert email.from == {"Polyphony", "hello@polyphony.test"}
      end)
    end

    test "configured provider headers are carried on the message" do
      Application.put_env(:polyphony, :mail_headers, %{"X-PM-Message-Stream" => "outbound"})
      on_exit(fn -> Application.delete_env(:polyphony, :mail_headers) end)

      assert {:ok, _} = Transport.Email.deliver_email("r@example.com", "Subject", "Body")

      # Postmark routes by stream. Without this the message is accepted and delivered
      # on whatever the server's default is, which may not be the one being watched.
      assert_email_sent(fn email ->
        assert email.headers["X-PM-Message-Stream"] == "outbound"
      end)
    end

    test "no configured headers means none added" do
      Application.delete_env(:polyphony, :mail_headers)

      assert {:ok, _} = Transport.Email.deliver_email("r@example.com", "Subject", "Body")

      # The transport is SMTP-generic: it must not name a vendor unless told to.
      # Asserted rather than refuted: `assert_email_sent/1` requires its function to
      # return something truthy, and a passing `refute` returns nil.
      assert_email_sent(fn email ->
        assert Map.get(email.headers, "X-PM-Message-Stream") == nil
      end)
    end

    test "an unconfigured from address is a delivery error, not a crash" do
      Application.delete_env(:polyphony, :mail_from)

      # Recorded as a failed notification by `Notifications.dispatch/6` rather than
      # taking down whatever was sending — a half-configured mailer must not be able
      # to break sign-in for everyone with an exception.
      assert {:error, :no_from_address} =
               Transport.Email.deliver_email("r@example.com", "Subject", "Body")
    end

    test "it satisfies the transport behaviour the notification path talks to" do
      # `Code.ensure_loaded!/1` is load-bearing: modules load lazily, so
      # `function_exported?/3` answers false for a perfectly good module that nothing
      # has called yet — which made this pass or fail on test order.
      Code.ensure_loaded!(Transport.Email)

      assert function_exported?(Transport.Email, :deliver_email, 3)

      # The behaviour is what lets `Notifications` swap transports by config alone.
      behaviours = Transport.Email.module_info(:attributes)[:behaviour] || []
      assert Transport in behaviours
    end
  end

  describe "the on-screen link is off in prod" do
    test "a prod build resolves :expose_magic_link to false" do
      config = Config.Reader.read!("config/config.exs", env: :prod)

      assert get_in(config, [:polyphony, :expose_magic_link]) == false
    end

    test "and is on everywhere else, so offline sign-in still works" do
      for env <- [:dev, :test] do
        config = Config.Reader.read!("config/config.exs", env: env)
        assert get_in(config, [:polyphony, :expose_magic_link]) == true
      end
    end

    test "the flag is a strict boolean in every env" do
      # `LoginLive` compares it against `true` and defaults to `false`, so a truthy
      # non-boolean — a `"false"` string out of an env var, say — would expose the
      # link. Pinning the type is what keeps that comparison honest.
      for env <- [:dev, :test, :prod] do
        value =
          get_in(Config.Reader.read!("config/config.exs", env: env), [
            :polyphony,
            :expose_magic_link
          ])

        assert is_boolean(value), "expected a boolean in #{env}, got #{inspect(value)}"
      end
    end
  end
end

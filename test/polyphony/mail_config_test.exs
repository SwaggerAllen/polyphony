defmodule Polyphony.MailConfigTest do
  @moduledoc """
  What `config/runtime.exs` resolves the mailer to, read from the real file with the
  real prod branch.

  Sign-in is magic-link only, so this config *is* the front door, and it is the one
  part of the app with no local equivalent — nothing in dev or test exercises it, and
  the first feedback is a failed send in production. That earns a test that reads the
  actual file rather than a restatement of it.

  The failure it was written for: a relay is a hostname, and gen_smtp hands it
  straight to DNS. Providers publish their settings as "server: smtp.example.com,
  ports: 25/587/2525", so pasting `smtp.example.com:587` into SMTP_HOST is a natural
  move — and it resolves to nothing, failing as `:nxdomain`, which names DNS rather
  than the mistake.
  """
  use ExUnit.Case, async: false

  @env %{
    "SECRET_KEY_BASE" => String.duplicate("x", 64),
    "DATABASE_URL" => "postgres://u:p@localhost/db",
    "PHX_HOST" => "example.com"
  }

  @mail_vars ~w(SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_SSL MAIL_FROM
               MAIL_FROM_NAME POSTMARK_MESSAGE_STREAM)

  # Reads the real file with a **clean** mail environment each time: the vars are
  # process-global, so anything left behind by a previous case would arm a mailer the
  # case under test never asked for.
  defp read_prod(extra) do
    saved = Map.new(@mail_vars ++ Map.keys(@env), &{&1, System.get_env(&1)})
    Enum.each(@mail_vars, &System.delete_env/1)
    System.put_env(Map.merge(@env, extra))

    try do
      Config.Reader.read!("config/runtime.exs", env: :prod)
    after
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  defp mailer_config(extra), do: read_prod(extra) |> get_in([:polyphony, Polyphony.Mailer])

  describe "the relay" do
    test "a plain hostname with an explicit port" do
      config =
        mailer_config(%{
          "SMTP_HOST" => "smtp.postmarkapp.com",
          "SMTP_PORT" => "587",
          "MAIL_FROM" => "hello@example.com"
        })

      assert config[:relay] == "smtp.postmarkapp.com"
      assert config[:port] == 587
    end

    test "a port pasted onto the host is split off, not sent to DNS" do
      config =
        mailer_config(%{
          "SMTP_HOST" => "smtp.postmarkapp.com:2525",
          "MAIL_FROM" => "hello@example.com"
        })

      # The whole point: `relay` must never carry the port, or it resolves to nothing.
      assert config[:relay] == "smtp.postmarkapp.com"
      assert config[:port] == 2525
    end

    test "an explicit SMTP_PORT wins over one on the host" do
      config =
        mailer_config(%{
          "SMTP_HOST" => "smtp.postmarkapp.com:25",
          "SMTP_PORT" => "587",
          "MAIL_FROM" => "hello@example.com"
        })

      assert config[:relay] == "smtp.postmarkapp.com"
      assert config[:port] == 587
    end

    test "defaults to submission, not port 25" do
      config =
        mailer_config(%{"SMTP_HOST" => "smtp.example.com", "MAIL_FROM" => "a@example.com"})

      # 25 is server-to-server relay and blocked outbound by most hosts, App Platform
      # included — defaulting to it would fail in a way that looks like a network fault.
      assert config[:port] == 587
    end

    test "the certificate is verified against the host actually connected to" do
      config =
        mailer_config(%{
          "SMTP_HOST" => "smtp.postmarkapp.com:587",
          "MAIL_FROM" => "a@example.com"
        })

      # SNI must be the bare host: with the port still attached it wouldn't match the
      # certificate, turning a config slip into a TLS error instead.
      assert config[:tls_options][:server_name_indication] == ~c"smtp.postmarkapp.com"
      assert config[:tls_options][:verify] == :verify_peer
    end

    test "a wildcard certificate is accepted, as a browser would" do
      config =
        mailer_config(%{"SMTP_HOST" => "smtp.example.com", "MAIL_FROM" => "a@example.com"})

      match_fun = config[:tls_options][:customize_hostname_check][:match_fun]

      # Erlang's default check is strict RFC 6125 and rejects `*.example.com` for
      # `smtp.example.com`. Providers serve wildcards, so `verify_peer` is unusable
      # without the `:https` rule — and it fails as `:tls_failed`, which reads like a
      # bad certificate rather than a missing option.
      assert is_function(match_fun, 2)

      assert match_fun.({:dns_id, ~c"smtp.example.com"}, {:dNSName, ~c"*.example.com"})

      # Still only the leftmost label: a wildcard must not span a dot.
      refute match_fun.({:dns_id, ~c"a.b.example.com"}, {:dNSName, ~c"*.example.com"}) == true
    end

    test "a port left on the host still wins, so it is warned about" do
      # Deleting SMTP_PORT is not enough on its own: the host's own port is still
      # honoured, which is right (an explicit choice is an explicit choice) but is the
      # one case where "I removed the port" doesn't do what it sounds like.
      assert mailer_config(%{"SMTP_HOST" => "smtp.example.com:25", "MAIL_FROM" => "a@e.com"})[
               :port
             ] == 25

      warning =
        ExUnit.CaptureIO.capture_io(fn ->
          mailer_config(%{"SMTP_HOST" => "smtp.example.com:25", "MAIL_FROM" => "a@e.com"})
        end)

      assert warning =~ "WARNING port 25"
    end

    test "MX lookups are off — a submission relay is connected to directly" do
      config =
        mailer_config(%{"SMTP_HOST" => "smtp.example.com", "MAIL_FROM" => "a@example.com"})

      # Asking who accepts mail *for* the relay's domain is a different question, and
      # for a host that does publish MX records it would send the mail elsewhere.
      assert config[:no_mx_lookups] == true
    end
  end

  describe "the Postmark message stream" do
    defp headers(extra), do: read_prod(extra) |> get_in([:polyphony, :mail_headers])

    test "defaults to the transactional stream for a Postmark relay" do
      assert headers(%{"SMTP_HOST" => "smtp.postmarkapp.com", "MAIL_FROM" => "a@e.com"}) ==
               %{"X-PM-Message-Stream" => "outbound"}
    end

    test "is not imposed on other providers" do
      # A vendor header defaulted for everyone would be noise at best, and this
      # transport is deliberately SMTP-generic.
      refute headers(%{"SMTP_HOST" => "smtp.sendgrid.net", "MAIL_FROM" => "a@e.com"})
    end

    test "can be pointed at another stream" do
      assert headers(%{
               "SMTP_HOST" => "smtp.postmarkapp.com",
               "MAIL_FROM" => "a@e.com",
               "POSTMARK_MESSAGE_STREAM" => "broadcast"
             }) == %{"X-PM-Message-Stream" => "broadcast"}
    end
  end

  describe "local development" do
    test "dev sends through the real transport into an in-memory mailbox" do
      dev = Config.Reader.read!("config/dev.exs", env: :dev)

      # Pointing the *transport* at Email is the part that is easy to miss: leave it on
      # `Transport.Log` and the mailbox stays empty while the log reports success.
      assert get_in(dev, [:polyphony, :notification_transport]) ==
               Polyphony.Notifications.Transport.Email

      assert get_in(dev, [:polyphony, Polyphony.Mailer])[:adapter] == Swoosh.Adapters.Local
      # `Transport.Email` refuses without one, so dev needs a sender too.
      assert get_in(dev, [:polyphony, :mail_from])
    end

    test "the mail viewer is dev-only, and off unless switched on" do
      # It renders every message the app has sent, magic links included. Same
      # fail-closed shape as `:expose_magic_link`: it must be switched on, never merely
      # fail to be switched off.
      assert get_in(Config.Reader.read!("config/dev.exs", env: :dev), [:polyphony, :dev_mailbox])

      for file <- ["config/config.exs", "config/test.exs"] do
        refute get_in(Config.Reader.read!(file, env: :prod), [:polyphony, :dev_mailbox])
      end
    end

    test "prod is untouched by any of it" do
      config = read_prod(%{"SMTP_HOST" => "smtp.example.com", "MAIL_FROM" => "a@e.com"})

      refute get_in(config, [:polyphony, :dev_mailbox])
      assert get_in(config, [:polyphony, Polyphony.Mailer])[:adapter] == Swoosh.Adapters.SMTP
    end
  end

  describe "arming the mailer at all" do
    test "half-configured stays on the logging transport" do
      # Deliberate: the failure should read as "no mail configured", not as a stream of
      # relay errors. `Transport.Log` still records the attempt, so it stays visible.
      for partial <- [%{"SMTP_HOST" => "smtp.example.com"}, %{"MAIL_FROM" => "a@example.com"}] do
        config = read_prod(partial)

        refute get_in(config, [:polyphony, :notification_transport]),
               "#{inspect(partial)} armed the real mailer on its own"
      end
    end

    test "both together arm it" do
      config = read_prod(%{"SMTP_HOST" => "smtp.example.com", "MAIL_FROM" => "a@example.com"})

      assert get_in(config, [:polyphony, :notification_transport]) ==
               Polyphony.Notifications.Transport.Email
    end
  end
end

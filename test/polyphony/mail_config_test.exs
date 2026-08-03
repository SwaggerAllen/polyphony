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

  @mail_vars ~w(SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_SSL MAIL_FROM MAIL_FROM_NAME)

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

    test "MX lookups are off — a submission relay is connected to directly" do
      config =
        mailer_config(%{"SMTP_HOST" => "smtp.example.com", "MAIL_FROM" => "a@example.com"})

      # Asking who accepts mail *for* the relay's domain is a different question, and
      # for a host that does publish MX records it would send the mail elsewhere.
      assert config[:no_mx_lookups] == true
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

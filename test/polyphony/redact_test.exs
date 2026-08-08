defmodule Polyphony.RedactTest do
  @moduledoc """
  What may not leave this box (STR-55).

  A crash reporter posts a payload to somebody else's servers, and every one of these
  cases is a thing that would sit in a third party's search index otherwise. The tests
  that matter most are the ones using **real tokens**, minted the way the app mints
  them, rather than a plausible-looking string: this module's failure mode is a pattern
  that stops matching when a token's shape changes, and a fixture invented to match the
  pattern can never catch that.

  Two of these exist because the first implementation got them wrong in a way that
  looked completely correct in the output — see `a key that only starts like a secret`
  and `a magic link's fingerprint distinguishes it`.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Redact

  # The real thing, from the code that signs magic links: `SFMyNTY.<payload>.<sig>`.
  defp magic_link_token, do: PolyphonyWeb.Auth.sign_token(42)

  # The real thing, from `Accounts.gen_token/0` — 18 random bytes, URL-safe base64.
  defp invite_token, do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  describe "credentials in a URL" do
    test "a magic link never survives, in a URL or a bare log line" do
      token = magic_link_token()

      for text <- [
            "https://polyphony.app/auth/verify/#{token}",
            "GET /auth/verify/#{token} 302",
            ~s|{"path":"/auth/verify/#{token}"}|
          ] do
        assert Redact.text(text) =~ "/auth/verify/"
        refute Redact.text(text) =~ token
      end
    end

    test "a share link never survives" do
      token = invite_token()
      out = Redact.text("/s/#{token}?tab=worlds")

      refute out =~ token
      assert out =~ "?tab=worlds"
    end

    test "a credential in a query parameter never survives" do
      token = invite_token()

      for key <- ~w(t token invite_token) do
        out = Redact.text("/signup?#{key}=#{token}&next=/library")

        refute out =~ token
        assert out =~ "#{key}="
        assert out =~ "next=/library"
      end
    end

    test "a key that only starts like a secret is left alone" do
      # `t` is the share-token param, and the first version of the key pattern let the
      # `=` bind to the last alternative only — so the group matched a bare `t` and
      # `?tab=worlds` came back as `tab=world…`. It reads as a working redactor right
      # up until you notice it is redacting the word "worlds".
      assert Redact.text("/browse?tab=worlds") == "/browse?tab=worlds"
      assert Redact.text("?tokens=3&secretive=no") == "?tokens=3&secretive=no"
    end
  end

  describe "fingerprints" do
    test "a magic link's fingerprint distinguishes it from another magic link" do
      # The whole justification for fingerprinting rather than deleting is that you can
      # match a report against the link that caused it. A `Phoenix.Token` opens with
      # base64 of the algorithm name, identical on every token this app has ever minted,
      # so measuring from the front produced `SFMyNTY.…` for all of them — a value that
      # looks like an identifier and identifies nothing. It was doing that in the mail
      # log too, which is where it came from.
      one = Redact.fingerprint(magic_link_token())
      two = Redact.fingerprint(PolyphonyWeb.Auth.sign_token(43))

      refute one == two
      refute one =~ "SFMyNTY"
    end

    test "the signature is never any part of it" do
      token = magic_link_token()
      [_header, _payload, signature] = String.split(token, ".")

      refute Redact.fingerprint(token) =~ signature
    end

    test "a short value comes back whole, because it is not a token" do
      assert Redact.fingerprint("wren") == "wren"
      assert Redact.fingerprint("") == ""
    end
  end

  describe "addresses" do
    test "are masked to a shape, by the same rule the delivery log uses" do
      assert Redact.text("mail to allen.strut@pm.me bounced") == "mail to a***@pm.me bounced"
      assert Redact.text("someone+tag@example.co.uk") == "s***@example.co.uk"
    end

    test "are masked before tokens are matched, so a local part stays a name" do
      # An address's local part is exactly the shape a token pattern looks for. Masking
      # afterwards would leave a fingerprint where a recognisable name should be.
      assert Redact.text("user=verylongusername@example.com") =~ "v***@example.com"
    end
  end

  describe "walking a payload" do
    test "reaches a credential however deep it is buried" do
      token = invite_token()

      payload = %{
        request: %{
          "params" => %{"invite_token" => token, "username" => "wren"},
          "headers" => [{"authorization", "Bearer #{token}"}, {"accept", "text/html"}]
        }
      }

      out = payload |> Redact.scrub() |> inspect(limit: :infinity)

      refute out =~ token
      assert out =~ "wren"
      assert out =~ "text/html"
    end

    test "a value under a secret key is fingerprinted whatever it looks like" do
      # A raw token in a header has no URL around it to recognise it by, so the key is
      # the only signal there is.
      assert %{"cookie" => cookie} =
               Redact.scrub(%{"cookie" => "_polyphony_key=abcdefghijklmnop"})

      refute cookie =~ "abcdefghijklmnop"
    end

    test "a Sentry event comes back a Sentry event" do
      # The actual input to `Crash.before_send/1`. If the walk flattened it to a map the
      # SDK would fail to serialize the event and the report would be lost — a redactor
      # that silently drops crash reports is worse than no redactor.
      event = %Sentry.Event{
        event_id: Sentry.UUID.uuid4_hex(),
        timestamp: "2026-01-01T00:00:00Z",
        message: %{formatted: "mail to a@b.com failed"}
      }

      assert %Sentry.Event{message: message, event_id: id} = Redact.scrub(event)
      assert message.formatted == "mail to a***@b.com failed"
      assert id == event.event_id
    end

    test "a term that cannot be rebuilt is redacted, not raised on" do
      # A map carrying a `__struct__` for a module this node doesn't have pattern-matches
      # as a struct and cannot be rebuilt as one — an ordinary thing to find in a payload
      # assembled out of whatever was in scope. What must survive is the *redaction*: the
      # shape is already lost, and raising here would mean the redactor taking down the
      # crash report it was called to clean.
      out = Redact.scrub(%{__struct__: NoSuchModule.AnywhereAtAll, who: "a@b.com"})

      assert out.who == "a***@b.com"
    end

    test "dates and other opaque structs are left exactly as they are" do
      term = %{when: ~N[2026-01-01 00:00:00], range: 1..5}
      assert Redact.scrub(term) == term
    end
  end

  describe "what is deliberately kept" do
    test "the transcript, secrets and all" do
      # The recorded decision, and the one most likely to be 'fixed' by somebody who
      # knows what `PolyphonyCore.Visibility` is for. A dev is not a character; a crash
      # report has no audience inside the story.
      assigns = %{
        messages: [
          %{speaker: "wren", content: "Halden doesn't know about the ledger."},
          %{speaker: "halden", content: "Whatever it is, she'll tell me."}
        ]
      }

      assert Redact.scrub(assigns) == assigns
    end

    test "module names, scene ids and the rest of a readable error" do
      # A reporter you can't diagnose from is the state this ticket exists to end, so
      # anything long and opaque that isn't in a credential's position stays legible.
      for text <- [
            "Elixir.PolyphonyWeb.BrowseLive.handle_event/3",
            "no function clause matching in Polyphony.Redact.walk/2",
            "scene sc-1755012894 beat 3 packet sc-1755012894-3-c-halden"
          ] do
        assert Redact.text(text) == text
      end
    end
  end
end

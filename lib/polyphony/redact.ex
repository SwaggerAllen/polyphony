defmodule Polyphony.Redact do
  @moduledoc """
  What may not leave this box — the one place that answers it (§B2, STR-55).

  A crash reporter posts an error payload to somebody else's servers, and the payload
  is assembled by a library out of whatever happened to be in scope: params, headers,
  cookies, the URL, LiveView assigns, the message on the exception. That is a wide net
  thrown by code that has no idea what any of it means, which makes *what it caught*
  something to check rather than assume.

  ## What is stripped, and why these

  **Credentials, everywhere they appear.** A magic-link token is a working session for
  fifteen minutes and an invite token is a way into an invite-only app, so either one
  in a payload is a live credential sitting in a third party's search index for as long
  as the link lives — which is a window measured from the link's lifetime, not the
  crash's. A share token is the grant an unlisted story is readable by. They are
  **fingerprinted, not deleted**: a short digest identifies which link a report is about
  without carrying any part of it, so a report stays followable and a payload stays
  useless. `fingerprint/1` explains why it is a digest and not the obvious prefix.

  **Addresses, down to a shape.** `a***@example.com` is enough to recognise a report
  about your own account and not enough to harvest anybody's. Same rule and the same
  function the delivery logs use (`Notifications.Transport.redact/1`), because an app
  with two answers to *how much of an address may be written down* has one answer it
  forgot about.

  **Session cookies**, which are simply a signed-in session in text form.

  ## What is deliberately *not* stripped

  **The fiction.** A crash on the play screen carries assigns, and those assigns carry
  the omniscient transcript — every secret every character is keeping. That is allowed,
  and it is a decision rather than an oversight:

  > A dev doesn't care about spoilers, and we may need to be able to see the transcript
  > for debugging purposes.

  It is worth saying loudly because everything else in this codebase is built to treat
  exactly that as a leak — `PolyphonyCore.Visibility` exists to prevent it, and a
  future reader finding the omniscient log in a crash payload will reach for a fix.
  Dramatic irony is a property of what a **character** is shown. A backtrace is not a
  character, and a crash report has no audience inside the story.

  ## Why a whitelist would be wrong here

  The obvious safer design is to send nothing except a stack trace. It is also how you
  end up with a reporter nobody can diagnose anything from, which is the state the app
  is in today — `SafeEvent` catches the error, shows a flash, and the failure is
  invisible to everyone who could fix it. This strips what is dangerous and keeps what
  is useful, and the list of dangerous things is short and enumerable because this app
  only mints three kinds of token.
  """

  alias Polyphony.Notifications.Transport

  # Hex digits of digest — enough to match a report against the link that caused it,
  # and the shortest value this will bother hashing.
  @keep 8

  # Position, not grammar. A magic link is a `Phoenix.Token` (`SFMyNTY.….…`, dotted,
  # past a hundred characters) and an invite is 24 characters of URL-safe base64 — a
  # pattern describing both, and only those, is a pattern that breaks silently the day
  # either changes. What is reliable is *where* they sit: everything after
  # `/auth/verify/` up to the next delimiter is the token, whatever it looks like.
  @rest ~S|[^/?#\s"'&<]+|
  @email ~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/

  # Rebuilding one of these from a map either fails or silently produces something
  # else, and none of them can hold a credential anyway.
  @opaque_structs [Date, Time, DateTime, NaiveDateTime, Regex, MapSet, Range]

  # Where a credential travels as a whole value rather than inside a sentence. Matched
  # case-insensitively against the key, so `Authorization`, `invite_token` and `t` are
  # all caught.
  @secret_keys ~w(token invite invite_token t share_token authorization cookie
                  set-cookie secret password api_key)

  @doc """
  Strip credentials from any term, however deeply nested.

  Walks maps, lists and tuples; leaves everything else alone but rewrites the strings
  it finds. Structs are walked as maps and rebuilt, so an exception carrying a URL in a
  field is covered as well as one carrying it in its message.
  """
  @spec scrub(term()) :: term()
  def scrub(term), do: walk(term, false)

  # `secret?` rides along: once a key has said its value is a credential, the whole
  # value is fingerprinted rather than pattern-matched, because a raw token is a bare
  # string with no URL around it to recognise it by.
  defp walk(%mod{} = struct, _secret?) when mod in @opaque_structs, do: struct

  defp walk(%mod{} = struct, secret?) do
    scrubbed = struct |> Map.from_struct() |> walk(secret?)

    try do
      struct(mod, scrubbed)
    rescue
      # A term that pattern-matches as a struct but cannot be rebuilt as one — a
      # `__struct__` naming a module this node doesn't have, which is an ordinary thing
      # to find in a payload assembled from whatever was in scope. Hand back the
      # scrubbed map: it is no longer the same shape, and it is *redacted*, which is the
      # property that must not be lost. Raising here would mean the redactor taking down
      # the crash report it was called to clean.
      _ -> scrubbed
    end
  end

  defp walk(map, secret?) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, walk(v, secret? or secret_key?(k))} end)
  end

  defp walk(list, secret?) when is_list(list) do
    Enum.map(list, fn
      {k, v} -> {k, walk(v, secret? or secret_key?(k))}
      other -> walk(other, secret?)
    end)
  end

  defp walk(tuple, secret?) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&walk(&1, secret?)) |> List.to_tuple()
  end

  defp walk(binary, true) when is_binary(binary), do: fingerprint(binary)
  defp walk(binary, false) when is_binary(binary), do: text(binary)
  defp walk(other, _secret?), do: other

  @doc """
  Rewrite the credentials inside one string.

  Order matters: addresses are masked first, because an address's local part is exactly
  the shape the token pattern is looking for and masking it afterwards would leave a
  fingerprint where a name should be.
  """
  @spec text(String.t()) :: String.t()
  def text(binary) when is_binary(binary) do
    binary
    |> String.replace(@email, &Transport.redact/1)
    |> replace_tokens()
  end

  def text(other), do: other

  # Only where we know a credential sits. A long opaque word in a message is far more
  # likely to be a module name, a scene id or a base64 blob somebody is debugging than
  # a token, and fingerprinting every one of them turns a readable error into a
  # redaction exercise — which is how a reporter stops being worth reading.
  @paths [~r|(/auth/verify/)(#{@rest})|, ~r|(/s/)(#{@rest})|]

  defp replace_tokens(binary) do
    # The non-capturing group around the alternation is load-bearing. Without it the
    # `=` binds to the last alternative only — `token|invite|…|api_key=` — so the group
    # matches a bare `t` and `?tab=worlds` comes out as `tab=world…`, a redaction of
    # something that was never a secret. Alternation has the lowest precedence there is.
    params = ~r/\b((?:#{Enum.join(@secret_keys, "|")})=)(#{@rest})/i

    @paths
    |> Enum.reduce(binary, &keep_prefix/2)
    |> then(&keep_prefix(params, &1))
  end

  defp keep_prefix(regex, binary),
    do:
      Regex.replace(regex, binary, fn _match, prefix, secret -> prefix <> fingerprint(secret) end)

  @doc """
  A token reduced to something you can match a report by and nothing you can use.

  **A digest, not a prefix**, and that took two goes to get right. The rule was
  originally "keep the first eight characters", which is what the mail log had always
  done. A `Phoenix.Token` is `SFMyNTY.<payload>.<signature>` and the first segment is
  base64 of the algorithm name — *identical on every token this app has ever minted* —
  so every magic link fingerprinted to `SFMyNTY.…`. Measuring from after the dot is no
  better: the payload opens with Erlang's term-format header, so two consecutive user
  ids still produce the same eight characters. Both versions look exactly right in a
  log line, which is why neither was noticed.

  Any prefix of a token is also the wrong shape twice over — it identifies poorly *and*
  it hands over real token material. A digest does neither: `#a1b2c3d4` reveals nothing,
  collides with nothing, and is reproducible, so a link somebody was emailed can be
  matched to the log line and the crash report that mention it by hashing it the same
  way. The `#` is there so it reads as an identifier rather than as a truncated secret.

  Short strings come back whole. They are not tokens, and hashing a four-character
  value loses information without protecting anything.
  """
  @spec fingerprint(String.t() | term()) :: String.t() | term()
  def fingerprint(value) when is_binary(value) do
    if String.length(value) > @keep do
      "#" <>
        (:sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower) |> binary_part(0, @keep))
    else
      value
    end
  end

  def fingerprint(other), do: other

  defp secret_key?(key) when is_atom(key), do: secret_key?(Atom.to_string(key))
  defp secret_key?(key) when is_binary(key), do: String.downcase(key) in @secret_keys
  defp secret_key?(_key), do: false
end

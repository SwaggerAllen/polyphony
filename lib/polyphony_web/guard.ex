defmodule PolyphonyWeb.Guard do
  @moduledoc """
  What an authoring screen does when you may not have the thing you asked for.

  Four screens each grew their own version of this — `gone_note/2` twice and
  `redirect_missing/2` once — which is how the fourth one ended up with no ownership
  check at all. One implementation, and adding a screen means calling it rather than
  remembering to.

  ## What it says, and what it refuses to say

  Three outcomes, and the distinction between them is the point:

    * **Taken down.** A moderated entry says so, because its owner has had an email
      about it and a silent disappearance would be worse than the news.
    * **Somebody else's.** Only when the reader could have read it anyway — it is
      published or shared — and then it says the true and useful thing: this is
      theirs, take a copy. That is the design's model (§2.5b), not a consolation.
    * **Not found.** Everything else, including *exists but is private and not yours*.
      A distinct "you're not allowed" would confirm the id belongs to something, which
      is a fact about somebody else's account, and ids here are small integers.
  """
  use PolyphonyWeb, :verified_routes

  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  alias Polyphony.Permissions

  @doc """
  Send them somewhere they may be, with a sentence explaining which of the three it is.

  Returns the `{:ok, socket}` a `mount/3` can hand straight back.
  """
  def refuse(socket, entry, noun, actor \\ nil)

  def refuse(socket, %{hidden_at: at}, _noun, _actor) when not is_nil(at),
    do:
      {:ok,
       socket
       |> put_flash(:error, "That was taken down after a report. Check your email.")
       |> redirect(to: ~p"/library")}

  # A published snapshot is readable by design, so pointing at the reading surface is
  # more useful than refusing — including to its own author, who cannot edit it either.
  def refuse(socket, %{frozen: true, kind: "campaign"} = entry, _noun, _actor),
    do:
      {:ok,
       socket
       |> put_flash(:info, "That's a published copy — here's how it reads.")
       |> redirect(to: ~p"/browse?#{[story: entry.id]}")}

  def refuse(socket, entry, noun, actor) do
    if Permissions.can_view?(entry, actor) do
      {:ok,
       socket
       |> put_flash(
         :info,
         "That #{String.downcase(noun)} is someone else's. Take a copy and it's yours to change."
       )
       |> redirect(to: ~p"/browse")}
    else
      {:ok, socket |> put_flash(:error, "#{noun} not found.") |> redirect(to: ~p"/library")}
    end
  end
end

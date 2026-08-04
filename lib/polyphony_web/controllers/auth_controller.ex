defmodule PolyphonyWeb.AuthController do
  @moduledoc "Magic-link verification + logout (session transport, §B2)."
  use PolyphonyWeb, :controller

  alias PolyphonyWeb.Auth
  alias Polyphony.Accounts

  def verify(conn, %{"token" => token}) do
    with {:ok, user_id} <- Auth.verify_token(token),
         %Accounts.User{} = user <- Accounts.get(user_id) do
      Auth.log_in_user(conn, user)
    else
      _ ->
        conn
        |> put_flash(:error, "That sign-in link is invalid or expired.")
        |> redirect(to: ~p"/login")
    end
  end

  def logout(conn, _params), do: Auth.log_out_user(conn)

  # A GET rather than an event, because deleting a cookie needs a response and nothing
  # sent over the LiveView socket has one. Same shape as `logout` above.
  def forget(conn, _params) do
    conn
    |> Auth.forget()
    |> put_flash(:info, "Forgotten — this device won't offer to sign you in.")
    |> redirect(to: ~p"/login")
  end
end

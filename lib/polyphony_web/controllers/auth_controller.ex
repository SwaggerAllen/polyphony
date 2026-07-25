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
end

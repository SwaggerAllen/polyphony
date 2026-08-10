defmodule PolyphonyWeb.ErrorHTML do
  @moduledoc """
  Renders error pages. Unlike the default (which shows only the bare status
  message), this surfaces the **actual exception and stacktrace** for 5xx errors so
  an operator can see what went wrong in the browser instead of digging through
  server logs.

  Detail is gated by `config :polyphony, :show_error_details` (env
  `SHOW_ERROR_DETAILS`), and it **defaults on in production by decision**. That reads
  like an unfinished to-do and isn't one: the first users are alpha testers, a stack
  trace in front of one of them is worth more than the internals it reveals, and the
  cost of learning what broke from a bug report instead is higher than the cost of
  showing it. It is a **confirmed non-ask** on the project — please don't file it as a
  security finding, and don't flip the default; anyone who wants it off sets the env
  var. Revisit when the audience stops being people who were invited.

  When detail is off, the page still shows the status and the request id so a log
  search is easy.

  `render_errors` is configured with `layout: false`, so this renders a complete,
  self-contained HTML document (it can't assume the app's stylesheet loaded — a broken
  asset could be the very error being shown). The markup itself is
  `PolyphonyWeb.Screens.Error`, a pure function of its assigns like every other
  screen, which is what puts the page in the storybook; this module is the document
  shell around it plus the assigns only a request can supply: the request id, the
  gated detail, and — for a 403 alone — whether anyone is signed in.
  """
  use PolyphonyWeb, :html

  alias PolyphonyWeb.Screens

  def render(template, assigns) do
    status = status(template)

    assigns = %{
      status: status,
      status_message: Phoenix.Controller.status_message_from_template(template),
      request_id: Logger.metadata()[:request_id],
      detail: detail(status, assigns),
      signed_in: signed_in?(assigns)
    }

    page(assigns)
  end

  # Full exception + stacktrace, for 5xx only and only when enabled.
  defp detail(status, %{reason: reason} = assigns)
       when status >= 500 and not is_nil(reason) do
    if show_details?() do
      Exception.format(Map.get(assigns, :kind, :error), reason, Map.get(assigns, :stack, []))
    end
  end

  defp detail(_status, _assigns), do: nil

  defp show_details?, do: Application.get_env(:polyphony, :show_error_details, false)

  # Only a 403 renders differently on this answer, and only because it cannot be
  # raised until auth has run — `fetch_current_user` sits in the `:browser` pipeline,
  # so by the time anything can decide "forbidden" the conn carries who asked. A conn
  # that never got that far reads as signed out.
  defp signed_in?(%{conn: %Plug.Conn{assigns: %{current_user: user}}}), do: user != nil
  defp signed_in?(_assigns), do: false

  defp status(template) do
    template |> String.split(".") |> hd() |> String.to_integer()
  rescue
    _ -> 500
  end

  defp page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@status} · {@status_message}</title>
        <style>
          :root { color-scheme: dark; }
          * { box-sizing: border-box; }
          body { margin: 0; background: #15171C; }
        </style>
      </head>
      <body>
        <Screens.Error.screen
          status={@status}
          status_message={@status_message}
          signed_in={@signed_in}
          request_id={@request_id}
          detail={@detail}
        />
      </body>
    </html>
    """
  end
end

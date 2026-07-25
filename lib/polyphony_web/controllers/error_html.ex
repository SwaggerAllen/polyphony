defmodule PolyphonyWeb.ErrorHTML do
  @moduledoc """
  Renders error pages. Unlike the default (which shows only the bare status
  message), this surfaces the **actual exception and stacktrace** for 5xx errors so
  an operator can see what went wrong in the browser instead of digging through
  server logs.

  Detail is gated by `config :polyphony, :show_error_details` (env
  `SHOW_ERROR_DETAILS`, default on in prod during bring-up — **turn it off before
  the app is public**, since stacktraces can leak internals). When detail is off,
  the page still shows the status and the request id so a log search is easy.

  `render_errors` is configured with `layout: false`, so this renders a complete,
  self-contained HTML document with inline styles (it can't assume the app's
  stylesheet loaded — a broken asset could be the very error being shown).
  """
  use PolyphonyWeb, :html

  def render(template, assigns) do
    status = status(template)

    assigns = %{
      status: status,
      status_message: Phoenix.Controller.status_message_from_template(template),
      request_id: Logger.metadata()[:request_id],
      detail: detail(status, assigns)
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
          body {
            margin: 0; background: #0f1115; color: #e6e8ee; min-height: 100vh;
            font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
          }
          main { max-width: 900px; margin: 0 auto; padding: 2.5rem 1.25rem; }
          .code { font-size: 3rem; font-weight: 800; margin: 0; color: #7c9cff; letter-spacing: .02em; }
          h1 { font-size: 1.4rem; margin: .25rem 0 1rem; }
          .rid { color: #9aa2b1; font-size: .85rem; margin: 0 0 1.5rem; }
          code { background: #1f232c; border-radius: 6px; padding: .1rem .35rem; }
          pre.detail {
            background: #171a21; border: 1px solid #2b303b; border-radius: 10px;
            padding: 1rem; overflow-x: auto; font-size: .82rem; line-height: 1.5;
            color: #f0b8b8; white-space: pre-wrap; word-break: break-word;
          }
          .hint { color: #9aa2b1; }
          a { color: #7c9cff; text-decoration: none; }
          a:hover { text-decoration: underline; }
        </style>
      </head>
      <body>
        <main>
          <p class="code">{@status}</p>
          <h1>{@status_message}</h1>
          <p :if={@request_id} class="rid">request id: <code>{@request_id}</code></p>

          <pre :if={@detail} class="detail">{@detail}</pre>
          <p :if={is_nil(@detail)} class="hint">
            Something went wrong.
            <span :if={@status >= 500}>
              The full error is in the server logs<span :if={@request_id}>— search for the request id above</span>.
            </span>
          </p>

          <p style="margin-top:1.5rem;"><a href="/">← Home</a></p>
        </main>
      </body>
    </html>
    """
  end
end

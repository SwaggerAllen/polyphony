defmodule PolyphonyWeb.Screens.Error do
  @moduledoc """
  The error page, as markup — the screen you get when there isn't one.

  Unlike every other screen this one uses **no kit classes and no `var()` tokens**: the
  shipped page must render when assets don't (a broken asset can be the error being
  shown), so the kit's `stage.dark` values are written out literally in the template.
  The mapping is hand-kept against `ux/polyphony-kit.css` and nothing checks it, so a
  kit change is a reason to look here — see the first standing decision in
  `docs/behaviors/error.md`; generating this block at build time is an open
  investigation on the issue.

      #15171C  --b1        #1D2027  --b2       #E9E5D9  --bc / --pri
      #8C897E  --bcm       #2E323C  --rule     #E0604A  --pencil
      #15171C  --pric
      Spectral, Georgia, serif        --f-title
      Archivo, system-ui, sans-serif  --f-ui
      "IBM Plex Mono", monospace      --f-mono

  The page loads no fonts either, so the families degrade to the same system stack the
  kit already falls back to.

  A 403 is the one state allowed to vary by session — it cannot be reached without
  auth having already run — and nothing else may. The rest of the copy's argument
  (a 404 assigns no blame; a 500 admits fault; the request id is always shown) is in
  `docs/behaviors/error.md`.
  """
  use PolyphonyWeb, :html

  attr(:status, :integer, required: true)

  attr(:status_message, :string,
    default: nil,
    doc: "Phoenix's message for the template — the title for statuses nobody has drawn"
  )

  attr(:signed_in, :boolean,
    default: false,
    doc: "read by the 403 states only — see the standing decision"
  )

  attr(:request_id, :string, default: nil)

  attr(:detail, :string,
    default: nil,
    doc: "formatted exception + stacktrace; the caller decides whether it may be shown"
  )

  def screen(assigns) do
    assigns =
      assigns
      |> assign(:title, title(assigns))
      |> assign(:message, message(assigns))

    ~H"""
    <div style="background:#15171C;color:#E9E5D9;font-family:Archivo,system-ui,sans-serif;min-height:100vh">
      <main style="max-width:900px;margin:0 auto;padding:2.5rem 1.25rem">
        <p style="font-family:Spectral,Georgia,serif;font-size:2.75rem;font-weight:600;margin:0;color:#8C897E;letter-spacing:.01em">
          {@status}
        </p>
        <h1 style="font-family:Spectral,Georgia,serif;font-size:1.3rem;font-weight:500;margin:.35rem 0 1rem">
          {@title}
        </h1>
        <p :if={@request_id} style="color:#8C897E;font-size:12px;margin:0 0 1.5rem">
          request id:
          <code style="background:#1D2027;border-radius:6px;padding:.1rem .35rem;font-family:'IBM Plex Mono',monospace">{@request_id}</code>
        </p>

        <p :if={@message} style="font-size:13.5px;line-height:1.6;margin:0 0 1.25rem;max-width:38ch">
          {@message}
        </p>

        <pre
          :if={@detail}
          style="background:#1D2027;border:1px solid #2E323C;border-radius:10px;padding:.85rem;overflow-x:auto;font-family:'IBM Plex Mono',monospace;font-size:11.5px;line-height:1.55;color:#E0604A;white-space:pre-wrap;margin:0 0 1.25rem"
        >{@detail}</pre>

        <p :if={@status == 403 and not @signed_in} style="margin:0 0 1rem">
          <a
            href="/login"
            style="display:inline-flex;align-items:center;border-radius:8px;padding:.25rem .5rem;font-size:12px;font-weight:600;border:1px solid transparent;background:#E9E5D9;color:#15171C;text-decoration:none"
          >
            Sign in
          </a>
        </p>

        <p style="margin:0">
          <a
            href="/"
            style="color:#E9E5D9;border-bottom:1px solid #2E323C;text-decoration:none;font-size:13px"
          >
            ← Polyphony
          </a>
        </p>
      </main>
    </div>
    """
  end

  defp title(%{status: 404}), do: "Nothing here"
  defp title(%{status: 403, signed_in: true}), do: "This isn't yours"
  defp title(%{status: 403}), do: "This one's private"
  defp title(%{status: status}) when status >= 500, do: "That one's on us"
  defp title(%{status: status} = assigns), do: assigns[:status_message] || to_string(status)

  # A 404 says what happened and assigns no blame; a 500 admits fault; a 403 tells the
  # truth about existence and, signed out, offers the door without promising it opens.
  defp message(%{status: 404}),
    do:
      "That address doesn't lead anywhere. It may have been mistyped, or the thing it pointed at may be gone."

  defp message(%{status: 403, signed_in: true}),
    do:
      "You're signed in, but this campaign isn't one of yours. If somebody meant to share it, they'll need to add you."

  defp message(%{status: 403}),
    do: "Who can open it depends on the account. You're not signed in on this device."

  defp message(%{status: status} = assigns) when status >= 500 do
    if assigns[:detail] do
      "Something broke while loading this. The details below are for whoever looks into it."
    else
      "Something broke while loading this. Quote the id above if you tell us about it."
    end
  end

  defp message(_assigns), do: nil
end

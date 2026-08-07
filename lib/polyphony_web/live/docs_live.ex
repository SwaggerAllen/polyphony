defmodule PolyphonyWeb.DocsLive do
  @moduledoc """
  One page listing every served doc, at `/docs` (and `/ux` — the same page).

  `Plug.Static` serves the files themselves and has no directory listing, so without
  this the docs are reachable only by somebody who already knows the filenames, which
  is exactly the person who doesn't need them. This is the URL you hand over: it names
  every file, says in a line what each is for, and links it.

  Built by **reading the directory**, not from a list written here. An index written by
  hand is a third thing to keep in step with `docs/` and `priv/static/docs`, and its
  failure mode is silence — a doc that exists and isn't listed is a doc nobody finds.

  A LiveView rather than a controller rendering a string, for one reason: HEEx escapes,
  and a page assembled by string interpolation is the shape `Sobelow`'s `XSS.SendResp`
  exists to flag. Nothing here is user input today; the point is that it can't become
  one quietly. It also means the page gets the app's shell and the `☰` like every other
  screen, instead of being a second kind of page.

  Public and unauthenticated, like the files it points at — see `Mix.Tasks.Docs.Publish`
  for what that publishes and why.
  """
  use PolyphonyWeb, :live_view

  alias PolyphonyWeb.{Kit, Layouts}

  @roots [
    {"docs", "The architecture, the roadmap, and the reasoning behind both."},
    {"ux", "The design: static mocks, the component kit, and the original brief."}
  ]

  # A line each, so the index reads rather than lists. Anything without a blurb is still
  # listed — an unexplained doc beats a missing one.
  @about %{
    "docs/README.md" => "Start here: what each document is for and where new writing goes.",
    "docs/architecture.md" => "How the shipped system works, section by section.",
    "docs/completed-roadmap.md" => "What's already been built, with the detail.",
    "docs/backend-capabilities.md" => "What the backend can already do, as a reference.",
    "docs/decisions.md" => "Post-v1 rationale — the forward argument, not the schedule.",
    "docs/deployment.md" => "Running it: the release, the host, mail, and the env vars.",
    "docs/frontend.md" => "The LiveView layer and how to run it.",
    "docs/design-thread.md" =>
      "Instructions for a normal Claude thread doing design work — what to read, and how work gets handed to the code thread.",
    "docs/behaviors/README.md" =>
      "What a behaviors doc is, the `rev` convention, and the index of the screens.",
    "ux/README.md" => "The design pass: information architecture, copy rules, porting notes.",
    "ux/polyphony-kit.css" => "The single source of truth for tokens and component classes.",
    "ux/polyphony-kit.html" => "The component kit, rendered — every component and its states.",
    "ux/archive/design-brief.md" =>
      "The original design brief. Every `§n` in the code cites this."
  }

  def mount(_params, _session, socket) do
    sections = for {root, blurb} <- @roots, do: %{root: root, blurb: blurb, files: listing(root)}
    {:ok, assign(socket, page_title: "Docs", sections: sections)}
  end

  # Through `Application.app_dir/2`, and with no help from the Mix task that wrote these
  # files: a release has no Mix and its working directory is not the project root, so a
  # relative path and a `Mix.*` call are both things that work in dev and crash in prod.
  defp listing(root) do
    dir = Application.app_dir(:polyphony, Path.join("priv/static", root))

    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: false)
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
    |> Enum.map(&%{href: "/#{root}/#{&1}", about: about("#{root}/#{&1}")})
  end

  # Hand-written where a file needs explaining, derived where it doesn't. Every screen's
  # behaviors doc says the same thing about a different screen, and fifteen copies of that
  # sentence in the map above is fifteen chances for one to be forgotten when a screen is
  # added — which is the exact failure this index exists to avoid.
  defp about("docs/behaviors/README.md" = path), do: Map.get(@about, path)

  defp about("docs/behaviors/" <> file),
    do:
      "What the #{file |> Path.rootname() |> String.replace("_", " ")} screen does, from a user's seat."

  defp about(path), do: Map.get(@about, path)

  def render(assigns) do
    ~H"""
    <Kit.frame class="min-h-[100dvh]">
      <Kit.header title="Documentation" subtitle="Served as files — no account needed">
        <:actions>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <div class="max-w-2xl mx-auto px-4 py-6">
        <p class="text-[13.5px] leading-relaxed dim mb-6">
          Everything in the repository's <span class="mono">docs/</span>
          and <span class="mono">ux/</span>. Markdown is served as text; the
          <span class="mono">ux</span>
          mocks render as pages.
        </p>

        <div :for={section <- @sections} class="mb-7">
          <div class="lbl dim mb-1"><%= section.root %>/</div>
          <p class="text-[12.5px] leading-relaxed dim mb-2.5"><%= section.blurb %></p>
          <Kit.sheet>
            <a :for={file <- section.files} href={file.href} class="row block px-4 py-2.5">
              <div class="mono text-[12.5px]"><%= file.href %></div>
              <div :if={file.about} class="text-[11.5px] leading-relaxed dim mt-0.5">
                <%= file.about %>
              </div>
            </a>
          </Kit.sheet>
        </div>
      </div>
    </Kit.frame>
    """
  end
end

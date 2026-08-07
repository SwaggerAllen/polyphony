defmodule Mix.Tasks.Docs.Publish do
  @moduledoc """
  Copy `docs/` and `ux/` into `priv/static/`, so the running app serves them.

  ## Why a copy

  The docs are the thing you hand somebody — a person, or a Claude thread — when they
  ask how this works. They are unreachable from outside the repo: it is private, so raw
  GitHub URLs need credentials, and `docs/`/`ux/` sit at the repo root, which is *not*
  in an OTP release. A release ships `priv/` and compiled beams and nothing else.

  So the files are copied under `priv/static` and committed, the same arrangement the
  built assets use and for the same reason: the artefact ships, and a drift guard
  (`DocsPublishTest`) fails the build when the source moved and nobody re-ran this. The
  alternative — copying only in the Dockerfile — would mean dev and prod serve different
  things, which is the class of difference that is only ever discovered in prod.

  ## What is copied

  Everything, verbatim, except the two dot-directories no reader wants. `docs/*.md`,
  `ux/*.html`, `ux/polyphony-kit.css` and `ux/archive/design-brief.md` — the brief every
  moduledoc cites as §n, and the single most useful file here for somebody trying to
  understand the product.

  Nothing is transformed. A `.md` is served as `text/markdown` and a mock renders as the
  page it is, because `Plug.Static` runs ahead of the router and so ahead of the CSP —
  which is what lets the mocks keep their CDN Tailwind.

  ## This is public

  Whatever is in `docs/` is readable by anyone who can reach the deployment, with no
  account. That includes `deployment.md`, which names every environment variable and
  describes how the mailbox gate works. It holds no secret *values* and it is still an
  operational map; if that stops being an acceptable trade, `@skip` below is where a
  file gets left behind.

      mix docs.publish           # refresh priv/static/docs and priv/static/ux
      mix docs.publish --check   # exit non-zero if it would change (CI/test guard)
  """
  @shortdoc "Copy docs/ and ux/ into priv/static so the app serves them"

  use Mix.Task

  # Build tooling, not part of the layering: a mix task reaches wherever it needs to and
  # nothing reaches back into it.
  use Boundary, check: [in: false, out: false]

  @trees [{"docs", "priv/static/docs"}, {"ux", "priv/static/ux"}]

  # Nothing a reader wants, and everything a copy of a working tree accumulates.
  @skip ~w(.DS_Store)

  @impl Mix.Task
  def run(args) do
    check? = "--check" in args

    stale =
      Enum.filter(@trees, fn {source, target} ->
        want = collect(source)
        have = collect(target)

        cond do
          Map.keys(want) != Map.keys(have) -> true
          Enum.any?(want, fn {path, body} -> Map.get(have, path) != body end) -> true
          true -> false
        end
      end)

    cond do
      stale == [] ->
        Mix.shell().info("docs are published and current")

      check? ->
        names = Enum.map_join(stale, ", ", fn {source, _} -> source end)
        Mix.raise("#{names} changed — run `mix docs.publish` and commit the result")

      true ->
        Enum.each(stale, &publish/1)
    end
  end

  @doc "The `{source, target}` pairs this task keeps in step."
  @spec trees() :: [{String.t(), String.t()}]
  def trees, do: @trees

  @doc "Every publishable file under `root`, as `%{relative_path => contents}`."
  @spec collect(String.t()) :: %{optional(String.t()) => binary()}
  def collect(root) do
    if File.dir?(root) do
      root
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: false)
      |> Enum.reject(&File.dir?/1)
      |> Enum.reject(&(Path.basename(&1) in @skip))
      |> Map.new(&{Path.relative_to(&1, root), File.read!(&1)})
    else
      %{}
    end
  end

  defp publish({source, target}) do
    File.rm_rf!(target)

    for {path, body} <- collect(source) do
      out = Path.join(target, path)
      File.mkdir_p!(Path.dirname(out))
      File.write!(out, body)
    end

    Mix.shell().info("published #{source} -> #{target}")
  end
end

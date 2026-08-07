defmodule Polyphony.Test.Purity do
  @moduledoc """
  Which functions can reach the database, computed rather than declared.

  ## Why this exists

  `PolyphonyWeb.Screens.*` may not read. That is what makes a screen renderable from
  fixture assigns, and it is what makes `STORYBOOK=true` safe in production — a story
  that could load a campaign would quietly turn that flag into an authorization hole.

  The first version of the guard asked *"does this call `Polyphony.*`?"*, which is a
  **proxy** for the real question and a bad one. Most of what a screen calls into the
  domain is a pure projection over a struct it already holds: `Library.payload/1` is
  `decode(bin)`, `Cast.render_name/2` is a `Map.get`, `WorldBible.statements/1` is a
  comprehension. Banning those forced a growing allowlist of hand-checked exemptions —
  a list nobody reads, where every entry is a judgement that can be wrong.

  So this asks the actual question: **can control flow get from here to `Repo`?** It
  builds a call graph across the whole `Polyphony.*` tree from each module's abstract
  code, seeds it with the functions that touch `Ecto`/`Repo`/`Postgrex` directly, and
  propagates until it stops changing. `Library.payload/1` comes out pure on its own
  merits; `Audience.resolve/1` comes out impure because it reaches `Groups.member_ids/2`
  and from there the repo. Nothing is exempted by hand.

  ## What it does not see

  Dynamic dispatch — `apply/3`, a protocol, a module in a variable — is invisible to a
  static walk, so an impure function reached that way would pass. That hole is closed
  from the other side: `PolyphonyWeb.StorybookTest` fails a screen module that contains
  any dynamic dispatch at all, which is cheap because screens are markup and have no
  business doing it. Together the two make the analysis sound for the code it governs.
  """

  @db ~w(Elixir.Ecto Elixir.Postgrex Elixir.Polyphony.Repo Elixir.Polyphony.EventStore
         Elixir.Commanded Elixir.Oban)

  # Everything under `Polyphony.LLM` is a call out to a provider — except `LLM.Settings`,
  # which is the per-campaign config struct read off a payload and reaches nothing.
  @llm {~w(Elixir.Polyphony.LLM), ~w(Elixir.Polyphony.LLM.Settings)}

  @doc """
  `MapSet` of `{module, function, arity}` in the `Polyphony.*` tree that can reach the
  database. Computed once and cached in `:persistent_term` — the walk is a second or so
  and several tests want the same answer.
  """
  @spec impure() :: MapSet.t({module(), atom(), arity()})
  def impure, do: reaching(@db)

  # Everything an effect can be, not just a database read. The distinction decides
  # `PolyphonyCore`'s membership and it is not academic: under a repo-only floor
  # `Broadcast`, `Mailer` and `DebugLog` all score clean, and they publish, send mail and
  # write ETS respectively.
  @effects @db ++
             ~w(Elixir.Phoenix.PubSub Elixir.Polyphony.Mailer Elixir.Swoosh Elixir.Logger
                Elixir.File Elixir.System Elixir.Task Elixir.GenServer Elixir.Agent
                Elixir.Process ets persistent_term Elixir.Polyphony.LLM
                Elixir.Polyphony.Broadcast Elixir.Polyphony.DebugLog
                Elixir.Polyphony.Notifications)

  @doc """
  Everything that can reach an effect of any kind — the floor `PolyphonyCore` is held to.
  """
  @spec reaches_effects() :: MapSet.t({module(), atom(), arity()})
  def reaches_effects, do: reaching({@effects, ~w(Elixir.Polyphony.LLM.Settings)})

  @doc """
  The same question for a different floor: what can reach a **provider call**?

  Aggregates are replayed, so a generation inside `execute/2` would re-fire every time
  the stream is rebuilt — invariant 2 in `CLAUDE.md`, and until this existed it rested
  entirely on somebody noticing in review.
  """
  @spec reaches_llm() :: MapSet.t({module(), atom(), arity()})
  def reaches_llm, do: reaching(@llm)

  @doc """
  Every `Polyphony.*` function that can reach a module named by `roots`.

  `roots` is a list of module-name prefixes, or a `{included, excluded}` pair when a
  namespace has an exception in it. Results are cached per root set — several tests want
  the same answer and the walk is a second or so.
  """
  @spec reaching([String.t()] | {[String.t()], [String.t()]}) ::
          MapSet.t({module(), atom(), arity()})
  def reaching(roots) do
    key = {__MODULE__, roots}

    case :persistent_term.get(key, nil) do
      nil ->
        set = compute(roots)
        :persistent_term.put(key, set)
        set

      set ->
        set
    end
  end

  defp compute(roots) do
    graph = call_graph()

    seeds =
      for {mfa, calls} <- graph, Enum.any?(calls, &root?(&1, roots)), into: MapSet.new(), do: mfa

    close(graph, seeds)
  end

  # Fixpoint: keep adding callers of anything already known to reach the roots.
  defp close(graph, known) do
    grown =
      for {mfa, calls} <- graph,
          not MapSet.member?(known, mfa),
          Enum.any?(calls, &MapSet.member?(known, &1)),
          into: known,
          do: mfa

    if MapSet.size(grown) == MapSet.size(known), do: known, else: close(graph, grown)
  end

  defp root?(mfa, {included, excluded}) do
    root?(mfa, included) and not root?(mfa, excluded)
  end

  defp root?({m, _f, _a}, prefixes) when is_list(prefixes) do
    name = to_string(m)
    Enum.any?(prefixes, &String.starts_with?(name, &1))
  end

  @doc "Every `Polyphony.*` function, mapped to the MFAs it calls."
  @spec call_graph() :: %{{module(), atom(), arity()} => [{module(), atom(), arity()}]}
  def call_graph do
    for path <- beams(), {mod, forms} <- abstract(path), into: %{}, do: {mod, forms}
  end

  @doc """
  Every call a single module makes, read from its **abstract code**.

  The `:imports` chunk is not enough for this. A genuinely dynamic call — a module
  arriving in a variable, as in `assigns[:mod].get(id)` — leaves *no trace at all*
  there, not even an `:erlang.apply/3`, so a check built on imports silently passes
  the one thing it was written to catch. The abstract code still has the shape.

  Dynamic calls come back as `{:dynamic, :dispatch, 0}`.
  """
  @spec calls_in(module()) :: [{module() | :dynamic, atom(), arity()}]
  def calls_in(mod) do
    case :beam_lib.chunks(:code.which(mod), [:abstract_code]) do
      {:ok, {_, [abstract_code: {:raw_abstract_v1, forms}]}} ->
        for {:function, _anno, _name, _arity, clauses} <- forms, reduce: [] do
          acc -> acc ++ calls(clauses, mod)
        end
        |> Enum.uniq()
        |> Enum.map(fn
          {Ecto, :__dynamic_dispatch__, 0} -> {:dynamic, :dispatch, 0}
          other -> other
        end)

      _ ->
        []
    end
  end

  defp beams do
    Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "polyphony", "ebin", "*.beam"]))
  end

  defp abstract(path) do
    with {:ok, {mod, [abstract_code: {:raw_abstract_v1, forms}]}} <-
           :beam_lib.chunks(String.to_charlist(path), [:abstract_code]),
         true <- String.starts_with?(to_string(mod), "Elixir.Polyphony") do
      for {:function, _anno, name, arity, clauses} <- forms do
        {{mod, name, arity}, calls(clauses, mod)}
      end
    else
      _ -> []
    end
  end

  # Remote calls keep their module; a local call is resolved against the module it sits
  # in, which is what lets a private helper carry impurity up to its public caller.
  defp calls(ast, mod), do: ast |> walk([], mod) |> Enum.uniq()

  defp walk({:call, _, {:remote, _, {:atom, _, m}, {:atom, _, f}}, args}, acc, mod),
    do: walk(args, [{m, f, length(args)} | acc], mod)

  # **A call on a module this walk cannot name is assumed to read.**
  #
  # Not a corner case: the repo is injectable throughout the domain — `repo(opts)`
  # returns `Polyphony.Repo` or a sandbox — so the query is `repo.all(q)`, a call whose
  # module is a variable. Reading those as "unknown, therefore fine" is what made the
  # first run of this analysis declare `Library.get/1` pure, which is exactly backwards
  # for a guard whose whole job is refusing reads.
  #
  # Being conservative here costs nothing on the screen path, because a screen contains
  # no dynamic dispatch at all — `PolyphonyWeb.StorybookTest` fails one that does.
  defp walk({:call, _, {:remote, _, _module, _fun}, args}, acc, mod),
    do: walk(args, [{Ecto, :__dynamic_dispatch__, 0} | acc], mod)

  defp walk({:call, _, {:atom, _, f}, args}, acc, mod),
    do: walk(args, [{mod, f, length(args)} | acc], mod)

  # `&Mod.fun/1` is an edge, and it did not used to be one. A capture is not a `:call`
  # node, so the walk above never saw it and descended into it as an anonymous tuple,
  # producing nothing — which meant a screen could reach the repo through
  # `Enum.map(ids, &Library.get/1)` and every guard here passed. Found by writing that
  # line into a screen and watching the suite stay green.
  defp walk({:fun, _, {:function, {:atom, _, m}, {:atom, _, f}, {:integer, _, a}}}, acc, _mod),
    do: [{m, f, a} | acc]

  # The same thing with any part computed — `&mod.fun/1` — is a module this walk cannot
  # name, and gets the same treatment as a dynamic call.
  defp walk({:fun, _, {:function, _m, _f, _a}}, acc, _mod),
    do: [{Ecto, :__dynamic_dispatch__, 0} | acc]

  defp walk({:fun, _, {:function, f, a}}, acc, mod) when is_atom(f) and is_integer(a),
    do: [{mod, f, a} | acc]

  defp walk(list, acc, mod) when is_list(list),
    do: Enum.reduce(list, acc, &walk(&1, &2, mod))

  defp walk(tuple, acc, mod) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> walk(acc, mod)

  defp walk(_other, acc, _mod), do: acc
end

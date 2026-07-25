defmodule Polyphony.Director.Arbitration do
  @moduledoc """
  Stage-1 arbitration (§10): mechanical, deterministic, free — pure Elixir, no
  LLM.

  Resolve each proposal against topology and entity state:

    * **auto-accept the trivial** — an `:exit` to a real connection, an
      `:interact` with an entity actually present;
    * **auto-reject the impossible** — an exit that isn't there, an entity that
      isn't;
    * **forward the rest** — every `:novel` proposal goes to the judgment call.

  This is small precisely because the valid option set was injected into the
  character's context (`Polyphony.Director.Options`), so most proposals are
  already well-formed. What survives to Stage 2 is the genuinely ambiguous.
  """

  alias Polyphony.Director.Proposal

  @type ruling ::
          {:accept, Proposal.t()} | {:reject, Proposal.t(), atom()} | {:forward, Proposal.t()}
  @type result :: %{
          accepted: [Proposal.t()],
          rejected: [{Proposal.t(), atom()}],
          forwarded: [Proposal.t()]
        }

  @doc "Classify proposals against `%{exits: [...], entities: [...]}` (see `Options`)."
  @spec classify([Proposal.t()], Polyphony.Director.Options.t()) :: result()
  def classify(proposals, options) do
    exits = MapSet.new(options[:exits] || [])
    entities = MapSet.new(options[:entities] || [])

    proposals
    |> Enum.map(&rule(&1, exits, entities))
    |> Enum.reduce(%{accepted: [], rejected: [], forwarded: []}, fn
      {:accept, p}, acc -> %{acc | accepted: acc.accepted ++ [p]}
      {:reject, p, reason}, acc -> %{acc | rejected: acc.rejected ++ [{p, reason}]}
      {:forward, p}, acc -> %{acc | forwarded: acc.forwarded ++ [p]}
    end)
  end

  @spec rule(Proposal.t(), MapSet.t(), MapSet.t()) :: ruling()
  defp rule(%Proposal{type: :exit, target: target} = p, exits, _entities) do
    if MapSet.member?(exits, to_string(target)),
      do: {:accept, p},
      else: {:reject, p, :no_such_exit}
  end

  defp rule(%Proposal{type: :interact, target: target} = p, _exits, entities) do
    if MapSet.member?(entities, to_string(target)),
      do: {:accept, p},
      else: {:reject, p, :no_such_entity}
  end

  # Novel proposals are always arbitrated by judgment (§10).
  defp rule(%Proposal{type: :novel} = p, _exits, _entities), do: {:forward, p}
end

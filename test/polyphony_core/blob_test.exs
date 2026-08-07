defmodule PolyphonyCore.BlobTest do
  @moduledoc """
  A term this application wrote must still read back after the module that shaped it moves.

  `Blob` stores Erlang term format, which writes a struct's module out as an atom — so a
  struct in a `:binary` column makes its **module path part of the stored data**, and a
  rename orphans every row already written. `:safe` then refuses to invent the missing
  atom, and the decode raises rather than degrading: a campaign's whole payload is lost
  because one nested struct changed namespace.

  Two things have to hold for `@renames` to actually rescue those rows, and they fail
  independently:

    * **the legacy atom must exist** before `binary_to_term/2` sees it, which is why the
      table spells the old names out for the compiler to bake in — loading `Blob` then
      registers them. Assemble those names at call time instead and the table still reads
      correctly while rescuing nothing;
    * **the mapping must be applied**, field by field, into whatever answers to the name
      today.

  The first is checked against `Blob`'s compiled code rather than the running VM, because
  in the test VM the atoms exist for a dozen incidental reasons and an in-VM check would
  pass no matter what the module did.
  """
  use ExUnit.Case, async: true

  alias PolyphonyCore.Blob
  alias PolyphonyCore.Content.CampaignConfig

  # Every `{:atom, _, name}` node anywhere in a module's abstract code — which is where a
  # name written as a literal shows up, and where one assembled at runtime does not.
  defp literal_atoms({:atom, _, name}), do: [name]
  defp literal_atoms(form) when is_tuple(form), do: form |> Tuple.to_list() |> literal_atoms()
  defp literal_atoms(forms) when is_list(forms), do: Enum.flat_map(forms, &literal_atoms/1)
  defp literal_atoms(_), do: []

  describe "the rename table" do
    test "every legacy name is a literal in the compiled module, not a runtime string" do
      {:ok, {_mod, [abstract_code: {:raw_abstract_v1, forms}]}} =
        Blob |> :code.which() |> :beam_lib.chunks([:abstract_code])

      present = forms |> literal_atoms() |> MapSet.new()

      for {legacy, _current} <- Blob.renames() do
        assert MapSet.member?(present, legacy), """
        #{inspect(legacy)} is in the rename table but appears nowhere in PolyphonyCore.Blob's
        compiled code as an atom.

        The whole mechanism is that loading `Blob` puts these atoms in the VM's table, so
        `:safe` can read a row written under a name no module answers to any more. That
        only happens for atoms the compiler baked in. Assembling one at call time —
        `String.to_atom/1` on a stored string, a name from config — leaves a table that
        reads correctly and rescues nothing.
        """
      end
    end

    test "every current module is real, and is not itself a legacy name" do
      legacy = Blob.renames() |> Map.keys() |> MapSet.new()

      for {_old, current} <- Blob.renames() do
        assert Code.ensure_loaded?(current)
        refute MapSet.member?(legacy, current), "#{inspect(current)} maps to itself"
      end
    end
  end

  describe "decoding a blob written under an old name" do
    # Hand-built rather than encoded from a struct: the point is a term whose `__struct__`
    # names a module that no longer exists, and there is no way to hold one of those except
    # to write the atom out.
    defp legacy_blob(module, fields),
      do: fields |> Map.put(:__struct__, module) |> :erlang.term_to_binary()

    test "a config stored as Polyphony.Content.CampaignConfig comes back as the current one" do
      bin =
        legacy_blob(:"Elixir.Polyphony.Content.CampaignConfig", %{
          adult_content: true,
          sexual: true,
          graphic_violence: false,
          other: false
        })

      assert %CampaignConfig{adult_content: true, sexual: true} = Blob.decode(bin)
      assert CampaignConfig.enabled(Blob.decode(bin)) == [:sexual]
    end

    test "the intermediate Polyphony.Core spelling reads too" do
      bin =
        legacy_blob(:"Elixir.Polyphony.Core.Content.CampaignConfig", %{
          adult_content: true,
          other: true
        })

      # A field the struct has since gained takes its default rather than staying unset.
      assert %CampaignConfig{adult_content: true, other: true, sexual: false} = Blob.decode(bin)
    end

    test "a legacy struct nested inside a payload is reached" do
      payload = %{
        name: "The Long Quiet",
        premise: "a wake nobody wanted",
        content_config: %{
          __struct__: :"Elixir.Polyphony.Content.CampaignConfig",
          adult_content: true,
          sexual: false,
          graphic_violence: true,
          other: false
        }
      }

      decoded = Blob.decode(:erlang.term_to_binary(payload))

      # The rest of the payload is the reason this matters: before the rename table, one
      # nested struct took the campaign's name and premise down with it.
      assert decoded.name == "The Long Quiet"
      assert decoded.premise == "a wake nobody wanted"
      assert %CampaignConfig{graphic_violence: true} = decoded.content_config
    end

    test "a legacy struct inside a list inside a struct is reached" do
      inner = %{__struct__: :"Elixir.Polyphony.Publication", perspectives: ["mira"]}
      bin = :erlang.term_to_binary(%{scenes: [%{pubs: [inner]}]})

      assert %{scenes: [%{pubs: [%PolyphonyCore.Publication{perspectives: ["mira"]}]}]} =
               Blob.decode(bin)
    end

    test "a field the struct has since dropped is discarded rather than crashing" do
      bin =
        legacy_blob(:"Elixir.Polyphony.Content.CampaignConfig", %{adult_content: true, gore: 1})

      assert %CampaignConfig{adult_content: true} = Blob.decode(bin)
    end
  end

  describe "everything else" do
    test "a blob with no legacy name round-trips untouched" do
      term = %{name: "ordinary", config: %CampaignConfig{sexual: true}, list: [1, {2, :three}]}

      assert Blob.decode(Blob.encode(term)) == term
    end

    test "nil stays nil in both directions" do
      assert Blob.encode(nil) == nil
      assert Blob.decode(nil) == nil
    end
  end
end

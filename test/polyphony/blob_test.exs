defmodule Polyphony.BlobTest do
  @moduledoc """
  The one `binary_to_term` in the application, and the flag that makes it safe.

  Five tables store a domain struct whole rather than in columns, and each had its own
  private codec — five copies of `:erlang.binary_to_term(bin, [:safe])` and five copies
  of the Sobelow annotation that says so. The length wasn't the problem; the repetition
  of a **security decision** was. Without `:safe`, decoding fabricates atoms and module
  references out of whatever is in the binary, and the annotation that quiets the
  scanner would have been copied along with the sixth version that forgot it.

  Centralising it means the guarantee is a thing a test can hold, which is what this is.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Blob

  describe "round trip" do
    test "a struct comes back as itself" do
      sheet = %Polyphony.Authoring.CharacterSheet{name: "Wren", status: :stub, tier: :incidental}
      assert sheet |> Blob.encode() |> Blob.decode() == sheet
    end

    test "nil stays nil at both ends" do
      assert Blob.encode(nil) == nil
      assert Blob.decode(nil) == nil
    end
  end

  describe ":safe" do
    test "refuses to invent an atom that isn't already loaded" do
      # ATOM_EXT by hand (tag 100), because there is no way to *encode* an atom the VM
      # doesn't have — which is the point. A binary from anywhere but our own column
      # could carry one, and an unguarded decode would add it to a table that is never
      # collected.
      name = "an_atom_this_application_never_defines"
      refute atom_exists?(name)

      crafted = <<131, 100, byte_size(name)::16, name::binary>>

      assert_raise ArgumentError, fn -> Blob.decode(crafted) end
      refute atom_exists?(name), "decoding created the atom, so :safe was not in force"
    end

    test "an atom the code already uses decodes fine" do
      # The flag refuses *fabrication*, not atoms — everything stored here is built from
      # structs and literal atoms this application compiled.
      assert Blob.decode(Blob.encode(:proposed)) == :proposed
    end
  end

  defp atom_exists?(name) do
    _ = String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end
end

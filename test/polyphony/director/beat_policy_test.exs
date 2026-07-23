defmodule Polyphony.Director.BeatPolicyTest do
  @moduledoc "The beat-loop stopping rule (§10) — pure."
  use ExUnit.Case, async: true

  alias Polyphony.Director.BeatPolicy

  test "continues while under the depth cap and the Director says continue" do
    assert :continue = BeatPolicy.next(%{depth: 0, control: :continue})
    assert :continue = BeatPolicy.next(%{depth: 1, control: :continue})
  end

  test "yields when the Director asks to" do
    assert :yield_to_user = BeatPolicy.next(%{depth: 0, control: :yield_to_user})
  end

  test "yields at the hard depth cap even if the Director wants to continue" do
    # default max_depth is 3: the beat about to be depth 2->3 stops.
    assert :yield_to_user = BeatPolicy.next(%{depth: 2, control: :continue})
  end

  test "a membership change truncates, overriding continue and the depth check" do
    assert :truncate = BeatPolicy.next(%{depth: 0, control: :continue, membership_changed: true})

    assert :truncate =
             BeatPolicy.next(%{depth: 2, control: :yield_to_user, membership_changed: true})
  end

  test "respects a custom max_depth" do
    assert :continue = BeatPolicy.next(%{depth: 3, control: :continue, max_depth: 10})
    assert :yield_to_user = BeatPolicy.next(%{depth: 4, control: :continue, max_depth: 5})
  end
end

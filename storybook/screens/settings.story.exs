defmodule Storybook.Screens.Settings do
  use PhoenixStorybook.Story, :component

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Screens.Settings.screen/1

  @user %{id: "u1", username: "wren", email: "wren@example.com", role: "user"}

  defp rows,
    do: [
      %{id: "camp-1", name: "The Salt Line", detail: "4 scenes", amount: 184_000},
      %{id: "camp-2", name: "Nightjar", detail: "1 scene", amount: 22_500},
      %{id: nil, name: "Outside any scene", detail: "Quick Build, autofill", amount: 9_100}
    ]

  defp base do
    %{
      current_user: @user,
      cap: 500_000,
      spent_today: 215_600,
      this_month: 1_204_000,
      fraction: 0.43,
      turns_left: 38,
      spend_rows: rows(),
      notifications: %{"report_alert" => true, "scene_ready" => false},
      what_goes: "3 campaigns, 2 worlds and 41 characters. All of it, gone in 30 days."
    }
  end

  defp v(id, description, overrides),
    do: %Variation{
      id: id,
      description: description,
      attributes: base() |> Map.merge(overrides) |> Map.put(:id, to_string(id))
    }

  def variations do
    [
      v(
        :settled,
        "Spend as **turns remaining**, not a percentage — nobody knows what 43% of their budget feels like, but everybody knows what nine more turns feels like. The per-campaign breakdown attributes a scene's generations to the campaign that owns the scene, which is how one story eating a month becomes visible before the cap bites.",
        %{}
      ),
      v(
        :no_history,
        "A new account. `turns_left` is **nil rather than a guess** — there is nothing to estimate from, and a made-up number here is worse than an absent one.",
        %{turns_left: nil, spent_today: 0, fraction: 0.0, this_month: 0, spend_rows: []}
      ),
      v(
        :cap_reached,
        "At the ceiling. The error copy has always said *you can raise it in Settings*, so the control has to actually be here — it was a promise with nothing behind it for a long time.",
        %{fraction: 1.0, turns_left: 0, spent_today: 500_000}
      ),
      v(
        :editing_cap,
        "Raising it. A daily cap and a per-campaign lifetime cap protect against different things — a runaway loop versus one story eating the month — which is why they live in different places.",
        %{editing_cap: true}
      ),
      v(
        :username_locked,
        "The handle is on a cooldown after a change. Stated as a date rather than a refusal, because *no* without *when* reads as a bug.",
        %{username_free_in: 12}
      ),
      v(
        :needs_reconsent,
        "The consent documents moved. Shown as a task rather than a modal, since blocking the whole account on a policy update punishes the wrong person.",
        %{needs_reconsent: true}
      ),
      v(
        :confirming_delete,
        "The delete confirmation, counting **what actually goes** — 'all your work' is easy to skim past and 'three campaigns, two worlds and forty-one characters' is not.",
        %{confirming_delete: true}
      ),
      v(
        :deletion_pending,
        "Already asked for. A decision on a clock rather than an event: signing back in inside the window takes it all back.",
        %{days_until_deletion: 26}
      )
    ]
  end
end

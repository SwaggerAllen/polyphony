defmodule Storybook.Screens.Admin do
  use PhoenixStorybook.Story, :component

  alias Polyphony.Accounts.{Invite, User}
  alias Polyphony.Moderation.{AuditLog, Report}
  alias Polyphony.ReadModels.LibraryEntry

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Screens.Admin.screen/1

  # Ages are rendered from `inserted_at`, so the fixtures are pinned relative to a fixed
  # instant rather than to now — a storybook page that reads "3m old" one minute and
  # "4m old" the next is a diff nobody can review.
  @now ~N[2026-03-04 21:00:00.000000]

  defp ago(minutes), do: NaiveDateTime.add(@now, -minutes * 60, :second)

  defp user(id, name, opts \\ []),
    do: %User{
      id: id,
      username: name,
      role: opts[:role] || "user",
      inserted_at: opts[:since] || ago(60 * 24 * 200)
    }

  defp report(id, opts),
    do: %Report{
      id: id,
      reason: opts[:reason] || "harassment",
      detail: opts[:detail],
      status: opts[:status] || "open",
      resolution: opts[:resolution],
      owner_id: opts[:owner_id] || 11,
      reporter_id: opts[:reporter_id] || 12,
      item_type: "library_entry",
      item_id: opts[:item_id] || 100,
      inserted_at: ago(opts[:age_min] || 30)
    }

  defp entry(id, opts \\ []),
    do: %LibraryEntry{
      id: id,
      kind: opts[:kind] || "campaign",
      owner_id: "11",
      visibility: opts[:visibility] || "public",
      inserted_at: ago(60 * 24 * 9)
    }

  defp audit(id, action, opts),
    do: %AuditLog{
      id: id,
      action: action,
      actor_id: 10,
      target_type: opts[:target_type] || "library_entry",
      target_id: opts[:target_id] || 100,
      metadata: opts[:metadata] || %{},
      inserted_at: ago(opts[:age_min] || 120)
    }

  defp invite(id, token, opts),
    do: %Invite{
      id: id,
      token: token,
      reusable: opts[:reusable] || false,
      uses: opts[:uses] || 0,
      redeemed_by_id: opts[:redeemed_by_id],
      revoked_at: opts[:revoked_at],
      inserted_at: ago(60 * 24 * (opts[:days] || 3))
    }

  defp history(opts \\ []),
    do: %{
      against: opts[:against] || [],
      against_upheld: opts[:against_upheld] || 0,
      made: opts[:made] || [],
      made_dismissed: opts[:made_dismissed] || 0
    }

  # Every line naming a person or an artifact is resolved once in the LiveView and keyed
  # `{kind, id}` — the screen only looks them up. The story supplies the same map, which
  # is the honest way to show a screen that takes answers rather than sources.
  defp lines do
    %{
      {:subject, 41} => "A campaign · The Long Quiet",
      {:by, 41} => "By ilias · reported 12m ago",
      {:subject, 42} => "A campaign · Saltmarch",
      {:by, 42} => "By wren · reported 2h ago",
      {:subject, 43} => "A character · Ilias Vane",
      {:by, 43} => "reported 5h ago",
      {:name, 100} => "The Long Quiet",
      {:item, 100} => "A campaign · public · 9 days old",
      {:name, 101} => "The Long Quiet (a fork)",
      {:item, 101} => "A campaign · public · 4 days old",
      {:fork, 101} => "By marek · descended from what was taken down",
      {:name, 102} => "Wren Ashgrove",
      {:item, 102} => "A character · private · 9 days old",
      {:audit, 71} => "sam · library_entry #100 · \"the reported passage needs context\"",
      {:audit, 72} => "sam · library_entry #100",
      {:audit, 73} => "sam · user #11 · \"repeat, after two warnings\"",
      {:invite, 81} => "Unused · made March",
      {:invite, 82} => "Reusable — stays valid · used 4 times · made March",
      {:invite, 83} => "Used by marek · March"
    }
  end

  defp lanes(opts \\ []),
    do: %{
      urgent: opts[:urgent] || [],
      rest: opts[:rest] || [],
      forks: opts[:forks] || []
    }

  # Storybook does not apply `attr` defaults — a variation's attributes are the whole of
  # the assigns — so every key the screen reads is named once, here.
  defp defaults do
    %{
      current_user: user(10, "sam", role: "admin"),
      tab: "waiting",
      lanes:
        lanes(
          rest: [
            report(42, reason: "nonconsensual_content", detail: "this is my photo", age_min: 120),
            report(43, reason: "other", age_min: 300)
          ]
        ),
      decided: [],
      suspended: [],
      admins: [],
      audit: [],
      invites: [],
      open: nil,
      unlocking: nil,
      viewed: nil,
      lines: lines(),
      fork_count: 0
    }
  end

  defp open_report(opts \\ []) do
    r = report(41, reason: "harassment", detail: "please look", age_min: 12)

    %{
      id: 41,
      report: r,
      reason: r.reason,
      detail: r.detail,
      owner: user(11, "wren"),
      reporter: user(12, "ilias"),
      history: opts[:history] || history(),
      dismissals: opts[:dismissals] || 0,
      item: Keyword.get(opts, :item, entry(100))
    }
  end

  defp v(id, description, overrides),
    do: %Variation{
      id: id,
      description: description,
      attributes: defaults() |> Map.merge(overrides) |> Map.put(:id, to_string(id))
    }

  def variations do
    [
      v(
        :queue,
        "The queue, with the child-safety lane on top. Not a filter on a general list — a **separate lane, always first**, because the alternative is the one report that can't wait sitting under forty about spam. Oldest first inside each lane.",
        %{
          lanes:
            lanes(
              urgent: [report(41, reason: "csam", detail: "please look", age_min: 12)],
              rest: [
                report(42,
                  reason: "nonconsensual_content",
                  detail: "this is my photo",
                  age_min: 120
                ),
                report(43, reason: "other", age_min: 300)
              ]
            )
        }
      ),
      v(
        :queue_empty,
        "Nothing waiting, which is the state this screen is in nearly all the time. It says how the queue orders itself rather than leaving a blank sheet, because the ordering is the thing a new moderator has to know before the first report arrives.",
        %{lanes: lanes()}
      ),
      v(
        :fork_lane,
        "A take-down spreads, and can't spread blind. A fork may have diverged twenty scenes past anything objectionable, so a take-down opens a **review lane** instead of firing a cascade — and somebody looks.",
        %{lanes: lanes(forks: [%{entry: entry(101), root_id: 100}])}
      ),
      v(
        :one_report,
        "One report, with everything needed to decide in a single read. Content and people are separate sections with separate buttons — taking down a snapshot and suspending an account have different consequences and different reversals, and one button for both is how the wrong one gets pressed.",
        %{open: open_report()}
      ),
      v(
        :history,
        "Both directions of the account's history. Someone whose own reports are nearly all dismissed is a signal too, and a queue that only ever looks at the accused can't see it.",
        %{
          open:
            open_report(
              history:
                history(
                  against: [
                    report(38, status: "actioned", resolution: "takedown", age_min: 60 * 24 * 40),
                    report(39, status: "dismissed", age_min: 60 * 24 * 70)
                  ],
                  against_upheld: 1,
                  made: [report(44, reporter_id: 11), report(45, reporter_id: 11)],
                  made_dismissed: 2
                ),
              dismissals: 3
            )
        }
      ),
      v(
        :unlocking,
        "The bypass, asked for out loud. A moderator has to see what the author never shared in order to judge — that's a real privilege, so the screen says what it means and asks **why** first. Nobody types a reason forty times a day for something they don't need.",
        %{open: open_report(), unlocking: true}
      ),
      v(
        :viewed,
        "Granted, and written down with their name on it. The banner stays up for as long as the unpublished material is on screen, because an access that looks like ordinary reading is one nobody remembers making.",
        %{open: open_report(), viewed: [entry(100), entry(102, kind: "character")]}
      ),
      v(
        :takedown_spreads,
        "The same report where the thing reported has descendants. The confirmation names what a take-down sweeps up rather than saying \"a campaign\" — the weight of the action should be visible at the moment of taking it.",
        %{open: open_report(), fork_count: 3}
      ),
      v(
        :decided,
        "What was decided, and what was done. Privilege use is tinted: reading an unpublished perspective is the entry most likely to matter later and the least likely to be looked for.",
        %{
          tab: "decided",
          decided: [
            report(42, status: "actioned", resolution: "takedown"),
            report(43, status: "dismissed")
          ],
          audit: [
            audit(71, "content_access", metadata: %{"why" => "context"}, age_min: 30),
            audit(72, "takedown", age_min: 28),
            audit(73, "suspend", target_type: "user", target_id: 11, age_min: 25)
          ]
        }
      ),
      v(
        :suspended,
        "Who is suspended and for how long, and how much of theirs went dark with it. Every row has a **Lift it** — an indefinite suspension with no way back is a deletion nobody agreed to.",
        %{
          tab: "suspended",
          suspended: [
            %{user: user(11, "wren"), days_left: 5, hidden: 3},
            %{user: user(13, "marek"), days_left: nil, hidden: 0}
          ]
        }
      ),
      v(
        :invites,
        "The door. Two buttons rather than a switch, because a reusable invite is a different object once minted — a standing hole in the gate for as long as it exists — so it says so on the row and it can be closed.",
        %{
          tab: "invites",
          invites: [
            invite(81, "SALT-MARCH-9F2K", days: 2),
            invite(82, "OPEN-TIDE-4Q7X", reusable: true, uses: 4, days: 20),
            invite(83, "GONE-WREN-1B8M", redeemed_by_id: 13, days: 40)
          ]
        }
      ),
      v(
        :invites_empty,
        "No invites minted. Worth saying why the list exists at all, since invite-only is a decision about this stage of the project rather than a permanent shape.",
        %{tab: "invites", invites: []}
      ),
      v(
        :admins,
        "Who can do all of this. The first account is pinned — there is exactly one superadmin, minted at first sign-up and never assignable — and everybody else can be made ordinary again, because an admin promoted by mistake used to be permanent.",
        %{
          tab: "admins",
          admins: [
            user(9, "root", role: "superadmin"),
            user(10, "sam", role: "admin", since: ago(60 * 24 * 120))
          ]
        }
      )
    ]
  end
end

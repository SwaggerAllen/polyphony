defmodule PolyphonyWeb.Screens.Home do
  @moduledoc """
  The landing page, as markup.

  What somebody sees before they have an account, and the only screen whose job is to
  explain what this is. It takes one assign — whether anybody is signed in — because a
  returning visitor needs a route to their own work rather than a pitch.
  """
  use PolyphonyWeb, :html

  alias PolyphonyWeb.{Kit, Layouts}

  attr(:current_user, :map, default: nil, doc: "signed-in user, or nil")

  def screen(assigns) do
    ~H"""
    <Kit.frame class="relative min-h-[100dvh]">
      <Layouts.corner_menu current_user={@current_user} />
      <div class="max-w-md mx-auto px-4 py-10">
        <.hero current_user={@current_user} />
        <.demo />
        <.how />
        <.closing :if={is_nil(@current_user)} />
      </div>
    </Kit.frame>
    """
  end

  attr(:current_user, :map, default: nil)

  defp hero(assigns) do
    ~H"""
    <div class="px-1 mb-6">
      <div class="lbl dim mb-2">Polyphony</div>
      <h1 class="ttl text-[28px] leading-[1.15] font-semibold mb-3">
        Write a world, cast some people, and find out what they do.
      </h1>
      <p class="text-[14.5px] leading-relaxed dim mb-5">
        Every character is played by their own AI, and every one of them knows only what
        they have actually seen. You see all of it. That gap is the whole point.
      </p>

      <div class="flex flex-wrap gap-1.5">
        <.link :if={@current_user} navigate={~p"/library"} class="btn btn-pri">Your stuff</.link>
        <.link :if={is_nil(@current_user)} navigate={~p"/signup"} class="btn btn-pri">
          Create an account
        </.link>
        <.link :if={is_nil(@current_user)} navigate={~p"/login"} class="btn btn-gh">Sign in</.link>
        <.link navigate={~p"/browse"} class="btn btn-gh">Browse published</.link>
      </div>
      <p :if={is_nil(@current_user)} class="text-[12px] leading-relaxed dim mt-2.5">
        No password to remember — we email you a link.
      </p>
    </div>
    """
  end

  # The argument, made rather than described. The attribution lines are the kit's, and
  # they say who can see a move — which is the same thing they say in play.
  defp demo(assigns) do
    ~H"""
    <Kit.sheet class="mb-6">
      <div class="px-4 py-3 row" style="background:var(--b2)">
        <div class="lbl dim">A scene, as the author sees it</div>
      </div>

      <div class="px-4 py-3">
        <Kit.world_move class="mb-3">
          The tide is out, and the ledger is due at the harbour office by dawn.
        </Kit.world_move>

        <Kit.thought colour="var(--v1)" note="Thought · only Wren" class="mb-3">
          She already burned the second page. If he asks to see it she will have to decide
          how much she likes him.
        </Kit.thought>

        <div class="flex gap-2 mb-1">
          <span class="dot mt-2 shrink-0" style="background:var(--v2)"></span>
          <p class="text-[14.5px] leading-relaxed">
            <span class="lbl" style="color:var(--v2)">Bram</span><br />
            "Bring it over when you've finished. I'll sign for both of us."
          </p>
        </div>
      </div>

      <div class="px-4 py-3 row" style="background:var(--b2)">
        <p class="text-[12.5px] leading-relaxed dim">
          Bram's AI was never given that first paragraph, so he cannot act on it — not
          because he was told to pretend, but because it was never in front of him. He
          finds out when Wren tells him, or when he catches her.
        </p>
      </div>
    </Kit.sheet>
    """
  end

  defp how(assigns) do
    ~H"""
    <Kit.sheet class="mb-6">
      <Kit.row class="px-4 py-3" style="background:var(--b2)">
        <div class="lbl dim">How it goes</div>
      </Kit.row>

      <Kit.row class="px-4 py-3">
        <div class="text-[13.5px] font-semibold mb-1">Write a world, or ask for one</div>
        <p class="text-[13px] leading-relaxed dim">
          A sentence is enough to start. Quick Build takes a line like "a rain-drowned
          harbour town" and comes back with the place, a cast who already know each other,
          and a premise.
        </p>
      </Kit.row>

      <Kit.row class="px-4 py-3">
        <div class="text-[13.5px] font-semibold mb-1">Give people something to hide</div>
        <p class="text-[13px] leading-relaxed dim">
          Facts on a character sheet carry an audience: everyone, nobody, or these two.
          That is what the other characters' AI is and isn't handed, so a secret is a
          property of the story rather than an instruction anyone can talk their way past.
        </p>
      </Kit.row>

      <Kit.row class="px-4 py-3">
        <div class="text-[13.5px] font-semibold mb-1">Set a scene and let it run</div>
        <p class="text-[13px] leading-relaxed dim">
          Pick who's in it and where. Everyone takes their turn; you can write any of them
          yourself, re-roll a line you don't like, or fork the scene and try it the other
          way without losing the first one.
        </p>
      </Kit.row>

      <Kit.row class="px-4 py-3">
        <div class="text-[13.5px] font-semibold mb-1">Read it back, or publish it</div>
        <p class="text-[13px] leading-relaxed dim">
          A finished campaign can be read the way anyone in it experienced it — including
          the ones who were wrong about everything.
        </p>
      </Kit.row>
    </Kit.sheet>
    """
  end

  defp closing(assigns) do
    ~H"""
    <Kit.sheet class="p-5 text-center">
      <div class="ttl text-[18px] font-semibold mb-1.5">Start with one sentence</div>
      <p class="text-[13px] leading-relaxed dim mb-4">
        You can have a world, a cast and a first scene in about a minute.
      </p>
      <div class="flex flex-col gap-1.5">
        <.link navigate={~p"/signup"} class="btn btn-pri justify-center">Create an account</.link>
        <.link navigate={~p"/login"} class="btn btn-gh justify-center">
          I already have one
        </.link>
      </div>
    </Kit.sheet>
    """
  end
end

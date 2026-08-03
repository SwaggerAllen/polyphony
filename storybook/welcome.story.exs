defmodule Storybook.Welcome do
  use PhoenixStorybook.Story, :page

  def doc, do: "The design kit, as it actually renders."

  def render(assigns) do
    ~H"""
    <div class="psb-welcome-page">
      <p>
        This is the live counterpart to <code>ux/polyphony-kit.html</code>. Every component
        <code>PolyphonyWeb.Kit</code>
        provides is here with its states, so a component can be
        reviewed on its own instead of only in situ on a screen.
      </p>

      <h2>Where things live</h2>
      <ul>
        <li>
          <strong>ux/polyphony-kit.css</strong>
          — the single source of truth for tokens and component classes. Change the design here.
        </li>
        <li>
          <strong>assets/css/kit.css</strong>
          — generated from it by <code>mix kit.port</code>. Never hand-edited;
          <code>PolyphonyWeb.KitPortTest</code>
          fails if the two disagree.
        </li>
        <li>
          <strong>lib/polyphony_web/components/kit.ex</strong>
          — the markup half of the port: the kit's structural idioms as function components.
        </li>
        <li>
          <strong>storybook/</strong>
          — these pages.
        </li>
      </ul>

      <h2>Two registers, not two design systems</h2>
      <p>
        The axis is <em>working vs reading</em>, not author vs player.
        <code>.stage</code>
        is omniscient play and every authoring screen — machinery visible, gutter labels, editorial
        controls. <code>.page</code>
        is a player in their own character's head, and published
        campaigns — wider measure, larger body, machinery at the edges. Same tokens, same components,
        different density. Every variation below is rendered inside a frame that picks one.
      </p>

      <h2>Four colours that mean something</h2>
      <p>
        <strong>lamp</strong>
        is <em>now</em> — the live turn, the current beat, an unsaved draft, and the only bright thing
        on screen. <strong>pencil</strong>
        is <em>correction</em> — reroll, edit, delete, branch, and every error; it is never a primary
        action. <strong>ok</strong>
        is <em>done</em>. <strong>secret</strong>
        is <em>concealed</em>. Voice colours <code>--v1</code>…<code>--v8</code>
        are assigned by cast order and must be stable: the same character is the same hue in the
        transcript, the status strip, the cast list, the picker and their sheet.
      </p>

      <h2>If you need a class that isn't here</h2>
      <p>
        It belongs in <code>ux/polyphony-kit.css</code>, not in a screen. That is the whole
        arrangement: the design file changes, the port re-runs, and every screen gets it at once.
      </p>
    </div>
    """
  end
end

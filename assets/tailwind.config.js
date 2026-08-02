// Tailwind configuration. Content globs drive which utilities are generated —
// only classes actually referenced in the templates or JS survive the build.
module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/polyphony_web.ex",
    "../lib/polyphony_web/**/*.*ex",
    // Story files carry markup too — the catalogue's frames and the mock content
    // inside them — so their utilities must survive the build.
    "../storybook/**/*.exs",
  ],
  theme: {
    extend: {},
  },
  plugins: [],
}

// Tailwind configuration. Content globs drive which utilities are generated —
// only classes actually referenced in the templates or JS survive the build.
module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/polyphony_web.ex",
    "../lib/polyphony_web/**/*.*ex",
  ],
  theme: {
    extend: {},
  },
  plugins: [],
}

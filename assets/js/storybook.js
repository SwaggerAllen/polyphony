// Loaded immediately before PhoenixStorybook's own JS. It reads `window.storybook`
// for the LiveView hooks the catalogued components need.
//
// The kit components are server-rendered and hookless — every state they have is
// a class the server sets, which is what makes them reviewable as static
// variations in the first place. When a component does grow a hook, export it
// from assets/js/app.js and register it here so the storybook drives the same
// code the app does.
(function () {
  window.storybook = { Hooks: {}, Params: {}, Uploaders: {} };
})();

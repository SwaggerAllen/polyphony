[
  # phoenix_storybook's DSL reads better paren-free, as its own docs assume.
  import_deps: [:phoenix_storybook],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "storybook/**/*.exs"
  ],
  line_length: 98
]

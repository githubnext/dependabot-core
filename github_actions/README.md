## `dependabot-github_actions`

GitHub Actions support for [`dependabot-core`][core-repo].

### GitHub Agentic Workflows

For [gh aw](https://github.com/github/gh-aw) workflows, Dependabot updates action
references declared in the YAML frontmatter of the source `.md` files, including
local frontmatter imports. It then recompiles affected `.lock.yml` files rather
than editing generated YAML. The selected workflows are compiled with
`gh aw compile --fix`; any compiler migrations to their Markdown are also
included in the update. Workflows are not refreshed from upstream repositories,
and unrelated action references are not deliberately bumped.
The usual `github-actions` configuration applies; no separate ecosystem is needed.
Compiled workflows are identified by their `.lock.yml` filenames and the JSON
`gh-aw-metadata` or `gh-aw-manifest` comments.

The compiler is installed in the updater image as the `gh-aw` GitHub CLI extension,
pinned through `GH_AW_VERSION`. Local imports, `aw.json`, and the action pin cache
are preserved as compilation inputs; updated lockfiles and cache changes are
included in the dependency update. Compilation failures prevent the update from
being returned.

The GitHub CLI is also used to resolve action references outside the compiler's
embedded pin catalog.

Building the updater image requires `GH_TOKEN` so the GitHub CLI can install the
pinned extension. The build passes it as a BuildKit secret; it is not stored in
the image.

Actions inserted by the compiler are not independently updated by Dependabot.
They may change when recompiling with a newer eligible compiler release.

### Running locally

1. Start a development shell

  ```
  $ bin/docker-dev-shell github_actions
  ```

2. Run tests
   ```
   [dependabot-core-dev] ~ $ cd github_actions && rspec
   ```

[core-repo]: https://github.com/dependabot/dependabot-core

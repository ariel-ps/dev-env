# ps-platform

Helpers for the `prompt-security/ps-platform` monorepo CI.

## Provides

| Command | Purpose |
|---|---|
| `ps-build-images` | Dispatch the **"Build and Push Docker Image (monorepo)"** workflow for a branch, watch it, and print the GHCR image names it pushed. |

## `ps-build-images`

The image workflow (`build-push-docker-image-ps-platform.yml`) is
`workflow_dispatch`-only. It builds the **nx-affected** microservices (all
apps except `ps-platform`) and pushes each to:

```
ghcr.io/ps-prod/<service>:<branch>
ghcr.io/ps-customers/<service>:<branch>     # mirror
```

`<branch>` is the branch name with every non-`[alnum_]` character replaced by
`-` (the workflow's own tag sanitizer). For a clean branch like
`PRO-2458-CREATE-NEW-ENDPOINT-CONFIG-AGENT-BLOCK-MODE` the tag is unchanged.

### Usage

```sh
ps-build-images                 # dispatch for the current git branch, watch, list images
ps-build-images my-branch       # dispatch for a specific branch
ps-build-images -n              # dispatch only, don't watch
ps-build-images images          # no dispatch — print images for the latest run of the current branch
ps-build-images images my-branch
```

### Requires

- `gh` CLI, authenticated (`gh auth login`) with access to the repo and GHCR.
- `git` (for the default branch when none is passed).

### Env overrides

- `PS_PLATFORM_REPO` — default `prompt-security/ps-platform`
- `PS_PLATFORM_IMAGE_WORKFLOW` — default `build-push-docker-image-ps-platform.yml`

### Notes

- The wrapper assumes the workflow's **default** tagging (branch name). If you
  dispatch with an `IMAGE_TAG_OVERRIDE` from the Actions UI, the printed tag
  won't match — pass the override-aware name yourself.
- `images` reads the affected-service list from the run's `build-and-push`
  matrix job names, so it only works once the run has expanded those jobs.

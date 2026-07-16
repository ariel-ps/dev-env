# Argo dev-env setup & deploy workflow

How we set up and deploy to Argo dev environments. All helpers live in
`argo.sh` (source it first). GitOps model: **deploy = git push to an env branch
in `ps-argocd-dev-envs`; ArgoCD watches the branch and auto-syncs.**

```bash
source ~/Documents/projects/dev-env/scripts/ps-agent/argo.sh
```

## 1. Session / auth setup

| Command | Does |
| --- | --- |
| `argo_env_start [nonprod]` | AWS SSO login for the profile (reuses valid session), exports `AWS_PROFILE`, prints caller identity |
| `argo_env_stop` | unset `AWS_PROFILE` |
| `argo_npm_login [nonprod]` | `argo_env_start` + `aws codeartifact login --tool npm --domain prompt-security --repository npm-proxy --region eu-north-1` |
| `argo_pip_login [nonprod]` | same for pip / `pypi-proxy` |

Default profile = `nonprod`, region `eu-north-1`.

## 2. Environment lifecycle (GitHub Actions on `ps-argocd-dev-envs`)

| Command | Dispatches |
| --- | --- |
| `argo_create_env [ttl_hours=8] [prompt_version]` | `create_env.yml` (instance_type=spot, gpu=false, shared_gpu=true) |
| `argo_delete_env [additional_setup=false]` | `delete_env.yml` |
| `argo_env_status [limit=1]` | `gh run list` filtered to your GitHub user |

Env name = your dev branch (e.g. `ariel-ps`) → `environments/<branch>/values.yaml`.

## 3. Deploy a new image

**a. Build + push to GHCR** (from `ps-platform`, per service):

```bash
argo_npm_login nonprod
echo "always-auth=true" >> ~/.npmrc
export SERVICE=ps-backend
export TAG="$(git rev-parse --abbrev-ref HEAD | sed 's/[^[:alnum:]_]/-/g')-local-$(date +%Y%m%d%H%M)"
export IMAGE="ghcr.io/ps-prod/$SERVICE:$TAG"
echo "$GHCR_PAT" | docker login ghcr.io -u "$GITHUB_USER" --password-stdin
docker buildx build --platform linux/amd64 \
  -f apps/$SERVICE/Dockerfile --build-arg APP_NAME=$SERVICE \
  --secret id=npmrc,src=<(base64 < ~/.npmrc) \
  --secret id=CHROME_EXTENSION_PEM,src="$CHROME_EXTENSION_PEM_FILE" \
  --secret id=BROWSER_EXTENSION_ACCESS_TOKEN,env=BROWSER_EXTENSION_ACCESS_TOKEN \
  -t "$IMAGE" --push .
```

**b. Point Argo at the tag** = `argo_set`:

```bash
# usage: argo_set <branch/env> <imageTag> <service[:imageName]> [service2 ...]
argo_set ariel-ps PROE-7092-HARDENING-DISABLE-WITH-ROTATION \
  ps-backend ps-backend-protect:ps-backend ps-frontend
argo_set ariel-ps PROE-7092-HARDENING-DISABLE-WITH-ROTATION ps-api-gateway
```

`argo_set`:
- fetches + hard-resets the env branch to origin (CI rewrites env branches, so a
  local copy always diverges) before a surgical text edit of `values.yaml`
- sets `image: { registry, imageTag }` per service
- commits `"<branch>: set image(s) to <tag> [<svc...>]"` and pushes → ArgoCD syncs
- `svc:imageName` when they differ, e.g. `ps-backend-protect` runs the `ps-backend` image
- registry default `ghcr.io/ps-prod/` (override `ARGO_SET_REGISTRY`)
- repo `~/.cache/ps-argocd-dev-envs` (override `PS_ARGOCD_REPO`)
- `ARGO_SET_DRY=1` → edit + show diff, no commit/push

## Clusters (don't confuse)

- `k3d-ps-dev-cluster` — **local** k3d cluster, runs on Docker Desktop. Start:
  `open -a Docker` then `k3d cluster start ps-dev-cluster`. API via k3d LB on
  localhost; `Bad Gateway` there = Docker daemon down.
- `arn:aws:eks:eu-north-1:...:cluster/prompt-dev` — **remote** EKS (namespace
  `dev-ariel-ps`); DeveloperAccess SSO role, node/argocd list is Forbidden.

# Petasus fork of goauthentik/helm

This repository is [goauthentik/helm](https://github.com/goauthentik/helm) with the changes
the Petasus hub needs. The hub installs `charts/authentik`; `charts/authentik-remote-cluster`
is upstream's and unchanged.

Our changes are always the difference to the upstream release a branch is based on:

```sh
git diff authentik-2025.8.4 release-2025.8 -- charts/authentik
```

| Area | Files |
|---|---|
| Secret key: generated on first install, kept on upgrades | `templates/secret.yaml` |
| Hub defaults: bundled PostgreSQL and Redis from `quay.io/edgestack`, init containers that wait for them, `/dev/shm`, authentik under `/auth/`, console password policy | `values.yaml`, `templates/petasus-password-policy.yaml` |
| Blueprint (brand, accounts, OIDC provider for KubeSphere, flows) and login page | `templates/ak-blueprints-configmap.yaml`, `petasus-login.css`, `authentik.css`, `petasus_user_settings.py`, `templates/server/deployment.yaml` |
| Gateway API: bundled NGINX Gateway Fabric, HTTPS listener on the console NodePort, self-signed certificate from cert-manager, console route | `Chart.yaml`, `values.yaml`, `templates/petasus-*.yaml`, `templates/server/route.yaml`, `templates/server/ingress.yaml` |
| CI | `.github/workflows/petasus-chart.yaml` (upstream's chart-releaser workflows are removed) |

`petasus/scripts` holds one-off operator scripts (KubeSphere users to authentik, bulk
deletion of local users); they are not part of the chart.

## Branches and versions

| Ref | What |
|---|---|
| `main` | The newest upstream release we follow, with our changes. A push publishes `0.0.0-dev` to the dev channel of [edgestack-helm](https://github.com/petasus-ai/edgestack-helm). |
| `release-<YYYY.M>` | One per upstream minor (`release-2025.8` = upstream `authentik-2025.8.x`). Releases are tagged here. |
| tag `v<upstream>-petasus.N` | A release: `v2025.8.4-petasus.1` publishes chart `2025.8.4-petasus.1` to the stable channel once, and never again with other contents. N counts our releases on the same upstream version. |
| `gatewayapi` | The old copy of the chart, published as `2025.8.4` over and over. Frozen. |

`Chart.yaml` keeps upstream's `version` and `appVersion`; CI stamps the release version
when it packages the chart and keeps `appVersion`, the authentik release the images
default to. The tag must be based on the chart's upstream version or CI refuses it.

## Following upstream

Merge, never rebase: release branches are protected from force-pushes.

```sh
git fetch upstream --tags
git switch main
git merge authentik-<new version>      # resolve, mostly values.yaml and the deployments
```

- A new patch of the same minor: merge it into `release-<YYYY.M>` as well and tag
  `v<new version>-petasus.1`.
- A new minor: create `release-<YYYY.M>` from `main` once it is tested.

authentik does not support skipping releases: an installation moves through every
upstream minor in turn (the latest patch of each), and cannot be downgraded. Back up the
database first. A site that is several minors behind needs each step published.

## Releasing

1. Test the chart on a hub (the dev channel, or a local package).
2. `git tag v<upstream>-petasus.N` on `release-<YYYY.M>` and push the tag.
3. Point edgespray's `versions.yml` (`authentik_helm_version`, and `authentik_version` for
   the images it preloads) at the new release.

# GitHub Actions runners on AKS

Self-hosted GitHub Actions runners on Azure Kubernetes Service, using Actions Runner Controller (ARC) runner scale sets.

Design goals:

- Isolation between GitHub orgs
- Lowest possible spend when idle (runner pods and runner nodes scale to zero)
- A golden runner image with a defined lifecycle for the image and the node OS

## Contents

| Path | What it is |
| --- | --- |
| [`docs/high-level-design.md`](docs/high-level-design.md) | High-level design: architecture, isolation model, cost, image and OS lifecycle, security, operations, open decisions and rollout |
| [`docs/images/architecture.svg`](docs/images/architecture.svg) | Architecture diagram |
| [`docs/poc-setup.md`](docs/poc-setup.md) | Step-by-step repository-scoped AKS/ARC PoC setup and teardown |
| [`docs/poc-deployment.md`](docs/poc-deployment.md) | Deployment observations and live-test results |
| [`poc/`](poc/) | Provisioning scripts, pinned ARC values, job-pod template and GitHub App registration helper |
| [`.github/workflows/poc-runner-smoke.yml`](.github/workflows/poc-runner-smoke.yml) | Manually triggered self-hosted runner smoke test |

## Status

PoC implementation in progress. The first experiment uses one shared development
node because the Azure subscription's East US vCPU quota is 4. It tests
repository-scoped GitHub App authentication, ephemeral ARC runners and runner-pod
scale-to-zero. Dedicated runner-node scale-to-zero and the production image
pipeline remain follow-up work. See the setup guide and deployment record above.

# GitHub Actions runners on AKS

Self-hosted GitHub Actions runners on Azure Kubernetes Service, using Actions Runner Controller (ARC) runner scale sets.

Design goals:

- Isolation between GitHub orgs
- Lowest possible spend when idle (runner pods and runner nodes scale to zero)
- A golden runner image with a defined lifecycle for the image and the node OS

## Contents

| Path | What it is |
| --- | --- |
| [`docs/high-level-design.md`](docs/high-level-design.md) | High-level design: architecture, prod and nonprod, isolation model, cost, node storage, image and OS lifecycle, deployment with GitOps (Argo CD), security design and threat model, logging and audit, disaster recovery, monitoring and operations, open decisions and rollout |
| [`docs/images/architecture.png`](docs/images/architecture.png) ([`.drawio`](docs/images/architecture.drawio)) | Platform architecture diagram |
| [`docs/images/logging.png`](docs/images/logging.png) ([`.drawio`](docs/images/logging.drawio)) | Logging and audit pipeline diagram |
| [`docs/poc-setup.md`](docs/poc-setup.md) | Step-by-step repository-scoped AKS/ARC PoC setup and teardown |
| [`docs/poc-deployment.md`](docs/poc-deployment.md) | Deployment observations and live-test results |
| [`docs/keyvault-credentials.md`](docs/keyvault-credentials.md) | Key Vault, workload identity, credential synchronization and recovery |
| [`poc/terraform/`](poc/terraform/) | Azure infrastructure and Terraform-managed Kubernetes resources / Helm releases |
| [`poc/`](poc/) | Pinned Helm values, job-pod template, GitHub App manifest and registration helper |
| [`.github/workflows/poc-runner-smoke.yml`](.github/workflows/poc-runner-smoke.yml) | Manually triggered self-hosted runner smoke test |

## Status

PoC implementation in progress. The first experiment uses one shared development
node because the Azure subscription's East US vCPU quota is 4. It tests
repository-scoped GitHub App authentication, ephemeral ARC runners and runner-pod
scale-to-zero. Dedicated runner-node scale-to-zero and the production image
pipeline remain follow-up work. See the setup guide and deployment record above.

All Azure and Kubernetes infrastructure is declared in Terraform. ARC is installed
through Terraform-managed Helm releases. Existing PoC resources are adopted by
Terraform imports; lifecycle changes use `terraform plan`, `apply`, and `destroy`.

The production design is different: Terraform builds the Azure side and bootstraps
Argo CD, and Argo CD deploys everything inside the clusters from Git. No one runs
`kubectl apply`. See the design's GitOps section.

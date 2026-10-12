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

## Status

Design phase. Infrastructure as code, Helm values and the image pipeline will follow the open decisions in the design.

# GitHub Runners on AKS — High-Level Design

_As of Oct 12, 2026_

## Summary

Run GitHub's Actions Runner Controller (ARC 0.15) on a dedicated, private AKS cluster, with a GitHub App, namespace and tainted node pool per org. Runner pods and runner nodes scale to zero when no jobs are queued. A signed runner image is rebuilt at least weekly and runs on AKS-managed Azure Linux 3 nodes.

| Requirement | How the design meets it |
| --- | --- |
| Isolation between GitHub orgs | Per org: GitHub App, runner scale sets, namespace, secrets, network policy and node pool. Jobs from two orgs never share a node. Docker jobs also run in their own Kata pod VM. |
| Lowest spend when idle | `minRunners: 0` on every scale set; runner nodes are created on demand and removed when empty. Idle spend is a fixed floor: control plane, a small system pool, egress, registry and logs. |
| Golden image with OS lifecycle | Two layers, two owners. AKS patches the node OS weekly in a maintenance window. The platform team builds, scans, signs and promotes the runner pod image weekly and on every runner release. |

**Assumptions to confirm**

- GitHub Enterprise Cloud, with several orgs under one enterprise.
- Linux x64 jobs only in phase 1; Windows and Arm later, if at all.
- The cluster hosts CI runners only, no production workloads, as [GitHub recommends](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets).
- Some jobs build container images, so a Docker-capable tier is needed.

## Architecture at a glance

![Each org runs on its own nodes, and idle runner capacity is zero](images/architecture.svg)

Each scale set's listener waits for jobs from the system pool; when a job is assigned, ARC creates a runner pod in that org's namespace, and NAP adds a node to that org's pool only if none has room.

## Runner orchestration with ARC

ARC runner scale sets (the GitHub-supported mode) run ephemeral runners: every job gets a fresh pod that is deleted when the job ends. The current release, 0.15.0 (Oct 1, 2026), adds in-place patch upgrades and controller tuning for clusters with many scale sets ([changelog](https://github.blog/changelog/2026-10-01-actions-runner-controller-release-0-15-0/)).

- **One controller, many scale sets.** The controller runs in `arc-system` on the system pool. Each org's scale sets install into that org's own namespace, as [GitHub recommends](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets).
- **Org-level registration.** Each scale set registers to `https://github.com/<org>` with that org's GitHub App. Enterprise-level scale sets would need a classic PAT, so the design avoids them ([docs](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets)).
- **Scale sets per org:** `<org>-linux` (default), `<org>-docker` (opt-in, Kata) and `<org>-spot` (retry-tolerant jobs). Since ARC 0.14 one scale set can carry several labels, so workflows target combinations without a scale set for each ([changelog](https://github.blog/changelog/2026-03-19-actions-runner-controller-release-0-14-0/)).

| Container mode | Privileged | What jobs can do | Use it for |
| --- | --- | --- | --- |
| `kubernetes-novolume` (default) | No | Container jobs, service containers and container actions, each run as its own pod by runner container hooks; no shared RWX volume needed | Most build and test jobs |
| `kubernetes` | No | Same, with a persistent volume per runner | Only if jobs need concurrent writes to a shared workspace |
| `dind` | Yes, the Docker sidecar | Full Docker, including `docker build` | Image builds, on Kata-sandboxed nodes only |

Keep `ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER` at its default in the Kubernetes modes. Turning it off runs job steps in the runner pod, which can create pods and read secrets through the API server ([docs](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets)). Moving image builds to ACR Tasks is an alternative that removes Docker from runners entirely.

## Isolation between orgs

Each org gets its own GitHub credentials, namespace, network boundary and VMs; Docker jobs also get their own guest kernel. GitHub's baseline is a namespace per org and a GitHub App per scale set ([docs](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets)); this design adds node and network separation on top.

| Layer | Control | Prevents |
| --- | --- | --- |
| GitHub | One GitHub App per org, installed on that org only. Scale sets sit in a runner group limited to selected repos; public repos can't use them. | Jobs from org A landing on org B's runners; one credential working across orgs |
| Kubernetes | Namespace per org. GitHub App key synced from that org's Key Vault into its namespace only. Namespace-scoped RBAC, ResourceQuota and LimitRange. Pod Security `restricted`, except the Docker scale set. | Reading another org's secrets; one org starving the others |
| Network | Cilium policy: default deny, no cross-namespace traffic. Job pods can't reach the API server or the instance metadata endpoint (169.254.169.254). Egress only through the firewall allowlist. | Lateral movement; stealing a node's managed identity token |
| Node | A node pool per org, tainted `gh-org=<org>:NoSchedule`. The runner template and the [job-pod hook extension](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets) carry the matching toleration and node affinity. | Two orgs' jobs sharing a kernel, disk or image cache |
| Sandbox | The `dind` scale set uses `runtimeClassName: kata-vm-isolation`, so each job runs in its own lightweight VM. | A privileged container escape reaching the node |

Pick an isolation tier per org:

| Tier | Boundary | Extra idle cost | When |
| --- | --- | --- | --- |
| A. Namespace only, shared nodes | Shared kernel | None | Not recommended between orgs |
| B. Node pool per org (default) | Separate VMs per org | None: pools scale to zero | Every org |
| C. B plus Kata for Docker jobs | Separate guest kernel per job | None when idle; each pod's CPU rounds up to whole vCPUs | Orgs that build images or run untrusted code |
| D. Cluster per org | Separate control plane, network and identities | One control plane, system pool and egress path per org | Regulated or contractually separated orgs only |

Kata limits to plan for: Azure Linux node pools only, a Gen2 VM size with nested virtualization, and no Defender for Containers assessment of Kata pods ([docs](https://learn.microsoft.com/en-us/azure/aks/use-pod-sandboxing)).

## Cost when idle

With no queued jobs, no runner pods and no runner nodes exist; spend falls to the fixed floor in the table below.

- **Pods:** `minRunners: 0` on every scale set, so ARC scales to zero when no jobs are assigned ([docs](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets)). `maxRunners` caps burst spend per scale set.
- **Nodes:** one node auto-provisioning (NAP, managed Karpenter) `NodePool` per org, consolidating empty nodes after a short `consolidateAfter` delay. `limits.cpu` on each NodePool is a hard ceiling per org ([docs](https://learn.microsoft.com/en-us/azure/aks/use-node-auto-provisioning)). Kata pools use classic node pools with cluster autoscaler minimum 0.
- **VM size:** NAP picks the VM from pending pod requests ([docs](https://learn.microsoft.com/en-us/azure/aks/node-auto-provisioning)), within an allowlist of general-purpose families. Right-sized runner requests let jobs pack well.
- **Spot:** the `<org>-spot` scale set runs on spot capacity for retry-tolerant jobs. The default stays on demand, because an eviction kills the running job.
- **Warm runners:** ARC has no scheduled min/max ([docs](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets)). Where cold start hurts, a CronJob raises `minRunners` in business hours only.
- **No cluster stop:** NAP clusters can't be stopped ([docs](https://learn.microsoft.com/en-us/azure/aks/node-auto-provisioning)), so scale-to-zero replaces any plan to stop the cluster at night.

| Always-on component | Why | How to keep it small |
| --- | --- | --- |
| AKS control plane | Cluster API | Standard tier in prod for the SLA; Free tier in dev |
| System node pool | ARC controller, one listener per scale set, CoreDNS, Cilium | Two small nodes; tight requests on listeners |
| Egress | Outbound control to GitHub and registries | Reuse a hub Azure Firewall if one exists; NAT gateway in dev |
| ACR, Key Vault, Log Analytics | Images, GitHub App keys, logs | Short retention on runner logs; purge old images |

The trade-off is cold start: the first job after idle waits for a node to boot and the image to pull. Track it with `gha_job_startup_duration_seconds` and keep the runner image slim. Showback per org comes from namespace labels in AKS cost analysis.

## Golden image and OS lifecycle

Two images, two owners: AKS patches the node OS weekly; the platform team owns the runner pod image and rebuilds it weekly and on every runner release.

### Node OS (owned by AKS)

- **OS:** Azure Linux 3 on every pool; Kata requires Azure Linux. Azure Linux 2.0 node images are removed on Oct 31, 2026, after which those pools can't scale ([docs](https://learn.microsoft.com/en-us/azure/aks/auto-upgrade-node-os-image)).
- **Channel:** node OS auto-upgrade `NodeImage`, a weekly VHD with security and bug fixes, in an `aksManagedNodeOSUpgradeSchedule` window of 4 hours or more ([docs](https://learn.microsoft.com/en-us/azure/aks/auto-upgrade-node-os-image)). Kubernetes patch versions follow the cluster auto-upgrade channel in its own `aksManagedAutoUpgradeSchedule` window.
- **SecurityPatch** ships CVE fixes faster but carries no bug fixes and conflicts with a deny-effect CMK disk policy. Revisit it if the CVE SLA demands faster patching.
- **No interrupted jobs:** on NAP pools, runner pods carry `karpenter.sh/do-not-disrupt`, so consolidation and image drift wait for the job to finish. On classic Kata pools, set the OS window outside peak CI hours.

### Runner pod image (owned by the platform team)

1. **Base:** `ghcr.io/actions/actions-runner`, pinned by digest.
2. **Platform layer:** corporate CA certs, proxy settings, the hook extension template and a few common CLIs. Toolchains stay out; jobs bring them in their job container.
3. **Org overlay (optional):** built `FROM` the platform image, owned by the org, built by the same pipeline.

The image pipeline:

1. **Trigger:** a new runner release, a base-image digest change, the weekly schedule, or a critical CVE.
2. **Build** in a platform repo, on a platform-only scale set.
3. **Scan** with Trivy or Defender; fail on critical or high findings that have a fix.
4. **Sign and push:** SBOM, signature (Notation or cosign) and an immutable tag `<runner-version>-<yyyymmdd>` in ACR; record the digest.
5. **Canary:** roll to the platform scale set and smoke-test a container job, a service container and a Kata Docker build.
6. **Promote by ring:** a PR bumps the digest in Helm values; GitOps rolls out platform → pilot org → all orgs.
7. **Enforce:** admission policy admits only signed images from the platform ACR in runner namespaces.
8. **Retire:** keep the last 3 versions for rollback; ACR purge removes older ones.

Rollback is a revert of the digest PR: new pods start on the previous image, with no node changes.

**Runner version guardrail:** since Sep 29, 2026, GitHub Enterprise Cloud blocks runners below 2.329.0 from registering, and runners below a higher execution minimum stop running jobs ([changelog](https://github.blog/changelog/2026-09-28-self-hosted-runner-version-enforcement-date-has-moved/)). Treat every runner release as a mandatory rebuild, and alert from GitHub's runner version deprecation API.

## Security, networking and secrets

The cluster is private and outbound-only, no credential is shared between orgs, and jobs reach Azure through GitHub OIDC rather than node identity.

- **Cluster:** private API server, Entra ID authentication with Azure RBAC, Azure CNI Overlay with the Cilium dataplane and network policy ([docs](https://learn.microsoft.com/en-us/azure/aks/use-node-auto-provisioning)).
- **Egress:** a UDR sends all outbound traffic to Azure Firewall, with an FQDN allowlist for GitHub's self-hosted runner endpoints, ACR and package mirrors. Per-org additions go in by PR.
- **GitHub App keys:** one Key Vault per org, synced into that org's namespace by the Secrets Store CSI driver or External Secrets, using that org's workload identity. Keys are referenced as Kubernetes secrets, never passed on the command line ([docs](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets)), and rotated on a fixed schedule.
- **Deployments from jobs:** GitHub OIDC federated credentials per repo or environment. Runner pods get no Azure identity by default.
- **Supply chain:** ACR behind a private endpoint, anonymous pull off, signed images only.
- **Runtime:** Defender for Containers on runc nodes. It doesn't assess Kata pods ([docs](https://learn.microsoft.com/en-us/azure/aks/use-pod-sandboxing)), so Kata pools rely on the VM boundary plus audit logs.
- **GitHub settings:** fork pull requests need approval before running, and self-hosted runner groups exclude public repos.

## Observability and operations

The platform is judged on three numbers: time for a job to start, failed runners, and idle spend per org.

- **Metrics:** enable ARC metrics on the controller and listeners, scraped into Azure Managed Prometheus with Grafana. Key series: `gha_job_startup_duration_seconds`, `gha_assigned_jobs` against `gha_desired_runners`, and `gha_controller_failed_ephemeral_runners` ([docs](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets)).
- **Logs:** controller, listener and runner logs go to Log Analytics with a retention policy, as GitHub advises. NAP events come from the `karpenter-events` control plane log category ([docs](https://learn.microsoft.com/en-us/azure/aks/use-node-auto-provisioning)).

Starting alerts, to tune after a month of baseline:

| Signal | Alert when | First response |
| --- | --- | --- |
| Job start time, p95 | Above the agreed target for 15 min | Check node provisioning and image pull |
| Failed ephemeral runners | Non-zero for 15 min | Check image, GitHub App key, quota |
| Runner version | Within 30 days of a GitHub deprecation date | Rebuild and promote the image |
| NodePool CPU | Above 80% of `limits.cpu` | Confirm the demand, then raise the cap |
| Idle spend | Floor above budget | Review system pool size and listener count |

Day-2 operations:

- **Onboard an org:** one PR from a template: namespace, quota, network policy, NodePool, Key Vault secret reference and scale sets.
- **Drain the queue:** set `minRunners` and `maxRunners` to 0 ([docs](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets)).
- **ARC upgrades:** patch upgrades now update in place ([0.15](https://github.blog/changelog/2026-10-01-actions-runner-controller-release-0-15-0/)). Upgrades with CRD changes need scale sets uninstalled and ARC reinstalled ([docs](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets)), so run them in a window, or use two clusters with separate runner groups for zero downtime.
- **Infrastructure as code:** Terraform for Azure and Kubernetes resources, with Terraform-managed Helm releases for ARC and scale sets. The PoC implementation is in `poc/terraform/`; any later GitOps migration must explicitly transfer resource ownership.

## Open decisions and rollout

Eight decisions shape the build; the recommendation column is the default if no other input arrives.

| Decision | Options | Recommendation |
| --- | --- | --- |
| GitHub product and org list | GHEC or GHES; which orgs | Confirm; design assumes GHEC |
| Docker in jobs | None; `dind` on Kata; builds moved to ACR Tasks | Kata `dind` tier only for orgs that need it |
| Isolation tier per org | B, C or D | B for all, C where Docker is needed, D only if mandated |
| Cold-start tolerance | Accept; business-hours warm runners | Measure in the pilot, then decide per org |
| Spot capacity | Off; opt-in scale set | Opt-in scale set |
| Node scaling | NAP; classic autoscaled pools | NAP for runc pools; spike to confirm it coexists with autoscaled Kata pools, else classic pools everywhere |
| Egress | Hub Azure Firewall; NAT gateway | Hub firewall if one exists |
| Windows or Arm runners | Now; later; never | Later; NAP doesn't support Windows pools ([docs](https://learn.microsoft.com/en-us/azure/aks/node-auto-provisioning)) |

Rollout:

1. **Foundation:** cluster, network, ACR, Key Vault, ARC controller, platform scale set and image pipeline. Exit: the pipeline builds the golden image on its own runners.
2. **Pilot org:** `kubernetes-novolume` scale set, NodePool, quotas and metrics. Exit: job start time measured, and idle spend equals the floor.
3. **Docker tier:** Kata pool and `dind` scale set, plus a security review. Exit: `docker build` works in the sandbox and a container-escape test fails.
4. **Remaining orgs:** onboarded by template PR, with showback by namespace.
5. **Hardening:** signed-image enforcement on, alerts tuned, and a second cluster if zero-downtime upgrades are required.

## Sources

- [Actions Runner Controller release 0.15.0](https://github.blog/changelog/2026-10-01-actions-runner-controller-release-0-15-0/) (GitHub changelog, Oct 1, 2026)
- [Actions Runner Controller release 0.14.0](https://github.blog/changelog/2026-03-19-actions-runner-controller-release-0-14-0/) (GitHub changelog, Mar 19, 2026)
- [Deploying runner scale sets with Actions Runner Controller](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets) (GitHub Docs)
- [Self-hosted runner version enforcement date has moved](https://github.blog/changelog/2026-09-28-self-hosted-runner-version-enforcement-date-has-moved/) (GitHub changelog, Sep 28, 2026)
- [Overview of node auto-provisioning in AKS](https://learn.microsoft.com/en-us/azure/aks/node-auto-provisioning) (Microsoft Learn)
- [Enable or disable node auto-provisioning in AKS](https://learn.microsoft.com/en-us/azure/aks/use-node-auto-provisioning) (Microsoft Learn)
- [Autoupgrade node OS images in AKS](https://learn.microsoft.com/en-us/azure/aks/auto-upgrade-node-os-image) (Microsoft Learn)
- [Pod sandboxing with AKS](https://learn.microsoft.com/en-us/azure/aks/use-pod-sandboxing) (Microsoft Learn)

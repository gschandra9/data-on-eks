# Updates on branch `data-on-eks-fs`

Changes made so the `spark-on-eks` stack can deploy into an existing VPC that has no direct internet
access (egress only through a proxy). Each bullet is one change: what it was before, what it is now,
and the files it touches. A masked sample config is in `data-stacks/spark-on-eks/vpc.json`.

## A. Existing-VPC support (commits `ff124049` and `ea819773`; item 3 partly reverted later)

1. Deploy into a new OR an existing VPC, selected by `--vpc-mode create|existing` and a `--vpc-config` JSON file.
   - Before: the stack always created its own VPC.
   - After: existing mode looks up a VPC and subnets by ID/name and deploys into them.
   - Files: `data-stacks/spark-on-eks/deploy.sh`, `data-stacks/spark-on-eks/terraform/vpc.tf`,
     `data-stacks/spark-on-eks/terraform/vpc-variables.tf`, `data-stacks/spark-on-eks/terraform/modules/vpc/{main,outputs,variables}.tf`,
     `infra/terraform/{vpc,eks,main,karpenter,outputs}.tf`, `infra/terraform/manifests/karpenter/ec2nodeclass.yaml`

2. Name every resource with a configurable prefix (default `fs-`), so the cluster is `<prefix>spark-on-eks`.
   - Before: fixed resource names.
   - After: `--prefix` on `deploy.sh` flows into `var.name`.
   - Files: `data-stacks/spark-on-eks/deploy.sh`

3. Helper scripts `create-vpc.sh` / `delete-vpc.sh` (create and tear down a sample VPC for testing existing mode).
   - Added in `ff124049`, later **removed from the repository** (kept locally only, git-ignored). Existing mode works with
     any VPC described in the `--vpc-config` file; see the masked sample `data-stacks/spark-on-eks/vpc.json`.
   - Files: `data-stacks/spark-on-eks/create-vpc.sh` (removed), `data-stacks/spark-on-eks/delete-vpc.sh` (removed),
     `.gitignore`

## B. Deploy into an existing VPC without direct internet access (commit `baa4a4a6`)

4. Allow `node_subnets` to overlap `private_subnets`.
   - Before: `deploy.sh` rejected a subnet ID listed in more than one of the public/private/node lists, so the
     private subnets could not also host the nodes.
   - After: only duplicates inside one list, and public subnets reused as private/node subnets, are rejected.
   - Files: `data-stacks/spark-on-eks/deploy.sh`

5. Create interface VPC endpoints for nodes that have no NAT/internet route.
   - Before: only S3 and S3 Express endpoints; nodes could not reach EC2/ECR/STS/EKS and failed to join
     (`NodeCreationFailure`).
   - After: `create_interface_endpoints` (`false` / `"auto"` / `true`); `auto` creates only the missing ones of
     ec2, ecr.api, ecr.dkr, sts, eks, eks-auth, logs, sqs, ssm, elasticloadbalancing in the node subnets, with a
     security group. The core node group and Karpenter wait for them.
   - Files: `data-stacks/spark-on-eks/deploy.sh`, `data-stacks/spark-on-eks/terraform/vpc.tf`,
     `data-stacks/spark-on-eks/terraform/vpc-variables.tf`

6. Tag this deployment's VPC endpoints so they are recognized as its own.
   - Before: the marker tag `Name=<name>-vpc-endpoints` was overwritten by the endpoints module, so `deploy.sh`
     mistook its own endpoints for pre-existing ones and `cleanup.sh` could not find them.
   - After: endpoints carry `data-on-eks:deployment=<name>`, used by `deploy.sh` and `cleanup.sh`.
   - Files: `data-stacks/spark-on-eks/terraform/vpc.tf`, `data-stacks/spark-on-eks/deploy.sh`,
     `data-stacks/spark-on-eks/cleanup.sh`

7. Add the ECR image-layer bucket to the existing S3 endpoint policy.
   - Before: the VPC's S3 gateway endpoint allowed only SSM/patch buckets, so ECR layer pulls returned 403 and the
     CNI could not start (nodes `NotReady`).
   - After: with `update_s3_endpoint_policy: true`, Terraform keeps the existing statements and adds one for
     `prod-<region>-starport-layer-bucket`. `cleanup.sh` resets that policy to the AWS default.
   - Files: `data-stacks/spark-on-eks/deploy.sh`, `data-stacks/spark-on-eks/terraform/vpc.tf`,
     `data-stacks/spark-on-eks/terraform/vpc-variables.tf`

8. Route node (containerd/kubelet) internet traffic through an HTTP proxy.
   - Before: nodes could not reach public registries (`public.ecr.aws`, `quay.io`, ...).
   - After: `node_http_proxy` in the config; when set, systemd proxy drop-ins are added to the core node group and
     all 8 Karpenter EC2NodeClasses via user data, with a `NO_PROXY` list that keeps cluster/VPC/endpoint traffic
     direct. When unset, nothing changes.
   - Files: `infra/terraform/node-proxy.tf`, `infra/terraform/variables.tf`, `infra/terraform/main.tf`,
     `infra/terraform/karpenter.tf`, `infra/terraform/manifests/karpenter/ec2nodeclass.yaml`,
     `data-stacks/spark-on-eks/deploy.sh`

9. Give the proxy to the pods that need the internet (pods do not inherit the node proxy).
   - Before: the Karpenter controller (IAM), the Argo CD repo-server (Git/Helm) and Grafana (dashboard/plugin
     downloads) had no internet path.
   - After: when `node_http_proxy` is set, these get `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`; Grafana's `NO_PROXY`
     also covers its in-cluster data sources.
   - Files: `infra/terraform/karpenter.tf`, `infra/terraform/eks.tf`, `infra/terraform/kube-prometheus-stack.tf`,
     `infra/terraform/node-proxy.tf`

10. Upgrade Karpenter from 1.9.0 to 1.15.3.
    - Before: 1.9.0 is incompatible with Kubernetes 1.37 (the default) and logged a version error.
    - After: chart 1.15.3, the line that supports 1.37.
    - Files: `infra/terraform/karpenter.tf`

11. Give the ingress-nginx internal NLB explicit subnets in existing-VPC mode.
    - Before: the load balancer controller looked for subnets tagged `kubernetes.io/role/internal-elb`; the
      existing VPC's subnets are untagged, so the NLB was never created.
    - After: the Service gets `aws-load-balancer-subnets` set to the private subnets; the VPC is not modified.
    - Files: `infra/terraform/vpc.tf`, `infra/terraform/ingress-nginx.tf`,
      `infra/terraform/helm-values/ingress-nginx.yaml`, `data-stacks/spark-on-eks/terraform/vpc.tf`

12. Point the Spark History Server at the regional S3 endpoint.
    - Before: S3A had no region set, so it used the global `s3.amazonaws.com`, which pods in this VPC cannot reach;
      the server timed out and restarted.
    - After: `spark.hadoop.fs.s3a.endpoint.region=<region>` in its Spark config.
    - Files: `infra/terraform/spark-history-server.tf`, `infra/terraform/helm-values/spark-history-server.yaml`

13. Make Argo CD compare the Spark History Server StatefulSet with server-side diff.
    - Before: Kubernetes 1.37 StatefulSet defaults kept the application `OutOfSync` (cosmetic) despite nothing
      really differing; two client-side ignore rules were not enough.
    - After: the application uses `ServerSideDiff=true` (the API server computes the diff with its own defaults);
      the ignore rules are kept for other StatefulSets.
    - Files: `infra/terraform/argocd-applications/spark-history-server.yaml`, `infra/terraform/helm-values/argocd.yaml`

14. Create an S3 bucket for TPC-DS benchmark data, kept across cleanups.
    - Before: no benchmark-data bucket; the stack's other buckets are force-destroyed with their data on cleanup.
    - After: `<prefix>spark-benchmarks-tpcds-data-<region>-<account id>`, encrypted, public access blocked, with
      read/write access for the Spark team roles. `cleanup.sh` keeps it when it holds data (unless confirmed or
      `--delete-tpcds-data`); the next `deploy.sh` adopts the kept bucket.
    - Files: `data-stacks/spark-on-eks/terraform/tpcds-data-bucket.tf`, `data-stacks/spark-on-eks/deploy.sh`,
      `data-stacks/spark-on-eks/cleanup.sh`

15. Add a preflight check to `deploy.sh` for a fresh deployment.
    - Before: a deploy with empty state ran into "already exists" errors when an earlier run left resources behind.
    - After: it stops if it finds a cluster, Karpenter role, log group, endpoints or instances with the same name,
      and tells you to run `cleanup.sh` (`--force` skips the check); it also requires working AWS credentials.
    - Files: `data-stacks/spark-on-eks/deploy.sh`

16. Rewrite `cleanup.sh` to be robust and never touch the existing VPC.
    - Before: a thin wrapper around the shared destroy script; it stopped on the first error and left resources
      behind.
    - After: its own three-phase `terraform destroy` with retries and error-specific handling; works when the
      cluster is gone or `kubectl` is unauthorized; AWS CLI fallback for the cluster; tag-scoped sweep of leftovers;
      `--dry-run`, `--yes`, a per-run log; a guard that refuses any AWS call that would change VPC networking.
    - Files: `data-stacks/spark-on-eks/cleanup.sh`

17. Wrap `cleanup.sh` and `deploy.sh` in a single `{ ... exit; }` block.
    - Before: editing a script while it ran could break the run (bash reads scripts incrementally); this happened
      once during this work.
    - After: bash reads the whole file before running it.
    - Files: `data-stacks/spark-on-eks/cleanup.sh`, `data-stacks/spark-on-eks/deploy.sh`

18. Add a deployment verification helper.
    - Before: no single check for the deployed cluster.
    - After: `check-deployment.sh` prints nodes, namespaces and Argo CD application status.
    - Files: `data-stacks/spark-on-eks/check-deployment.sh`

## Notes

- `data-stacks/spark-on-eks/vpc.json` is a masked sample (example IDs). Keep the real config under another `vpc*.json` name in the
  same folder (for example `vpc-fs.json`): those are git-ignored because they contain account-specific IDs. Deploy with
  `./deploy.sh --prefix fs- --vpc-mode existing --vpc-config vpc-fs.json`.
- Local-only files kept out of git: `data-stacks/spark-on-eks/instructions.md` (detailed working log with real IDs),
  `cleanup-*.log`, `state-backup-*`.
- All proxy/endpoint/subnet behaviour activates only when the corresponding config value is set, so these changes are
  no-ops for deployments that have direct internet access.

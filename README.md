# k8s-supply-chain-lab

A container image supply chain you can run end to end on a laptop in about four
minutes — build, scan, sign, and then an admission controller that refuses
anything unsigned.

Most writing about software supply chain security stops at "and then you sign
the image." This repo runs the part after that: a cluster that actually
verifies the signature at admission time and rejects the pod when verification
fails. Two commands prove both directions.

```bash
make demo        # signed image → admitted, running
make demo-fail   # unsigned image → rejected by the cluster, with the reason
```

---

## The chain

```
   source
     │
     ├─► docker build ──────────────► image
     │                                  │
     │   ┌──────────────────────────────┤
     │   │                              │
     │   ▼                              ▼
     │  trivy scan                   SBOM (CycloneDX)
     │  HIGH/CRITICAL → fail         attached to the image
     │   │
     │   ▼
     │  cosign sign (by digest, not tag)
     │   │
     │   ▼
     │  registry: image + signature + sbom
     │                   │
     └───────────────────┤
                         ▼
              ┌──────────────────────┐
              │  Kyverno admission   │   ← the gate that matters
              │  verifyImages        │
              │  + non-root          │
              │  + resource limits   │
              │  + no :latest        │
              └──────────┬───────────┘
                    ┌────┴────┐
                 admit      deny
                    │          │
                    ▼          ▼
                 running   never scheduled
```

The ordering is deliberate. Scanning comes before signing, because signing a
vulnerable image only gets you a cryptographically verified vulnerable image.
Signing targets the digest rather than the tag, because a tag can be moved
after it has been verified and a digest cannot.

---

## Why admission, not just pipeline

A pipeline check is a check the pipeline can skip. Anyone with cluster access
and a `kubectl apply` bypasses it entirely, and so does every emergency
hotfix at 2am.

Putting verification in the admission controller changes the question from
"did the pipeline do its job?" to "can this cluster run an image it cannot
verify?" — and the answer becomes no, structurally, for every path into the
cluster.

That is the single idea this repo exists to demonstrate.

---

## Quickstart

Requirements: `docker`, `kind`, `kubectl`, `cosign`, `trivy`.
`make preflight` tells you which ones are missing.

```bash
git clone https://github.com/Raju089-ui/k8s-supply-chain-lab
cd k8s-supply-chain-lab

make demo
```

That will:

1. create a throwaway kind cluster with a local registry
2. install Kyverno and the four policies
3. build the image and push it
4. scan it with Trivy, failing on fixable HIGH/CRITICAL findings
5. generate a CycloneDX SBOM
6. generate a cosign keypair and sign the image
7. verify the signature locally
8. deploy — and watch the admission controller verify it independently

Then prove the gate actually holds:

```bash
make demo-fail
```

An unsigned image is built, pushed, and rejected. The denial message from
Kyverno is printed verbatim, which is the output worth screenshotting:

```
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Deployment/demo/supply-chain-demo-unsigned was blocked due to the
following policies

verify-image-signature:
  require-cosign-signature: 'failed to verify image
    localhost:5001/supply-chain-demo:unsigned: .attestors[0].entries[0].keys:
    no signatures found'
```

Clean up with `make clean` — kind cluster and local registry both go away.

---

## What is in here

| Path | What it does |
|---|---|
| `Makefile` | Every step, individually runnable. Start here. |
| `Jenkinsfile` | The same chain as a real pipeline, with credential bindings |
| `.github/workflows/supply-chain.yml` | Keyless (OIDC) variant, plus policy unit-testing with the Kyverno CLI |
| `policies/` | Kyverno: non-root, resource limits, no floating tags |
| `scripts/render-verify-policy.sh` | Injects the public key into the verify policy at apply time |
| `manifests/` | Deployment and Service for the demo workload |
| `app/` | A deliberately boring HTTP service — the payload, not the point |
| `docs/` | Integration notes and the failure log |

---

## The policies

| Policy | Blocks | Why it is here |
|---|---|---|
| `verify-image-signature` | Images with no valid cosign signature | The headline gate |
| `require-non-root` | Root containers, privilege escalation, undropped capabilities | Signing proves provenance, not behaviour |
| `require-resource-limits` | Missing requests/limits | Cheapest guardrail against both noisy-neighbour incidents and runaway spend |
| `disallow-latest-tag` | `:latest` and untagged references | A floating tag means tomorrow's image is not the one you scanned today |

All four run in `Enforce`, not `Audit`. A policy in audit mode is a dashboard,
not a control.

---

## Four things that will bite you

Collected from getting this wrong first. See [`docs/what-broke.md`](docs/what-broke.md)
for the longer version.

**1. Signing the tag instead of the digest.** `cosign sign registry/app:v1`
signs whatever digest that tag points at *right now*. Push a new image to the
same tag and the signature is orphaned. Sign the digest and deploy the digest.

**2. `failurePolicy: Ignore` quietly disables everything.** If the Kyverno
webhook is unreachable and the policy is set to ignore failures, every pod is
admitted unverified and nothing in the logs looks wrong. This repo uses
`failurePolicy: Fail`, which means a Kyverno outage blocks deploys — the
correct trade for a security control, and a decision worth making consciously.

**3. `validationFailureAction: Audit` looks identical to working.** Policies
report violations, dashboards light up, and every unsigned image still gets
admitted. Check with `kubectl get cpol` and read the action column before
believing a gate exists.

**4. Trivy without `--ignore-unfixed` blocks on vulnerabilities with no
patch available.** The build fails on something nobody can fix, the team
disables the gate within a week, and the gate is now permanently off. Gate on
what is actionable.

---

## Adapting this to a real cluster

The lab uses a local kind cluster and a key-based cosign signature because
both are reproducible with no account anywhere. Production differs in three
places:

- **Key storage.** The private key belongs in a KMS (Azure Key Vault, AWS KMS)
  or in keyless OIDC signing — not in a file. `cosign sign --key azurekms://...`
  is a drop-in change.
- **Policy scope.** `imageReferences` should match your registry only, so that
  base images from public registries are handled by a separate rule rather than
  failing verification.
- **Rollout.** Start in `Audit`, read the policy reports for a week to find
  which existing workloads would break, fix those, and only then switch to
  `Enforce`. Flipping straight to enforce on a live cluster blocks deploys for
  teams who did not know a gate was coming.

See [`docs/jenkins-integration.md`](docs/jenkins-integration.md) for the
credential setup.

---

## License

MIT

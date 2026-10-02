# What broke

Notes kept while building this, in the order the problems showed up. Most of
the time spent on image signing is not spent on signing.

---

## The signature verified locally and the cluster still refused it

`cosign verify --key cosign.pub <image>` passed. Kyverno denied the pod with
"no signatures found".

Cause: the image was signed by tag, and Kyverno was verifying by digest after
`mutateDigest: true` resolved the tag. Between the sign and the deploy the tag
had been rebuilt, so the digest Kyverno resolved had no signature attached to
it — while the tag still pointed somewhere that did.

Fix: sign the digest.

```bash
DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE")"
cosign sign --yes --key cosign.key "$DIGEST"
```

The general rule: anything that verifies a signature should be handed an
immutable reference. A tag is a pointer, not an identity.

---

## Policies installed, dashboard green, unsigned images still running

`kubectl get cpol` showed all four policies present and ready. Unsigned pods
kept getting admitted anyway.

Cause: `validationFailureAction: Audit`. In audit mode Kyverno records a
policy report and admits the resource. Everything looks installed and nothing
is enforced.

Check this explicitly rather than assuming:

```bash
kubectl get cpol -o custom-columns=\
NAME:.metadata.name,ACTION:.spec.validationFailureAction,READY:.status.ready
```

Related: `failurePolicy: Ignore` has the same shape of problem one layer down.
If the admission webhook is unreachable, pods are admitted unverified and
nothing in the event log flags it. `Fail` is the correct setting for a
security gate, with the understood cost that a Kyverno outage stops deploys.

---

## kind could not pull from the local registry

`ErrImagePull` on `localhost:5001/...`, while `docker pull` from the host
worked fine.

Cause: `localhost` inside a kind node is the node's own loopback, not the
host's. The registry container has to be attached to the kind network and
containerd has to be told where to find it — which is what
`scripts/kind-with-registry.sh` sets up via `certs.d/<registry>/hosts.toml`.

This is not a cosign problem but it eats twenty minutes if the first failure
of the demo is a pull error and the instinct is to debug the signature.

---

## The build started failing on a vulnerability with no fix

Trivy began gating on a HIGH finding in a transitive OS package with no
patched version available upstream. There was no action that would clear it.

The realistic outcome of that situation is somebody disables the scan gate,
and then it stays disabled. `--ignore-unfixed` keeps the gate on things
somebody can actually do something about:

```bash
trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 "$IMAGE"
```

The unfixed findings still show in the archived report. They are tracked, just
not blocking.

---

## Non-root policy rejected the image that had just been signed

A correctly signed image was still denied, this time by `require-non-root`.

That is the policy working. Signing answers "did this come from us"; it says
nothing about whether the thing inside runs as uid 0. The Dockerfile in this
repo creates a uid 10001 user for exactly that reason, and the deployment sets
`runAsNonRoot`, `readOnlyRootFilesystem` and drops all capabilities.

Worth stating because "we sign our images" gets talked about as if it were a
complete control. It covers one axis.

---

<!-- TODO (Raju): add production incidents here as they happen — the
     cluster-specific ones are the most valuable entries in this file.
     Format: symptom first, wrong hypothesis second, root cause third, fix
     last. Keep the wrong hypothesis in; it is the part that is useful to
     another engineer. -->

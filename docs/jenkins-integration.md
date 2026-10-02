# Running this chain in Jenkins

The `Jenkinsfile` at the repo root is the pipeline version of `make demo`.
It differs from the lab in one way that matters: nothing is generated on the
fly. Keys, registry credentials and cluster access all come from Jenkins
credentials.

## Credentials to create

| ID | Kind | Contains |
|---|---|---|
| `registry-credentials` | Username with password | Registry push account |
| `cosign-private-key` | Secret file | `cosign.key` |
| `cosign-public-key` | Secret file | `cosign.pub` |
| `cosign-password` | Secret text | Passphrase for the private key |
| `kubeconfig` | Secret file | Kubeconfig scoped to the deploy namespace |

Three of those are cosign-specific and are easy to miss when wiring this up
for the first time — the pipeline fails at the Sign stage with a bare
`COSIGN_PASSWORD not set`, which does not point at the missing credential very
clearly.

## Agent requirements

The agent needs `docker`, `cosign`, `trivy` and `kubectl` on PATH. If your
agents are containers, bake those in rather than installing them per-build —
a `trivy` install on every run adds a minute and occasionally fails on
upstream rate limits.

Trivy's vulnerability database is the other common slow spot. Mount a shared
cache directory across builds:

```groovy
environment {
  TRIVY_CACHE_DIR = '/var/jenkins_cache/trivy'
}
```

## Moving the key into Key Vault

Once the chain works with a file-based key, swap the signing step:

```groovy
sh '''
  cosign sign --yes \
    --key "azurekms://${VAULT_NAME}.vault.azure.net/${KEY_NAME}" \
    "${DIGEST}"
'''
```

The Kyverno policy changes correspondingly — instead of an inline
`publicKeys` block it points at the KMS reference, so key rotation stops
being a policy redeploy.

## Rollback

The deploy stage uses `kubectl rollout undo` on failure. If you are on Helm
instead, `helm upgrade --install --atomic --timeout 5m` does the same thing
more cleanly: a failed release rolls itself back and the pipeline gets a
non-zero exit without a separate post block.

One caveat worth knowing: `--atomic` implies `--wait`, so the pipeline blocks
for the full timeout on a bad deploy. Set the timeout deliberately rather than
leaving it at the five-minute default if your rollouts are slower.

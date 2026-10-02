#!/usr/bin/env bash
# Inline the cosign public key into the Kyverno verifyImages policy.
#
# Kyverno wants the PEM inside the policy body. Keeping the key out of git and
# rendering it at apply time is the same thing a real pipeline does with a
# Jenkins credential or a Key Vault secret.
set -euo pipefail

PUB="${1:-cosign.pub}"
REGISTRY="${2:-localhost:5001}"

if [ ! -f "${PUB}" ]; then
  echo "error: public key '${PUB}' not found — run 'make keys' first" >&2
  exit 1
fi

# Indent the PEM so it sits inside the 'publicKeys: |-' block scalar.
# publicKeys sits at 20 spaces, so its content needs strictly more than that.
KEY_BLOCK="$(sed 's/^/                      /' "${PUB}")"

cat <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
  annotations:
    policies.kyverno.io/title: Verify image signatures
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: critical
    policies.kyverno.io/description: >-
      Every image from the trusted registry must carry a valid cosign
      signature made with the key below. Unsigned or foreign-signed images
      are refused at admission, before a pod is ever scheduled.
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  rules:
    - name: require-cosign-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "${REGISTRY}/*"
          mutateDigest: true
          verifyDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
${KEY_BLOCK}
EOF

// Supply-chain pipeline — the shape this repo demonstrates, written the way it
// actually runs in a cluster rather than the way it looks in a blog post.
//
// Gate order matters: scan before sign. Signing a vulnerable image just gives
// you a cryptographically verified vulnerable image.
//
// Required Jenkins credentials:
//   registry-credentials    Username/password for the image registry
//   cosign-private-key      Secret file   — cosign.key
//   cosign-public-key       Secret file   — cosign.pub
//   cosign-password         Secret text   — passphrase for the private key
//   kubeconfig              Secret file   — cluster access for the deploy stage

pipeline {
  agent any

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '30'))
    timeout(time: 30, unit: 'MINUTES')
    disableConcurrentBuilds()
  }

  environment {
    REGISTRY      = 'registry.example.com'
    IMAGE_NAME    = 'supply-chain-demo'
    IMAGE_TAG     = "${env.GIT_COMMIT?.take(7) ?: env.BUILD_NUMBER}"
    IMAGE         = "${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    NAMESPACE     = 'demo'
    TRIVY_SEVERITY = 'HIGH,CRITICAL'
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm
        script {
          currentBuild.description = "${IMAGE_NAME}:${IMAGE_TAG}"
        }
      }
    }

    stage('Build') {
      steps {
        sh '''
          set -euo pipefail
          docker build \
            --build-arg APP_VERSION="${IMAGE_TAG}" \
            --label org.opencontainers.image.revision="${GIT_COMMIT}" \
            --label org.opencontainers.image.source="${GIT_URL}" \
            -t "${IMAGE}" .
        '''
      }
    }

    stage('Scan') {
      steps {
        sh '''
          set -euo pipefail

          # Report for humans, regardless of outcome.
          trivy image --severity "${TRIVY_SEVERITY}" --format table \
            --output trivy-report.txt "${IMAGE}" || true

          # The gate itself. --ignore-unfixed keeps the build from failing on
          # vulnerabilities with no upstream patch; everything else blocks.
          trivy image \
            --severity "${TRIVY_SEVERITY}" \
            --ignore-unfixed \
            --exit-code 1 \
            --format table \
            "${IMAGE}"
        '''
      }
      post {
        always {
          archiveArtifacts artifacts: 'trivy-report.txt', allowEmptyArchive: true
        }
      }
    }

    stage('SBOM') {
      steps {
        sh '''
          set -euo pipefail
          trivy image --format cyclonedx --output sbom.cdx.json "${IMAGE}"
        '''
        archiveArtifacts artifacts: 'sbom.cdx.json', allowEmptyArchive: true
      }
    }

    stage('Push') {
      steps {
        withCredentials([usernamePassword(
          credentialsId: 'registry-credentials',
          usernameVariable: 'REG_USER',
          passwordVariable: 'REG_PASS')]) {
          sh '''
            set -euo pipefail
            echo "${REG_PASS}" | docker login "${REGISTRY}" -u "${REG_USER}" --password-stdin
            docker push "${IMAGE}"
            docker logout "${REGISTRY}"
          '''
        }
      }
    }

    stage('Sign') {
      steps {
        withCredentials([
          file(credentialsId: 'cosign-private-key', variable: 'COSIGN_KEY_FILE'),
          string(credentialsId: 'cosign-password', variable: 'COSIGN_PASSWORD'),
          usernamePassword(credentialsId: 'registry-credentials',
                           usernameVariable: 'REG_USER',
                           passwordVariable: 'REG_PASS')
        ]) {
          sh '''
            set -euo pipefail
            echo "${REG_PASS}" | docker login "${REGISTRY}" -u "${REG_USER}" --password-stdin

            # Sign the digest, not the tag — a tag can be moved, a digest cannot.
            DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE}")"
            cosign sign --yes --key "${COSIGN_KEY_FILE}" "${DIGEST}"
            cosign attach sbom --sbom sbom.cdx.json "${DIGEST}" || true

            echo "${DIGEST}" > image-digest.txt
            docker logout "${REGISTRY}"
          '''
        }
        archiveArtifacts artifacts: 'image-digest.txt', allowEmptyArchive: false
      }
    }

    stage('Verify') {
      steps {
        withCredentials([file(credentialsId: 'cosign-public-key', variable: 'COSIGN_PUB_FILE')]) {
          sh '''
            set -euo pipefail
            DIGEST="$(cat image-digest.txt)"

            # Verifying here is not ceremony: it catches a key mismatch at build
            # time instead of at 2am when admission starts refusing every pod.
            cosign verify --key "${COSIGN_PUB_FILE}" "${DIGEST}"
          '''
        }
      }
    }

    stage('Deploy') {
      steps {
        withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')]) {
          sh '''
            set -euo pipefail
            DIGEST="$(cat image-digest.txt)"

            # The cluster re-verifies the signature at admission. If the policy
            # refuses, the rollout never starts — the gate is the cluster's, not
            # the pipeline's, which is the whole point.
            sed "s|IMAGE_PLACEHOLDER|${DIGEST}|g" manifests/deployment.yaml \
              | kubectl -n "${NAMESPACE}" apply -f -
            kubectl -n "${NAMESPACE}" apply -f manifests/service.yaml
            kubectl -n "${NAMESPACE}" rollout status deploy/supply-chain-demo --timeout=120s
          '''
        }
      }
      post {
        failure {
          withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')]) {
            sh 'kubectl -n "${NAMESPACE}" rollout undo deploy/supply-chain-demo || true'
          }
        }
      }
    }
  }

  post {
    always {
      sh 'docker image rm "${IMAGE}" || true'
      cleanWs()
    }
  }
}

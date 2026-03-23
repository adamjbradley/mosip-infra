#!/bin/bash
# Installs MOSIP external components on local Docker Desktop Kubernetes.
# Follows the sequence from mosip-infra/deployment/v3/external/all/install-all.sh
# but adapted for local dev (no Istio, reduced resources, hostpath storage).
#
# Profiles:
#   minimal — postgres + keycloak + softhsm (~1.5GB RAM)
#   core    — + kafka + minio + activemq (~3.5GB RAM)
#   all     — + clamav + msg-gateways + captcha (~5GB RAM)
#
# Prerequisites:
#   - k8s-infra local setup already running (k8s-infra/local/setup.sh minimal)
#   - helm, kubectl on PATH
#
# Usage: ./install-external.sh [minimal|core|all|component|teardown]

set -e
set -o errexit
set -o nounset
set -o errtrace
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENT="${1:-all}"

# ---------- helpers ----------

ensure_ns() {
  local ns=$1
  kubectl create ns "$ns" 2>/dev/null || true
}

copy_cm() {
  local cm=$1 src_ns=$2 dst_ns=$3
  kubectl get cm "$cm" -n "$src_ns" -o yaml \
    | sed "s/namespace: $src_ns/namespace: $dst_ns/" \
    | kubectl apply -n "$dst_ns" -f - 2>/dev/null || true
}

copy_standard_cms() {
  local ns=$1
  copy_cm global default "$ns"
  copy_cm artifactory-share artifactory "$ns" 2>/dev/null || true
  copy_cm config-server-share config-server "$ns" 2>/dev/null || true
}

add_helm_repos() {
  echo "Adding Helm repos..."
  helm repo add mosip https://mosip.github.io/mosip-helm 2>/dev/null || true
  helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
  helm repo update
}

# ---------- ingress ----------

# Create keycloak-host configmap in default namespace for services to copy.
install_keycloak_host_cm() {
  echo "=== Creating keycloak-host configmap ==="
  kubectl create configmap keycloak-host \
    --from-literal=keycloak-internal-url="http://keycloak.keycloak/auth" \
    --from-literal=keycloak-internal-host="keycloak.keycloak" \
    --from-literal=keycloak-external-url="http://iam.mosip.localhost:30080/auth" \
    --from-literal=keycloak-external-host="iam.mosip.localhost" \
    --dry-run=client -o yaml | kubectl apply -f -
}

install_ingress() {
  echo "=== Applying MOSIP ingress resources ==="
  # Apply each ingress resource only if its namespace exists.
  # This allows minimal/core profiles to skip resources for uninstalled components.
  local tmpdir
  tmpdir=$(mktemp -d)
  # Split multi-doc YAML into individual files
  awk 'BEGIN{n=0} /^---/{n++; next} {print > ("'"$tmpdir"'/doc-" n ".yaml")}' "$SCRIPT_DIR/ingress-mosip.yaml"
  for f in "$tmpdir"/doc-*.yaml; do
    local ns
    ns=$(grep '^ *namespace:' "$f" 2>/dev/null | head -1 | awk '{print $2}')
    if [ -n "$ns" ] && kubectl get ns "$ns" &>/dev/null; then
      kubectl apply -f "$f"
    else
      echo "  Skipping ingress for namespace '$ns' (not deployed)"
    fi
  done
  rm -rf "$tmpdir"
  echo "Ingress resources applied."
}

# ---------- global configmap ----------

install_global_configmap() {
  echo "=== Applying global configmap ==="
  kubectl apply -f "$SCRIPT_DIR/global-configmap.yaml"
}

# ---------- postgres ----------

install_postgres() {
  echo "=== Installing PostgreSQL ==="
  local NS=postgres
  ensure_ns $NS
  helm upgrade --install postgres mosip/postgresql \
    -n $NS \
    -f "$SCRIPT_DIR/postgres-values-local.yaml" \
    --set image.repository=mosipid/postgresql \
    --set image.tag=14.2.0-debian-10-r70 \
    --set global.security.allowInsecureImages=true \
    --wait --timeout 5m
  echo "PostgreSQL installed."
}

# ---------- keycloak (MOSIP version with built-in postgres) ----------

install_keycloak() {
  echo "=== Installing Keycloak (MOSIP) ==="
  local NS=keycloak
  ensure_ns $NS
  copy_standard_cms $NS
  helm upgrade --install keycloak mosip/keycloak \
    -n $NS \
    --version 7.1.18 \
    -f "$SCRIPT_DIR/keycloak-values-local.yaml" \
    --set image.repository=mosipid/mosip-artemis-keycloak \
    --set image.tag=1.3.0 \
    --set postgresql.image.repository=mosipid/postgresql \
    --set postgresql.image.tag=14.2.0-debian-10-r70 \
    --set global.security.allowInsecureImages=true \
    --timeout 10m
  echo "Keycloak installed (may take 5+ min to fully start)."
}

# ---------- softhsm ----------

install_softhsm() {
  echo "=== Installing SoftHSM ==="
  local NS=softhsm
  ensure_ns $NS
  helm upgrade --install softhsm-kernel mosip/softhsm \
    -n $NS --version 1.3.0 \
    --set resources.requests.cpu=5m \
    --set resources.requests.memory=16Mi \
    --set resources.limits.cpu=100m \
    --set resources.limits.memory=128Mi \
    --wait --timeout 3m
  helm upgrade --install softhsm-ida mosip/softhsm \
    -n $NS --version 1.3.0 \
    --set resources.requests.cpu=5m \
    --set resources.requests.memory=16Mi \
    --set resources.limits.cpu=100m \
    --set resources.limits.memory=128Mi \
    --wait --timeout 3m
  echo "SoftHSM installed (kernel + ida)."
}

# ---------- minio ----------

install_minio() {
  echo "=== Installing MinIO ==="
  local NS=minio
  ensure_ns $NS
  helm upgrade --install minio mosip/minio \
    -n $NS --version 15.0.6 \
    --set image.repository=mosipid/minio \
    --set image.tag=2025.2.28-debian-12-r1 \
    --set global.security.allowInsecureImages=true \
    --set persistence.storageClass=hostpath \
    --set resources.requests.cpu=10m \
    --set resources.requests.memory=64Mi \
    --set resources.limits.cpu=200m \
    --set resources.limits.memory=256Mi \
    --wait --timeout 5m
  echo "MinIO installed."
}

# ---------- clamav ----------

install_clamav() {
  echo "=== Installing ClamAV ==="
  local NS=clamav
  ensure_ns $NS
  helm upgrade --install clamav mosip/clamav \
    -n $NS --version 3.1.0 \
    --set image.repository=mosipid/clamav \
    --set image.tag=1.3.0_base \
    --set resources.requests.memory=512Mi \
    --set resources.limits.memory=1200Mi \
    --wait --timeout 5m
  echo "ClamAV installed."
}

# ---------- activemq ----------

install_activemq() {
  echo "=== Installing ActiveMQ ==="
  local NS=activemq
  ensure_ns $NS
  helm upgrade --install activemq mosip/activemq-artemis \
    -n $NS --version 0.0.3 \
    --set image.repository=mosipid/activemq-artemis \
    --set image.tag=2.39.0 \
    --set persistence.storageClass=hostpath \
    --set resources.requests.cpu=10m \
    --set resources.requests.memory=64Mi \
    --set resources.limits.cpu=300m \
    --set resources.limits.memory=768Mi \
    --wait --timeout 5m
  echo "ActiveMQ installed."
}

# ---------- kafka ----------

install_kafka() {
  echo "=== Installing Kafka ==="
  local NS=kafka
  ensure_ns $NS
  helm upgrade --install kafka mosip/kafka \
    -n $NS --version 18.3.1 \
    -f "$SCRIPT_DIR/kafka-values-local.yaml" \
    --set image.repository=mosipid/kafka \
    --set image.tag=3.2.1-debian-11-r9 \
    --set zookeeper.image.repository=mosipid/zookeeper \
    --set zookeeper.image.tag=3.8.0-debian-11-r30 \
    --set global.security.allowInsecureImages=true \
    --set persistence.storageClass=hostpath \
    --set zookeeper.persistence.storageClass=hostpath \
    --wait --timeout 5m

  # Kafka UI
  helm upgrade --install kafka-ui mosip/kafka-ui \
    -n $NS --version 0.4.2 \
    --set envs.config.KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS=kafka.$NS:9092 \
    --set envs.config.KAFKA_CLUSTERS_0_ZOOKEEPER=kafka-zookeeper.$NS:2181 \
    --timeout 3m
  echo "Kafka installed."
}

# ---------- msg-gateways ----------

install_msg_gateways() {
  echo "=== Configuring message gateways ==="
  local NS=msg-gateways
  ensure_ns $NS
  kubectl -n $NS create configmap msg-gateway \
    --from-literal=smtp-host=mock-smtp.mock-smtp \
    --from-literal=smtp-port=8025 \
    --from-literal=sms-host=mock-smtp.mock-smtp \
    --from-literal=sms-port=8080 \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Message gateways configured (using mock-smtp)."
}

# ---------- docker-secrets ----------

install_docker_secrets() {
  echo "=== Skipping docker-secrets (public Docker Hub only) ==="
}

# ---------- landing-page ----------

install_landing_page() {
  echo "=== Skipping landing-page (optional for local dev) ==="
}

# ---------- captcha ----------

install_captcha_secret() {
  echo "=== Creating captcha secret (dummy for local dev) ==="
  local NS=captcha
  ensure_ns $NS
  kubectl -n $NS create secret generic mosip-captcha \
    --from-literal=prereg-site-key=dummy \
    --from-literal=prereg-secret-key=dummy \
    --from-literal=admin-site-key=dummy \
    --from-literal=admin-secret-key=dummy \
    --from-literal=resident-site-key=dummy \
    --from-literal=resident-secret-key=dummy \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Captcha secret created (dummy keys for local dev)."
}

# ---------- teardown ----------

teardown() {
  echo "=== Tearing down MOSIP external components ==="
  for ns in captcha msg-gateways clamav minio softhsm activemq kafka keycloak postgres; do
    echo "Removing $ns..."
    helm ls -n $ns -q 2>/dev/null | xargs -r -n1 helm uninstall -n $ns 2>/dev/null || true
    kubectl delete ns $ns 2>/dev/null || true
  done
  echo "Teardown complete."
}

# ---------- main ----------

case "$COMPONENT" in
  teardown)
    teardown
    ;;
  # --- profiles ---
  minimal)
    add_helm_repos
    install_global_configmap
    install_postgres
    install_keycloak
    install_keycloak_host_cm
    install_softhsm
    install_ingress
    echo ""
    echo "Minimal external components installed (postgres, keycloak, softhsm)."
    echo "Use './install-external.sh core' to add kafka, minio, activemq."
    ;;
  core)
    add_helm_repos
    install_global_configmap
    install_postgres
    install_keycloak
    install_keycloak_host_cm
    install_softhsm
    install_kafka
    install_minio
    install_activemq
    install_ingress
    echo ""
    echo "Core external components installed."
    echo "Use './install-external.sh all' to add clamav, msg-gateways, captcha."
    ;;
  all)
    add_helm_repos
    install_global_configmap
    install_postgres
    install_keycloak
    install_keycloak_host_cm
    install_softhsm
    install_kafka
    install_minio
    install_activemq
    install_clamav
    install_msg_gateways
    install_docker_secrets
    install_captcha_secret
    install_landing_page
    install_ingress
    echo ""
    echo "All MOSIP external components installed."
    ;;
  # --- individual components ---
  postgres)     install_postgres ;;
  keycloak)     install_keycloak ;;
  softhsm)      install_softhsm ;;
  minio)        install_minio ;;
  clamav)       install_clamav ;;
  activemq)     install_activemq ;;
  kafka)        install_kafka ;;
  *)
    echo "Unknown component: $COMPONENT"
    echo "Usage: $0 [minimal|core|all|postgres|keycloak|softhsm|minio|clamav|activemq|kafka|teardown]"
    echo ""
    echo "Profiles:"
    echo "  minimal — postgres + keycloak + softhsm (~1.5GB RAM)"
    echo "  core    — + kafka + minio + activemq (~3.5GB RAM)"
    echo "  all     — + clamav + msg-gateways + captcha (~5GB RAM)"
    exit 1
    ;;
esac
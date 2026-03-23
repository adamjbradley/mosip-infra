#!/bin/bash
# Installs MOSIP core services on local Docker Desktop Kubernetes.
# Follows the sequence from mosip-infra/deployment/v3/mosip/all/install-all.sh
# but adapted for local dev: reduced JVM heap, minimal resource requests,
# no Istio sidecars, skip SSL cert init containers.
#
# Prerequisites:
#   - MOSIP external components running (./mosip-external.sh)
#   - config-server, artifactory, keymanager already deployed
#
# Usage: ./install-services.sh [component|teardown|status]

set -e
set -o errexit
set -o nounset
set -o errtrace
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENT="${1:-all}"
CHART_VERSION=1.3.0

# --- JVM heap override ---
# MOSIP images hardcode -Xms1575M -Xmx1575M via JDK_JAVA_OPTIONS.
# On local dev with 1Gi container limits, this causes OOMKill.
# We override to 512m max heap.
JVM_OPTS="-Xms256m -Xmx512m"

# --- Resource template ---
# Minimal requests so K8s can overcommit on a memory-constrained node.
# Limits at 1Gi to accommodate Spring Boot + JVM overhead.
REQ_CPU=10m
REQ_MEM=64Mi
LIM_CPU=500m
LIM_MEM=1Gi

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

# Install a simple MOSIP helm chart with JVM override and minimal resources.
# Usage: install_mosip_chart <namespace> <release> <chart> [extra helm args...]
install_mosip_chart() {
  local ns=$1 release=$2 chart=$3
  shift 3
  helm upgrade --install "$release" "mosip/$chart" \
    -n "$ns" --version "$CHART_VERSION" \
    --set resources.requests.cpu=$REQ_CPU \
    --set resources.requests.memory=$REQ_MEM \
    --set resources.limits.cpu=$LIM_CPU \
    --set resources.limits.memory=$LIM_MEM \
    --set extraEnvVars[0].name=JDK_JAVA_OPTIONS \
    --set extraEnvVars[0].value="$JVM_OPTS" \
    --timeout 5m \
    "$@"
}

# Patch a running deployment to override JVM heap (for charts that don't
# support extraEnvVars).
patch_jvm() {
  local ns=$1 deploy=$2
  kubectl -n "$ns" set env "deploy/$deploy" JDK_JAVA_OPTIONS="$JVM_OPTS" 2>/dev/null || true
}

# Patch a deployment's init container to skip SSL cert import (not needed locally).
skip_cacerts_init() {
  local ns=$1 deploy=$2
  kubectl -n "$ns" patch deploy "$deploy" --type='json' \
    -p='[{"op":"replace","path":"/spec/template/spec/initContainers/0/command","value":["sh","-c","echo skipping cacerts for local dev"]},{"op":"replace","path":"/spec/template/spec/initContainers/0/image","value":"eclipse-temurin:11-jre"}]' \
    2>/dev/null || true
}

# ---------- 1. conf-secrets ----------

install_conf_secrets() {
  echo "=== Installing conf-secrets (1/27) ==="
  local NS=conf-secrets
  ensure_ns $NS
  helm upgrade --install conf-secrets mosip/conf-secrets \
    -n $NS --version $CHART_VERSION --wait --timeout 3m
}

# ---------- 2. config-server ----------

install_config_server() {
  echo "=== Installing config-server (2/27) ==="
  local NS=config-server
  ensure_ns $NS
  copy_cm global default $NS
  helm upgrade --install config-server mosip/config-server \
    -n $NS --version $CHART_VERSION \
    --set resources.requests.cpu=10m \
    --set resources.requests.memory=128Mi \
    --set resources.limits.cpu=500m \
    --set resources.limits.memory=512Mi \
    --set spring_profiles.enabled=true \
    --set 'spring_profiles.spring_compositeRepos[0].type=git' \
    --set 'spring_profiles.spring_compositeRepos[0].uri=https://github.com/mosip/mosip-config.git' \
    --set 'spring_profiles.spring_compositeRepos[0].version=v1.3.0' \
    --timeout 5m
  patch_jvm $NS config-server
}

# ---------- 3. artifactory ----------

install_artifactory() {
  echo "=== Installing artifactory (3/27) ==="
  local NS=artifactory
  ensure_ns $NS
  copy_standard_cms $NS
  helm upgrade --install artifactory mosip/artifactory \
    -n $NS --version $CHART_VERSION \
    --set resources.requests.cpu=10m \
    --set resources.requests.memory=64Mi \
    --set resources.limits.cpu=200m \
    --set resources.limits.memory=256Mi \
    --timeout 5m
}

# ---------- 4. captcha ----------

install_captcha() {
  echo "=== Installing captcha (4/27) ==="
  local NS=captcha
  ensure_ns $NS
  helm upgrade --install captcha mosip/captcha \
    -n $NS --version 0.1.0 \
    --set resources.requests.cpu=10m \
    --set resources.requests.memory=64Mi \
    --set resources.limits.cpu=500m \
    --set resources.limits.memory=$LIM_MEM \
    --timeout 5m
  patch_jvm $NS captcha
}

# ---------- 5. keymanager ----------

install_keymanager() {
  echo "=== Installing keymanager (5/27) ==="
  local NS=keymanager
  ensure_ns $NS
  copy_standard_cms $NS
  copy_cm softhsm-kernel-share softhsm $NS

  echo "Running keygen..."
  helm upgrade --install kernel-keygen mosip/keygen \
    -n $NS --version $CHART_VERSION \
    --set springConfigNameEnv=kernel \
    --set softHsmCM=softhsm-kernel-share \
    --wait --wait-for-jobs --timeout 10m

  echo "Installing keymanager service..."
  helm upgrade --install keymanager mosip/keymanager \
    -n $NS --version $CHART_VERSION \
    --set resources.requests.cpu=25m \
    --set resources.requests.memory=256Mi \
    --set resources.limits.cpu=500m \
    --set resources.limits.memory=2Gi \
    --timeout 5m
}

# ---------- 6. websub ----------

install_websub() {
  echo "=== Installing websub (6/27) ==="
  local NS=websub
  ensure_ns $NS
  copy_standard_cms $NS
  install_mosip_chart $NS websub-consolidator websub-consolidator
  install_mosip_chart $NS websub websub
}

# ---------- 7. mock-smtp ----------

install_mock_smtp() {
  echo "=== Installing mock-smtp (7/27) ==="
  local NS=mock-smtp
  ensure_ns $NS
  copy_cm global default $NS
  copy_cm config-server-share config-server $NS
  local SMTP_HOST
  SMTP_HOST=$(kubectl get cm global -o jsonpath='{.data.mosip-smtp-host}')
  helm upgrade --install mock-smtp mosip/mock-smtp \
    -n $NS --version 1.0.0 \
    --set istio.hosts[0]="$SMTP_HOST" \
    --timeout 5m
}

# ---------- 8. kernel ----------

install_kernel() {
  echo "=== Installing kernel (8/27 — 9 sub-services) ==="
  local NS=kernel
  ensure_ns $NS
  copy_standard_cms $NS
  local ADMIN_HOST
  ADMIN_HOST=$(kubectl get cm global -o jsonpath='{.data.mosip-admin-host}')

  for svc in authmanager auditmanager idgenerator otpmanager pridgenerator ridgenerator syncdata notifier; do
    echo "  Installing $svc..."
    install_mosip_chart $NS "$svc" "$svc" --set enable_insecure=true
    patch_jvm $NS "$svc"
  done

  echo "  Installing masterdata..."
  install_mosip_chart $NS masterdata masterdata \
    --set "istio.corsPolicy.allowOrigins[0].exact=https://$ADMIN_HOST"
  patch_jvm $NS masterdata

  # Fix init containers that reference the removed openjdk:11-jre image
  for svc in authmanager auditmanager; do
    skip_cacerts_init $NS "$svc"
  done
}

# ---------- 9. masterdata-loader ----------

install_masterdata_loader() {
  echo "=== Installing masterdata-loader (9/27) ==="
  local NS=masterdata-loader
  ensure_ns $NS
  copy_standard_cms $NS
  helm upgrade --install masterdata-loader mosip/masterdata-loader \
    -n $NS --version $CHART_VERSION \
    --wait --wait-for-jobs --timeout 10m
}

# ---------- 10. biosdk ----------

install_biosdk() {
  echo "=== Installing biosdk (10/27) ==="
  local NS=biosdk
  ensure_ns $NS
  copy_standard_cms $NS
  install_mosip_chart $NS biosdk biosdk-service
  patch_jvm $NS biosdk-biosdk-service
}

# ---------- 11-12. packetmanager + datashare ----------

install_packetmanager() {
  echo "=== Installing packetmanager (11/27) ==="
  local NS=packetmanager
  ensure_ns $NS
  copy_standard_cms $NS
  install_mosip_chart $NS packetmanager packetmanager
  patch_jvm $NS packetmanager
}

install_datashare() {
  echo "=== Installing datashare (12/27) ==="
  local NS=datashare
  ensure_ns $NS
  copy_standard_cms $NS
  install_mosip_chart $NS datashare datashare
  patch_jvm $NS datashare
}

# ---------- 13. prereg ----------

install_prereg() {
  echo "=== Installing prereg (13/27) ==="
  local NS=prereg
  ensure_ns $NS
  copy_standard_cms $NS
  for svc in prereg-application prereg-booking prereg-datasync prereg-batchjob; do
    install_mosip_chart $NS "$svc" "$svc"
    patch_jvm $NS "$svc"
  done
  # UI (lightweight, no JVM override needed)
  helm upgrade --install prereg-ui mosip/prereg-ui \
    -n $NS --version $CHART_VERSION --timeout 3m
}

# ---------- 14. idrepo ----------

install_idrepo() {
  echo "=== Installing idrepo (14/27) ==="
  local NS=idrepo
  ensure_ns $NS
  copy_standard_cms $NS

  # Salt generation job
  helm upgrade --install idrepo-saltgen mosip/idrepo-saltgen \
    -n $NS --version $CHART_VERSION \
    --wait --wait-for-jobs --timeout 10m

  for svc in credential credentialrequest identity vid; do
    install_mosip_chart $NS "$svc" "$svc"
    patch_jvm $NS "$svc"
  done
}

# ---------- 15. pms ----------

install_pms() {
  echo "=== Installing pms (15/27) ==="
  local NS=pms
  ensure_ns $NS
  copy_standard_cms $NS
  install_mosip_chart $NS pms-partner pms-partner
  install_mosip_chart $NS pms-policy pms-policy
  patch_jvm $NS pms-partner
  patch_jvm $NS pms-policy
}

# ---------- 16-17. mock-abis + mock-mv ----------

install_mock_abis() {
  echo "=== Installing mock-abis + mock-mv (16-17/27) ==="
  local NS=abis
  ensure_ns $NS
  copy_standard_cms $NS
  install_mosip_chart $NS mock-abis mock-abis
  install_mosip_chart $NS mock-mv mock-mv
  patch_jvm $NS mock-abis
  patch_jvm $NS mock-mv
}

# ---------- 18. regproc ----------

install_regproc() {
  echo "=== Installing regproc (18/27 — 15 sub-services) ==="
  local NS=regproc
  ensure_ns $NS
  copy_standard_cms $NS

  # Salt generation
  helm upgrade --install regproc-salt mosip/regproc-salt \
    -n $NS --version $CHART_VERSION \
    --wait --wait-for-jobs --timeout 10m

  # Core services (keep groups 1-2 for dev, skip 3-7 to save memory)
  for svc in regproc-workflow regproc-status regproc-camel regproc-pktserver regproc-group1 regproc-group2; do
    install_mosip_chart $NS "$svc" "$svc"
    patch_jvm $NS "$svc"
  done
}

# ---------- 19. admin ----------

install_admin() {
  echo "=== Installing admin (19/27) ==="
  local NS=admin
  ensure_ns $NS
  copy_standard_cms $NS
  local ADMIN_HOST
  ADMIN_HOST=$(kubectl get cm global -o jsonpath='{.data.mosip-admin-host}')

  install_mosip_chart $NS admin-hotlist admin-hotlist
  install_mosip_chart $NS admin-service admin-service \
    --set "istio.corsPolicy.allowOrigins[0].exact=https://$ADMIN_HOST"
  patch_jvm $NS admin-hotlist
  patch_jvm $NS admin-service
}

# ---------- 20. ida ----------

install_ida() {
  echo "=== Installing ida (20/27) ==="
  local NS=ida
  ensure_ns $NS
  copy_standard_cms $NS
  copy_cm softhsm-ida-share softhsm $NS

  # Key generation
  helm upgrade --install ida-keygen mosip/keygen \
    -n $NS --version $CHART_VERSION \
    --set springConfigNameEnv=ida \
    --set softHsmCM=softhsm-ida-share \
    --wait --wait-for-jobs --timeout 10m

  for svc in ida-auth ida-internal ida-otp; do
    install_mosip_chart $NS "$svc" "$svc" --set enable_insecure=true
    patch_jvm $NS "$svc"
    skip_cacerts_init $NS "$svc"
  done
}

# ---------- 21. resident ----------

install_resident() {
  echo "=== Installing resident (21/27) ==="
  local NS=resident
  ensure_ns $NS
  copy_standard_cms $NS
  install_mosip_chart $NS resident resident --set enable_insecure=true
  patch_jvm $NS resident
  skip_cacerts_init $NS resident

  # UI (lightweight)
  helm upgrade --install resident-ui mosip/resident-ui \
    -n $NS --version $CHART_VERSION --timeout 3m
}

# ---------- status ----------

show_status() {
  echo "=== MOSIP Core Services Status ==="
  local ok=0 total=0
  for ns_dep in \
    "conf-secrets/conf-secrets" "config-server/config-server" "artifactory/artifactory" \
    "keymanager/keymanager" "websub/websub" "websub/websub-consolidator" \
    "mock-smtp/mock-smtp" \
    "kernel/authmanager" "kernel/auditmanager" "kernel/idgenerator" "kernel/masterdata" \
    "kernel/otpmanager" "kernel/pridgenerator" "kernel/ridgenerator" "kernel/syncdata" "kernel/notifier" \
    "biosdk/biosdk-biosdk-service" "packetmanager/packetmanager" "datashare/datashare" \
    "idrepo/identity" "idrepo/credential" "idrepo/credentialrequest" "idrepo/vid" \
    "regproc/regproc-workflow" "regproc/regproc-status" \
    "ida/ida-auth" "ida/ida-internal" "ida/ida-otp" \
    "resident/resident" \
  ; do
    local ns dep ready status icon
    ns=$(echo "$ns_dep" | cut -d/ -f1)
    dep=$(echo "$ns_dep" | cut -d/ -f2)
    ready=$(kubectl -n "$ns" get pods --no-headers 2>&1 | grep "^$dep" | grep -v Terminating | grep "1/1" | wc -l)
    status=$(kubectl -n "$ns" get pods --no-headers 2>&1 | grep "^$dep" | grep -v Terminating | head -1 | awk '{print $3}')
    icon="  "; if [ "$ready" -ge 1 ]; then icon="OK"; ok=$((ok+1)); fi
    total=$((total+1))
    printf "[%2s] %-15s %-25s %s\n" "$icon" "$ns" "$dep" "${status:-N/A}"
  done
  echo ""
  echo "$ok/$total services Running"
}

# ---------- teardown ----------

teardown() {
  echo "=== Tearing down MOSIP core services ==="
  for ns in resident ida admin regproc abis pms prereg idrepo datashare packetmanager biosdk \
            masterdata-loader kernel mock-smtp websub captcha keymanager artifactory config-server conf-secrets; do
    echo "Removing $ns..."
    helm ls -n "$ns" -q 2>/dev/null | xargs -r -n1 helm uninstall -n "$ns" 2>/dev/null || true
    kubectl delete ns "$ns" 2>/dev/null || true
  done
  echo "Teardown complete."
}

# ---------- main ----------

case "$COMPONENT" in
  teardown) teardown ;;
  status)   show_status ;;
  conf-secrets)     install_conf_secrets ;;
  config-server)    install_config_server ;;
  artifactory)      install_artifactory ;;
  captcha)          install_captcha ;;
  keymanager)       install_keymanager ;;
  websub)           install_websub ;;
  mock-smtp)        install_mock_smtp ;;
  kernel)           install_kernel ;;
  masterdata-loader) install_masterdata_loader ;;
  biosdk)           install_biosdk ;;
  packetmanager)    install_packetmanager ;;
  datashare)        install_datashare ;;
  prereg)           install_prereg ;;
  idrepo)           install_idrepo ;;
  pms)              install_pms ;;
  mock-abis)        install_mock_abis ;;
  regproc)          install_regproc ;;
  admin)            install_admin ;;
  ida)              install_ida ;;
  resident)         install_resident ;;
  all)
    install_conf_secrets
    install_config_server
    install_artifactory
    install_captcha
    install_keymanager
    install_websub
    install_mock_smtp
    install_kernel
    install_masterdata_loader
    install_biosdk
    install_packetmanager
    install_datashare
    install_prereg
    install_idrepo
    install_pms
    install_mock_abis
    install_regproc
    install_admin
    install_ida
    install_resident
    echo ""
    echo "All MOSIP core services installed."
    show_status
    ;;
  *)
    echo "Unknown component: $COMPONENT"
    echo "Usage: $0 [all|status|teardown|<component-name>]"
    exit 1
    ;;
esac
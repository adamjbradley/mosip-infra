#!/bin/bash
# Installs MOSIP core services on local Docker Desktop Kubernetes.
# Follows the sequence from mosip-infra/deployment/v3/mosip/all/install-all.sh
# but adapted for local dev: reduced JVM heap, minimal resource requests,
# no Istio sidecars, skip SSL cert init containers.
#
# Profiles:
#   minimal — config-server + kernel + idrepo + keymanager (~6GB RAM, ~13 pods)
#   core    — + websub + biosdk + packetmanager + datashare + ida (~10GB RAM, ~21 pods)
#   all     — + regproc + prereg + admin + pms + mock-abis + resident (~16GB RAM, ~29 pods)
#
# Prerequisites:
#   - MOSIP external components running (./install-external.sh)
#   - For minimal: ./install-external.sh minimal
#   - For core/all: ./install-external.sh core (needs kafka, minio, activemq)
#
# Usage: ./install-services.sh [minimal|core|all|component|teardown|status]

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

add_helm_repos() {
  echo "Adding Helm repos..."
  helm repo add mosip https://mosip.github.io/mosip-helm 2>/dev/null || true
  helm repo update
}

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
  copy_cm keycloak-host default "$ns" 2>/dev/null || true
  ensure_db_secret "$ns"
}

# Create db-common-secrets in a namespace from the postgres password.
# Many MOSIP charts mount this secret for database connectivity.
ensure_db_secret() {
  local ns=$1
  if ! kubectl -n "$ns" get secret db-common-secrets &>/dev/null; then
    local pg_pass
    pg_pass=$(kubectl -n postgres get secret postgres-postgresql -o jsonpath='{.data.postgresql-password}' | base64 -d)
    kubectl -n "$ns" create secret generic db-common-secrets \
      --from-literal=db-dbuser-password="$pg_pass" \
      --dry-run=client -o yaml | kubectl apply -f -
  fi
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

# Config-server mounts env vars from configmaps/secrets owned by other services
# (activemq, keycloak, s3, softhsm, etc.). On a fresh deploy these don't exist
# yet, causing CreateContainerConfigError. This function creates stubs with
# placeholder values so config-server can start. Real values replace these
# when the owning services are installed.
bootstrap_config_server_deps() {
  local ns=$1

  # Stub configmaps (only created if they don't already exist)
  for cm_data in \
    "activemq-activemq-artemis-share:activemq-host=activemq-activemq-artemis.activemq,activemq-core-port=61616" \
    "postgres-setup-config:mosip-database-hostname-override=postgres-postgresql.postgres,mosip-database-port-override=5432" \
  ; do
    local cm_name="${cm_data%%:*}"
    local cm_vals="${cm_data#*:}"
    if ! kubectl -n "$ns" get cm "$cm_name" &>/dev/null; then
      local args=""
      IFS=',' read -ra pairs <<< "$cm_vals"
      for pair in "${pairs[@]}"; do
        args="$args --from-literal=$pair"
      done
      eval kubectl -n "$ns" create configmap "$cm_name" $args
    fi
  done

  # Stub secrets (placeholder values — config-server passes these through to
  # services which won't use them until properly configured)
  for sec_name in keycloak-client-secrets; do
    if ! kubectl -n "$ns" get secret "$sec_name" &>/dev/null; then
      kubectl -n "$ns" create secret generic "$sec_name" \
        --from-literal=mosip_abis_client_secret=placeholder \
        --from-literal=mosip_auth_client_secret=placeholder \
        --from-literal=mosip_creser_client_secret=placeholder \
        --from-literal=mosip_creser_idpass_client_secret=placeholder \
        --from-literal=mosip_hotlist_client_secret=placeholder \
        --from-literal=mosip_ida_client_secret=placeholder \
        --from-literal=mosip_idrepo_client_secret=placeholder \
        --from-literal=mosip_pms_client_secret=placeholder \
        --from-literal=mosip_reg_client_secret=placeholder \
        --from-literal=mosip_resident_client_secret=placeholder \
        --from-literal=mpartner_default_digitalcard_secret=placeholder \
        --from-literal=mpartner_default_mobile_secret=placeholder \
        --from-literal=mpartner_default_template_secret=placeholder \
        --from-literal=mosip_syncdata_client_secret=placeholder \
        --from-literal=mosip_crereq_client_secret=placeholder \
        --from-literal=mosip_datsha_client_secret=placeholder \
        --from-literal=mpartner_default_auth_secret=placeholder \
        --from-literal=mpartner_default_print_secret=placeholder \
        --from-literal=mosip_digitalcard_client_secret=placeholder \
        --from-literal=mosip_misp_client_secret=placeholder \
        --from-literal=mosip_policymanager_client_secret=placeholder \
        --from-literal=mosip_prereg_client_secret=placeholder \
        --from-literal=mosip_regproc_client_secret=placeholder \
        --from-literal=mosip_admin_client_secret=placeholder
    fi
  done

  # Copy secrets from their source namespaces (if they exist)
  for src in \
    "softhsm/softhsm-kernel" \
    "softhsm/softhsm-ida" \
    "activemq/activemq-activemq-artemis" \
  ; do
    local src_ns="${src%%/*}"
    local sec_name="${src#*/}"
    if kubectl -n "$src_ns" get secret "$sec_name" &>/dev/null && \
       ! kubectl -n "$ns" get secret "$sec_name" &>/dev/null; then
      kubectl -n "$src_ns" get secret "$sec_name" -o yaml \
        | sed "s/namespace: $src_ns/namespace: $ns/" \
        | kubectl apply -n "$ns" -f -
    fi
  done

  # keycloak-host configmap
  if ! kubectl -n "$ns" get cm keycloak-host &>/dev/null; then
    kubectl -n "$ns" create configmap keycloak-host \
      --from-literal=keycloak-internal-url="http://keycloak.keycloak/auth" \
      --from-literal=keycloak-internal-host="keycloak.keycloak" \
      --from-literal=keycloak-external-url="http://iam.mosip.localhost:30080/auth" \
      --from-literal=keycloak-external-host="iam.mosip.localhost"
  fi

  # Copy conf-secrets-various from conf-secrets namespace
  if ! kubectl -n "$ns" get secret conf-secrets-various &>/dev/null; then
    kubectl -n conf-secrets get secret conf-secrets-various -o yaml \
      | sed "s/namespace: conf-secrets/namespace: $ns/" \
      | kubectl apply -n "$ns" -f - 2>/dev/null || true
  fi

  # Stub s3 configmap (MinIO credentials — chart uses configMapKeyRef for all keys)
  if ! kubectl -n "$ns" get cm s3 &>/dev/null; then
    kubectl -n "$ns" create configmap s3 \
      --from-literal=s3-region="" \
      --from-literal=s3-pretext-value="s3a://" \
      --from-literal=s3-user-key=minioadmin \
      --from-literal=s3-user-secret=minioadmin
  fi

  # Stub msg-gateway configmap + secret (chart uses both ref types)
  if ! kubectl -n "$ns" get cm msg-gateway &>/dev/null; then
    kubectl -n "$ns" create configmap msg-gateway \
      --from-literal=smtp-host=mock-smtp.mock-smtp \
      --from-literal=smtp-port=8025 \
      --from-literal=smtp-username="" \
      --from-literal=smtp-secret="" \
      --from-literal=sms-host=mock-smtp.mock-smtp \
      --from-literal=sms-port=8080 \
      --from-literal=sms-username="" \
      --from-literal=sms-secret="" \
      --from-literal=sms-authkey=""
  fi
  if ! kubectl -n "$ns" get secret msg-gateway &>/dev/null; then
    kubectl -n "$ns" create secret generic msg-gateway \
      --from-literal=smtp-secret="" \
      --from-literal=sms-secret="" \
      --from-literal=sms-authkey=""
  fi

  # Stub mosip-captcha secret (key names must match chart expectations)
  if ! kubectl -n "$ns" get secret mosip-captcha &>/dev/null; then
    kubectl -n "$ns" create secret generic mosip-captcha \
      --from-literal=prereg-captcha-site-key=dummy \
      --from-literal=prereg-captcha-secret-key=dummy \
      --from-literal=resident-captcha-site-key=dummy \
      --from-literal=resident-captcha-secret-key=dummy
  fi

  # Copy keycloak admin password secret
  if ! kubectl -n "$ns" get secret keycloak &>/dev/null; then
    kubectl -n keycloak get secret keycloak -o yaml \
      | sed "s/namespace: keycloak/namespace: $ns/" \
      | kubectl apply -n "$ns" -f - 2>/dev/null || true
  fi
}

install_config_server() {
  echo "=== Installing config-server (2/27) ==="
  local NS=config-server
  ensure_ns $NS
  copy_cm global default $NS
  copy_cm keycloak-host default $NS 2>/dev/null || true
  ensure_db_secret $NS

  # config-server mounts env vars from 14 configmaps/secrets across many namespaces.
  # Create stubs for any that don't exist yet so the pod can start.
  # Real values are populated later when the owning service is installed.
  echo "  Bootstrapping config-server dependencies..."
  bootstrap_config_server_deps $NS

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
    --set 'spring_profiles.spring_compositeRepos[0].spring_cloud_config_server_git_cloneOnStart=true' \
    --set 'spring_profiles.spring_compositeRepos[0].spring_cloud_config_server_git_force_pull=true' \
    --set 'spring_profiles.spring_compositeRepos[0].spring_cloud_config_server_git_refreshRate=0' \
    --set extraEnvVars[0].name=JDK_JAVA_OPTIONS \
    --set extraEnvVars[0].value="$JVM_OPTS" \
    --timeout 5m

  echo "  Waiting for config-server to be ready (may take 2-3 min)..."
  kubectl -n $NS rollout status deploy/config-server --timeout=300s || true
  kubectl -n $NS wait --for=condition=ready pod -l app.kubernetes.io/name=config-server --timeout=300s || true
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
  # --- profiles ---
  minimal)
    add_helm_repos
    install_conf_secrets
    install_config_server
    install_artifactory
    install_keymanager
    install_kernel
    install_idrepo
    echo ""
    echo "Minimal MOSIP services installed (config-server, kernel, idrepo, keymanager)."
    echo "Requires: ./install-external.sh minimal"
    echo "Use './install-services.sh core' to add websub, biosdk, ida, etc."
    show_status
    ;;
  core)
    add_helm_repos
    install_conf_secrets
    install_config_server
    install_artifactory
    install_keymanager
    install_websub
    install_kernel
    install_biosdk
    install_packetmanager
    install_datashare
    install_idrepo
    install_ida
    echo ""
    echo "Core MOSIP services installed (+ websub, biosdk, packetmanager, datashare, ida)."
    echo "Requires: ./install-external.sh core"
    echo "Use './install-services.sh all' to add regproc, prereg, admin, pms, resident."
    show_status
    ;;
  all)
    add_helm_repos
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
  # --- individual components ---
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
  *)
    echo "Unknown component: $COMPONENT"
    echo "Usage: $0 [minimal|core|all|status|teardown|<component-name>]"
    echo ""
    echo "Profiles:"
    echo "  minimal — config-server + kernel + idrepo + keymanager (~6GB RAM)"
    echo "  core    — + websub + biosdk + packetmanager + datashare + ida (~10GB RAM)"
    echo "  all     — + regproc + prereg + admin + pms + resident (~16GB RAM)"
    exit 1
    ;;
esac
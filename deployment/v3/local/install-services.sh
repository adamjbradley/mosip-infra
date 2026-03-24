#!/bin/bash
# Installs MOSIP core services on local Docker Desktop Kubernetes.
# Follows the sequence from mosip-infra/deployment/v3/mosip/all/install-all.sh
# but adapted for local dev: reduced JVM heap, minimal resource requests,
# no Istio sidecars, skip SSL cert init containers.
#
# IMPORTANT: Services are deployed SEQUENTIALLY by dependency layer.
# Each service waits until fully Ready (1/1) before the next starts.
# This prevents memory thrashing and cascading CrashLoops on constrained nodes.
#
# Dependency layers:
#   Layer 0: conf-secrets (secrets only, no pods)
#   Layer 1: config-server (all services depend on this)
#   Layer 2: keymanager (needs config-server + softhsm)
#   Layer 3: kernel (needs keymanager + config-server + DB)
#   Layer 4: idrepo (needs kernel + keymanager)
#   Layer 5: websub, biosdk, packetmanager, datashare (needs kernel)
#   Layer 6: ida, regproc, pms, admin, resident (needs all above)
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
# We use additionalResources.javaOpts (not extraEnvVars) to override,
# since many charts already define JDK_JAVA_OPTIONS in extraEnvVars.
JVM_OPTS="-Xms256m -Xmx512m"

# --- Resource template ---
# Minimal requests so K8s can overcommit on a memory-constrained node.
# Limits at 1Gi to accommodate Spring Boot + JVM overhead.
REQ_CPU=10m
REQ_MEM=64Mi
LIM_CPU=500m
LIM_MEM=1Gi

# --- Wait settings ---
# Poll interval (seconds) for checking pod status during wait_ready
POLL_INTERVAL=5
# Max consecutive crash restarts before giving up
MAX_CRASHES=3

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

copy_secret() {
  local sec=$1 src_ns=$2 dst_ns=$3
  if kubectl -n "$src_ns" get secret "$sec" &>/dev/null; then
    kubectl -n "$src_ns" get secret "$sec" -o yaml \
      | sed "s/namespace: $src_ns/namespace: $dst_ns/" \
      | kubectl apply -n "$dst_ns" -f - 2>/dev/null || true
  fi
}

# Prepare a namespace with the standard configmaps/secrets all MOSIP services need.
setup_ns() {
  local ns=$1
  ensure_ns "$ns"
  copy_cm global default "$ns"
  copy_cm artifactory-share artifactory "$ns" 2>/dev/null || true
  copy_cm config-server-share config-server "$ns" 2>/dev/null || true
  copy_cm keycloak-host default "$ns" 2>/dev/null || true
  copy_cm softhsm-kernel-share softhsm "$ns" 2>/dev/null || true
  ensure_db_secret "$ns"
}

# Create db-common-secrets in a namespace from the postgres password.
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

# Wait for a deployment to be fully ready (1/1 Running).
# Actively polls pod status and logs every POLL_INTERVAL seconds.
# Detects crashes (CrashLoopBackOff, Error, OOMKilled) immediately
# instead of waiting for a timeout.
#
# Usage: wait_ready <namespace> <deployment>
wait_ready() {
  local ns=$1 deploy=$2
  local prev_restarts=0 crash_count=0

  echo "  Waiting for $deploy..."
  while true; do
    # Get pod status line (newest non-Terminating pod matching the deploy name)
    local pod_line
    pod_line=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null \
      | grep "^$deploy" | grep -v Terminating | head -1)

    if [ -z "$pod_line" ]; then
      echo "    No pod found yet for $deploy, waiting..."
      sleep $POLL_INTERVAL
      continue
    fi

    local pod_name ready status restarts
    pod_name=$(echo "$pod_line" | awk '{print $1}')
    ready=$(echo "$pod_line" | awk '{print $2}')
    status=$(echo "$pod_line" | awk '{print $3}')
    restarts=$(echo "$pod_line" | awk '{print $4}' | sed 's/(.*//')

    # --- Success: pod is Ready ---
    if [ "$ready" = "1/1" ] && [ "$status" = "Running" ]; then
      echo "  $deploy is Ready (1/1 Running)."
      return 0
    fi

    # --- Crash detection ---
    case "$status" in
      CrashLoopBackOff|Error|OOMKilled|ImagePullBackOff|ErrImagePull|InvalidImageName)
        echo "    $deploy is in $status — checking logs..."
        kubectl -n "$ns" logs "$pod_name" --tail=10 2>&1 \
          | grep -iE "error|exception|fatal|killed|denied|refused|incorrect" \
          | tail -3
        crash_count=$((crash_count + 1))
        if [ "$crash_count" -ge "$MAX_CRASHES" ]; then
          echo "  FATAL: $deploy crashed $crash_count times ($status). Aborting."
          echo "  Full logs: kubectl -n $ns logs $pod_name"
          return 1
        fi
        echo "    Crash $crash_count/$MAX_CRASHES — will retry..."
        ;;
      Init:*)
        # Init container running or failing
        echo "    $deploy init: $status"
        if echo "$status" | grep -qE "CrashLoopBackOff|Error|ImagePull"; then
          echo "    Init container failing — checking..."
          kubectl -n "$ns" logs "$pod_name" -c "$(kubectl -n "$ns" get pod "$pod_name" -o jsonpath='{.spec.initContainers[0].name}' 2>/dev/null)" --tail=5 2>&1 | tail -3
          crash_count=$((crash_count + 1))
          if [ "$crash_count" -ge "$MAX_CRASHES" ]; then
            echo "  FATAL: $deploy init crashed $crash_count times. Aborting."
            return 1
          fi
        fi
        ;;
      Running)
        # Running but not Ready yet — still starting up (Spring Boot takes time)
        if [ "$((restarts))" -gt "$((prev_restarts))" ]; then
          echo "    $deploy restarted (restarts: $restarts) — checking logs..."
          kubectl -n "$ns" logs "$pod_name" --previous --tail=5 2>&1 \
            | grep -iE "error|exception|fatal|killed" | tail -2 || true
          prev_restarts=$restarts
          crash_count=$((crash_count + 1))
          if [ "$crash_count" -ge "$MAX_CRASHES" ]; then
            echo "  FATAL: $deploy restarted $crash_count times. Aborting."
            return 1
          fi
        else
          echo "    $deploy: $ready $status (starting up...)"
        fi
        ;;
      ContainerCreating|PodInitializing|Pending|CreateContainerConfigError)
        # CreateContainerConfigError may resolve once dependencies are ready
        if [ "$status" = "CreateContainerConfigError" ]; then
          echo "    $deploy: $status (waiting for dependencies...)"
          kubectl -n "$ns" describe pod "$pod_name" 2>&1 | grep "Error:" | tail -1
        else
          echo "    $deploy: $status"
        fi
        ;;
      *)
        echo "    $deploy: $ready $status"
        ;;
    esac

    sleep $POLL_INTERVAL
  done
}

# Install a MOSIP helm chart with JVM override and minimal resources.
# Does NOT wait — call wait_ready separately if needed.
# Usage: helm_install <namespace> <release> <chart> [extra helm args...]
helm_install() {
  local ns=$1 release=$2 chart=$3
  shift 3
  echo "  Installing $release..."
  helm upgrade --install "$release" "mosip/$chart" \
    -n "$ns" --version "$CHART_VERSION" \
    --set "additionalResources.javaOpts=$JVM_OPTS" \
    --set resources.requests.cpu=$REQ_CPU \
    --set resources.requests.memory=$REQ_MEM \
    --set resources.limits.cpu=$LIM_CPU \
    --set resources.limits.memory=$LIM_MEM \
    --timeout 5m \
    "$@"
}

# Install a MOSIP chart, then wait for it to be ready.
# Usage: install_mosip_chart <namespace> <release> <chart> [extra helm args...]
install_mosip_chart() {
  helm_install "$@"
  wait_ready "$1" "$2"
}

# Patch a deployment's init container to skip SSL cert import (not needed locally).
skip_cacerts_init() {
  local ns=$1 deploy=$2
  kubectl -n "$ns" patch deploy "$deploy" --type='json' \
    -p='[{"op":"replace","path":"/spec/template/spec/initContainers/0/command","value":["sh","-c","echo skipping cacerts for local dev"]},{"op":"replace","path":"/spec/template/spec/initContainers/0/image","value":"eclipse-temurin:11-jre"}]' \
    2>/dev/null || true
}

# ---------- Layer 0: conf-secrets ----------

install_conf_secrets() {
  echo "=== Layer 0: conf-secrets ==="
  local NS=conf-secrets
  ensure_ns $NS
  helm upgrade --install conf-secrets mosip/conf-secrets \
    -n $NS --version $CHART_VERSION --wait --timeout 3m
  echo "  conf-secrets installed."
}

# ---------- Layer 1: config-server ----------

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

  # Stub keycloak-client-secrets
  if ! kubectl -n "$ns" get secret keycloak-client-secrets &>/dev/null; then
    kubectl -n "$ns" create secret generic keycloak-client-secrets \
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

  # Copy secrets from source namespaces (or create stubs if source doesn't exist)
  copy_secret softhsm-kernel softhsm "$ns"
  copy_secret softhsm-ida softhsm "$ns"
  copy_secret activemq-activemq-artemis activemq "$ns"
  # Stub ActiveMQ secret if it wasn't copied (minimal profile — activemq not installed)
  if ! kubectl -n "$ns" get secret activemq-activemq-artemis &>/dev/null; then
    kubectl -n "$ns" create secret generic activemq-activemq-artemis \
      --from-literal=artemis-password=placeholder
  fi

  # keycloak-host configmap
  if ! kubectl -n "$ns" get cm keycloak-host &>/dev/null; then
    kubectl -n "$ns" create configmap keycloak-host \
      --from-literal=keycloak-internal-url="http://keycloak.keycloak/auth" \
      --from-literal=keycloak-internal-host="keycloak.keycloak" \
      --from-literal=keycloak-external-url="http://iam.mosip.localhost:30080/auth" \
      --from-literal=keycloak-external-host="iam.mosip.localhost"
  fi

  # Copy conf-secrets-various from conf-secrets namespace
  copy_secret conf-secrets-various conf-secrets "$ns"

  # Stub s3 configmap + secret (chart references both types)
  if ! kubectl -n "$ns" get cm s3 &>/dev/null; then
    kubectl -n "$ns" create configmap s3 \
      --from-literal=s3-region="" \
      --from-literal=s3-pretext-value="s3a://" \
      --from-literal=s3-user-key=minioadmin \
      --from-literal=s3-user-secret=minioadmin
  fi
  if ! kubectl -n "$ns" get secret s3 &>/dev/null; then
    kubectl -n "$ns" create secret generic s3 \
      --from-literal=s3-region="" \
      --from-literal=s3-pretext-value="s3a://" \
      --from-literal=s3-user-key=minioadmin \
      --from-literal=s3-user-secret=minioadmin
  fi

  # Stub msg-gateway configmap + secret
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

  # Stub mosip-captcha secret
  if ! kubectl -n "$ns" get secret mosip-captcha &>/dev/null; then
    kubectl -n "$ns" create secret generic mosip-captcha \
      --from-literal=prereg-captcha-site-key=dummy \
      --from-literal=prereg-captcha-secret-key=dummy \
      --from-literal=resident-captcha-site-key=dummy \
      --from-literal=resident-captcha-secret-key=dummy
  fi

  # Copy keycloak admin password secret
  copy_secret keycloak keycloak "$ns"
}

install_config_server() {
  echo "=== Layer 1: config-server ==="
  local NS=config-server
  ensure_ns $NS
  copy_cm global default $NS
  copy_cm keycloak-host default $NS 2>/dev/null || true
  ensure_db_secret $NS

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
    --timeout 5m

  # Patch to Recreate strategy — prevents duplicate config-server pods during
  # rolling updates which causes port conflicts and stale config.
  kubectl -n $NS patch deploy config-server --type=json \
    -p='[{"op":"remove","path":"/spec/strategy/rollingUpdate"},{"op":"replace","path":"/spec/strategy/type","value":"Recreate"}]' \
    2>/dev/null || true

  wait_ready $NS config-server
}

# ---------- Layer 1.5: artifactory ----------

install_artifactory() {
  echo "=== Layer 1.5: artifactory ==="
  local NS=artifactory
  ensure_ns $NS
  setup_ns $NS
  helm upgrade --install artifactory mosip/artifactory \
    -n $NS --version $CHART_VERSION \
    --set resources.requests.cpu=10m \
    --set resources.requests.memory=64Mi \
    --set resources.limits.cpu=200m \
    --set resources.limits.memory=256Mi \
    --timeout 5m
  echo "  artifactory installed."
}

# ---------- Layer 2: keymanager ----------

install_keymanager() {
  echo "=== Layer 2: keymanager ==="
  local NS=keymanager
  setup_ns $NS
  copy_cm softhsm-kernel-share softhsm $NS

  # NOTE: keygen job is skipped on local dev — it has a known NPE with
  # Spring Boot 3.x classloader when loading the JDBC driver class.
  # Keymanager generates keys on first request if they don't exist.
  echo "  Skipping keygen (keys generated on first use)..."

  echo "  Installing keymanager service..."
  helm upgrade --install keymanager mosip/keymanager \
    -n $NS --version $CHART_VERSION \
    --set "additionalResources.javaOpts=$JVM_OPTS" \
    --set resources.requests.cpu=$REQ_CPU \
    --set resources.requests.memory=$REQ_MEM \
    --set resources.limits.cpu=$LIM_CPU \
    --set resources.limits.memory=$LIM_MEM \
    --timeout 5m
  wait_ready $NS keymanager
}

# ---------- Layer 3: kernel ----------

install_kernel() {
  echo "=== Layer 3: kernel (9 sub-services, deployed sequentially) ==="
  local NS=kernel
  setup_ns $NS
  local ADMIN_HOST
  ADMIN_HOST=$(kubectl get cm global -o jsonpath='{.data.mosip-admin-host}')

  # Deploy each kernel service sequentially.
  # Helm install → patch init container → wait for Ready.
  # This keeps memory pressure low (only 1 JVM starting at a time).
  for svc in authmanager auditmanager idgenerator otpmanager pridgenerator ridgenerator syncdata notifier; do
    helm_install $NS "$svc" "$svc" --set enable_insecure=true
    # Patch init containers BEFORE waiting — openjdk:11-jre is removed from Docker Hub
    skip_cacerts_init $NS "$svc"
    wait_ready $NS "$svc"
  done

  # masterdata needs CORS policy for Istio VirtualService
  helm_install $NS masterdata masterdata \
    --set "istio.corsPolicy.allowOrigins[0].prefix=*"
  skip_cacerts_init $NS masterdata
  wait_ready $NS masterdata
}

# ---------- Layer 4: idrepo ----------

install_idrepo() {
  echo "=== Layer 4: idrepo (3 sub-services) ==="
  local NS=idrepo
  setup_ns $NS

  # Salt generation job (must complete before services start)
  echo "  Running idrepo salt generation..."
  helm upgrade --install idrepo-saltgen mosip/idrepo-saltgen \
    -n $NS --version $CHART_VERSION \
    --wait --wait-for-jobs --timeout 10m

  for svc in identity credential vid; do
    helm_install $NS "$svc" "$svc"
    skip_cacerts_init $NS "$svc"
    wait_ready $NS "$svc"
  done
}

# ---------- Layer 5: websub ----------

install_websub() {
  echo "=== Layer 5: websub ==="
  local NS=websub
  setup_ns $NS
  install_mosip_chart $NS websub-consolidator websub-consolidator
  install_mosip_chart $NS websub websub
}

# ---------- Layer 5: biosdk ----------

install_biosdk() {
  echo "=== Layer 5: biosdk ==="
  local NS=biosdk
  setup_ns $NS
  install_mosip_chart $NS biosdk biosdk-service
}

# ---------- Layer 5: packetmanager + datashare ----------

install_packetmanager() {
  echo "=== Layer 5: packetmanager ==="
  local NS=packetmanager
  setup_ns $NS
  install_mosip_chart $NS packetmanager packetmanager
}

install_datashare() {
  echo "=== Layer 5: datashare ==="
  local NS=datashare
  setup_ns $NS
  install_mosip_chart $NS datashare datashare
}

# ---------- Layer 6: ida ----------

install_ida() {
  echo "=== Layer 6: ida ==="
  local NS=ida
  setup_ns $NS
  copy_cm softhsm-ida-share softhsm $NS 2>/dev/null || true

  # IDA key generation (uses ida profile, not kernel)
  echo "  Skipping ida-keygen (keys generated on first use)..."

  for svc in ida-auth ida-internal ida-otp; do
    helm_install $NS "$svc" "$svc" --set enable_insecure=true
    skip_cacerts_init $NS "$svc"
    wait_ready $NS "$svc"
  done
}

# ---------- Layer 6: regproc ----------

install_regproc() {
  echo "=== Layer 6: regproc ==="
  local NS=regproc
  setup_ns $NS

  # Salt generation
  echo "  Running regproc salt generation..."
  helm upgrade --install regproc-salt mosip/regproc-salt \
    -n $NS --version $CHART_VERSION \
    --wait --wait-for-jobs --timeout 10m

  for svc in regproc-workflow regproc-status regproc-camel regproc-pktserver regproc-group1 regproc-group2; do
    install_mosip_chart $NS "$svc" "$svc"
  done
}

# ---------- Layer 6: prereg ----------

install_prereg() {
  echo "=== Layer 6: prereg ==="
  local NS=prereg
  setup_ns $NS
  for svc in prereg-application prereg-booking prereg-datasync prereg-batchjob; do
    install_mosip_chart $NS "$svc" "$svc"
  done
  # UI (lightweight, no JVM override needed)
  helm upgrade --install prereg-ui mosip/prereg-ui \
    -n $NS --version $CHART_VERSION --timeout 3m
}

# ---------- Layer 6: pms ----------

install_pms() {
  echo "=== Layer 6: pms ==="
  local NS=pms
  setup_ns $NS
  install_mosip_chart $NS pms-partner pms-partner
  install_mosip_chart $NS pms-policy pms-policy
}

# ---------- Layer 6: mock-abis ----------

install_mock_abis() {
  echo "=== Layer 6: mock-abis + mock-mv ==="
  local NS=abis
  setup_ns $NS
  install_mosip_chart $NS mock-abis mock-abis
  install_mosip_chart $NS mock-mv mock-mv
}

# ---------- Layer 6: admin ----------

install_admin() {
  echo "=== Layer 6: admin ==="
  local NS=admin
  setup_ns $NS
  local ADMIN_HOST
  ADMIN_HOST=$(kubectl get cm global -o jsonpath='{.data.mosip-admin-host}')
  install_mosip_chart $NS admin-hotlist admin-hotlist
  install_mosip_chart $NS admin-service admin-service \
    --set "istio.corsPolicy.allowOrigins[0].prefix=*"
}

# ---------- Layer 6: mock-smtp ----------

install_mock_smtp() {
  echo "=== Layer 6: mock-smtp ==="
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

# ---------- Layer 6: captcha ----------

install_captcha() {
  echo "=== Layer 6: captcha ==="
  local NS=captcha
  ensure_ns $NS
  helm upgrade --install captcha mosip/captcha \
    -n $NS --version 0.1.0 \
    --set resources.requests.cpu=10m \
    --set resources.requests.memory=64Mi \
    --set resources.limits.cpu=500m \
    --set resources.limits.memory=$LIM_MEM \
    --timeout 5m
}

# ---------- Layer 6: masterdata-loader ----------

install_masterdata_loader() {
  echo "=== Layer 6: masterdata-loader ==="
  local NS=masterdata-loader
  setup_ns $NS
  helm upgrade --install masterdata-loader mosip/masterdata-loader \
    -n $NS --version $CHART_VERSION \
    --wait --wait-for-jobs --timeout 10m
}

# ---------- Layer 6: resident ----------

install_resident() {
  echo "=== Layer 6: resident ==="
  local NS=resident
  setup_ns $NS
  helm_install $NS resident resident --set enable_insecure=true
  skip_cacerts_init $NS resident
  wait_ready $NS resident
  helm upgrade --install resident-ui mosip/resident-ui \
    -n $NS --version $CHART_VERSION --timeout 3m
}

# ---------- status ----------

show_status() {
  echo "=== MOSIP Core Services Status ==="
  local ok=0 total=0
  for ns_dep in \
    "config-server/config-server" "keymanager/keymanager" \
    "kernel/authmanager" "kernel/auditmanager" "kernel/idgenerator" "kernel/masterdata" \
    "kernel/otpmanager" "kernel/pridgenerator" "kernel/ridgenerator" "kernel/syncdata" "kernel/notifier" \
    "idrepo/identity" "idrepo/credential" "idrepo/vid" \
    "websub/websub" "websub/websub-consolidator" \
    "biosdk/biosdk-biosdk-service" "packetmanager/packetmanager" "datashare/datashare" \
    "ida/ida-auth" "ida/ida-internal" "ida/ida-otp" \
    "regproc/regproc-workflow" "regproc/regproc-status" \
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
    install_conf_secrets        # Layer 0
    install_config_server       # Layer 1 (waits until Ready)
    install_artifactory         # Layer 1.5
    install_keymanager          # Layer 2 (waits until Ready)
    install_kernel              # Layer 3 (each of 9 services waits)
    install_idrepo              # Layer 4 (each of 3 services waits)
    echo ""
    echo "Minimal MOSIP services installed."
    echo "Requires: ./install-external.sh minimal"
    echo "Use './install-services.sh core' to add websub, biosdk, ida, etc."
    show_status
    ;;
  core)
    add_helm_repos
    install_conf_secrets        # Layer 0
    install_config_server       # Layer 1
    install_artifactory         # Layer 1.5
    install_keymanager          # Layer 2
    install_kernel              # Layer 3
    install_idrepo              # Layer 4
    install_websub              # Layer 5
    install_biosdk              # Layer 5
    install_packetmanager       # Layer 5
    install_datashare           # Layer 5
    install_ida                 # Layer 6
    echo ""
    echo "Core MOSIP services installed."
    echo "Requires: ./install-external.sh core"
    echo "Use './install-services.sh all' to add regproc, prereg, admin, pms, resident."
    show_status
    ;;
  all)
    add_helm_repos
    install_conf_secrets        # Layer 0
    install_config_server       # Layer 1
    install_artifactory         # Layer 1.5
    install_captcha             # Layer 1.5
    install_keymanager          # Layer 2
    install_kernel              # Layer 3
    install_idrepo              # Layer 4
    install_websub              # Layer 5
    install_mock_smtp           # Layer 5
    install_biosdk              # Layer 5
    install_packetmanager       # Layer 5
    install_datashare           # Layer 5
    install_masterdata_loader   # Layer 6
    install_prereg              # Layer 6
    install_pms                 # Layer 6
    install_mock_abis           # Layer 6
    install_regproc             # Layer 6
    install_admin               # Layer 6
    install_ida                 # Layer 6
    install_resident            # Layer 6
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
    echo "Profiles (RAM required for MOSIP services only, add ~3GB for external components):"
    echo "  minimal — config-server + kernel + idrepo + keymanager (~6GB RAM)"
    echo "  core    — + websub + biosdk + packetmanager + datashare + ida (~10GB RAM)"
    echo "  all     — + regproc + prereg + admin + pms + resident (~16GB RAM)"
    echo ""
    echo "Deployment is SEQUENTIAL by dependency layer. Each service waits until"
    echo "fully Ready before the next starts, preventing memory thrashing."
    exit 1
    ;;
esac

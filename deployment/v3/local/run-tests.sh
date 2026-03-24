#!/bin/bash
# Runs MOSIP API tests against the local Docker Desktop cluster.
# Wraps the upstream apitestrig Helm chart with local-dev defaults
# (no interactive prompts, self-signed certs, local S3/DB endpoints).
#
# This script does NOT modify the upstream testrig/ directory.
#
# Prerequisites:
#   - install-external.sh and install-services.sh already running
#   - MinIO deployed (core profile) OR pass --no-s3 to skip report storage
#
# Usage:
#   ./run-tests.sh [minimal|core|all|status|teardown]
#
# Profiles control which test modules are enabled:
#   minimal — masterdata + idrepo only (matches minimal service profile)
#   core    — + auth (matches core service profile)
#   all     — + prereg + partner + resident (matches all service profile)

set -e
set -o errexit
set -o nounset
set -o errtrace
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTRIG_DIR="$SCRIPT_DIR/../testrig/apitestrig"
PROFILE="${1:-minimal}"
NS=apitestrig
CHART_VERSION=1.3.5

# ---------- helpers ----------

ensure_ns() {
  kubectl create ns "$1" 2>/dev/null || true
}

copy_resource() {
  local kind=$1 name=$2 src_ns=$3 dst_ns=$4
  kubectl -n "$src_ns" get "$kind" "$name" -o yaml 2>/dev/null \
    | sed "s/namespace: $src_ns/namespace: $dst_ns/" \
    | kubectl apply -n "$dst_ns" -f - 2>/dev/null || true
}

wait_job() {
  local ns=$1 job=$2
  echo "  Waiting for job $job..."
  for i in $(seq 1 120); do
    local status
    status=$(kubectl -n "$ns" get job "$job" -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "")
    if [ "$status" = "Complete" ]; then echo "  Job $job completed."; return 0; fi
    if [ "$status" = "Failed" ]; then
      echo "  Job $job FAILED."
      kubectl -n "$ns" logs "job/$job" --tail=20 2>&1 | grep -iE "fail|error|assert" | tail -5
      return 1
    fi
    # Show pod status
    local pod_status
    pod_status=$(kubectl -n "$ns" get pods -l "job-name=$job" --no-headers 2>/dev/null | head -1 | awk '{print $3}')
    echo "    ($i) $pod_status"
    sleep 5
  done
  echo "  Timed out waiting for job $job"
  return 1
}

# ---------- prereqs ----------

run_prereqs() {
  echo "=== Configuring config-server for test rig ==="

  # Add testrig client to allowed audiences (non-destructive — appends to existing)
  kubectl -n config-server set env deploy/config-server \
    SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_AUTH_SERVER_ADMIN_ALLOWED_AUDIENCE_IDREPO_OVERRIDE="mosip-regproc-client,mosip-prereg-client,mosip-admin-client,mosip-crereq-client,mosip-creser-client,mosip-datsha-client,mosip-ida-client,mosip-resident-client,mosip-reg-client,mpartner-default-print,mosip-idrepo-client,mpartner-default-auth,mosip-syncdata-client,mosip-masterdata-client,mosip-idrepo-client,mosip-pms-client,mosip-hotlist-client,opencrvs-partner,mpartner-default-digitalcard,mpartner-default-mobile,mosip-signup-client,mosip-testrig-client"

  kubectl -n config-server set env deploy/config-server \
    SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_IDREPO_CREDENTIAL_REQUEST_ENABLE_CONVENTION_BASED_ID_IDREPO_OVERRIDE="true"

  kubectl -n config-server set env deploy/config-server \
    SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_AUTH_SERVER_ADMIN_ALLOWED_AUDIENCE_KERNEL_OVERRIDE="mosip-toolkit-android-client,mosip-toolkit-client,mosip-regproc-client,mosip-prereg-client,mosip-admin-client,mosip-crereq-client,mosip-creser-client,mosip-datsha-client,mosip-ida-client,mosip-resident-client,mosip-reg-client,mpartner-default-print,mosip-idrepo-client,mpartner-default-auth,mosip-syncdata-client,mosip-masterdata-client,mosip-idrepo-client,mosip-pms-client,mosip-hotlist-client,mobileid_newlogic,opencrvs-partner,mosip-deployment-client,mpartner-default-digitalcard,mpartner-default-mobile,mosip-signup-client,mosip-testrig-client"

  kubectl -n config-server set env deploy/config-server \
    SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_PREREGISTRATION_CAPTCHA_ENABLE_OVERRIDE="false"

  # Wait for config-server to restart
  echo "  Waiting for config-server restart..."
  kubectl -n config-server rollout status deploy/config-server --timeout=120s
  echo "  Config-server ready with test overrides."
}

# ---------- setup namespace ----------

setup_testrig_ns() {
  echo "=== Setting up $NS namespace ==="
  ensure_ns $NS

  # Copy configmaps
  copy_resource configmap global default $NS
  copy_resource configmap keycloak-host default $NS   # keycloak-host is in default ns
  copy_resource configmap artifactory-share artifactory $NS
  copy_resource configmap config-server-share config-server $NS

  # Copy secrets
  copy_resource secret keycloak-client-secrets keycloak $NS
  copy_resource secret s3 minio $NS 2>/dev/null || \
    copy_resource secret s3 config-server $NS  # Fallback to config-server stub
  copy_resource secret postgres-postgresql postgres $NS

  echo "  Namespace $NS ready."
}

# ---------- install ----------

install_testrig() {
  local values_file="$SCRIPT_DIR/values-apitestrig-local.yaml"
  local api_host
  api_host=$(kubectl get cm global -o jsonpath='{.data.mosip-api-internal-host}')
  local env_user
  env_user=$(echo "$api_host" | awk -F '.' '{print $1"."$2}')

  # Select modules based on profile
  local module_overrides=""
  case "$PROFILE" in
    minimal)
      module_overrides="--set modules.prereg.enabled=false --set modules.partner.enabled=false --set modules.resident.enabled=false --set modules.auth.enabled=false"
      ;;
    poc)
      module_overrides="--set modules.prereg.enabled=false --set modules.partner.enabled=false --set modules.resident.enabled=false --set modules.auth.enabled=true"
      ;;
    all)
      module_overrides=""  # All enabled from upstream values.yaml
      ;;
  esac

  echo "=== Installing apitestrig (profile: $PROFILE) ==="
  helm upgrade --install apitestrig mosip/apitestrig \
    -n $NS \
    --version $CHART_VERSION \
    -f "$values_file" \
    --set crontime="0 */6 * * *" \
    --set apitestrig.configmaps.s3.s3-host='http://minio.minio:9000' \
    --set apitestrig.configmaps.s3.s3-user-key='admin' \
    --set apitestrig.configmaps.s3.s3-region='' \
    --set apitestrig.configmaps.db.db-server="postgres-postgresql.postgres" \
    --set apitestrig.configmaps.db.db-su-user="postgres" \
    --set apitestrig.configmaps.db.db-port="5432" \
    --set apitestrig.configmaps.apitestrig.ENV_USER="$env_user" \
    --set apitestrig.configmaps.apitestrig.ENV_ENDPOINT="http://$api_host" \
    --set apitestrig.configmaps.apitestrig.ENV_TESTLEVEL="smoke" \
    --set apitestrig.configmaps.apitestrig.reportExpirationInDays="3" \
    --set apitestrig.configmaps.apitestrig.slack-webhook-url="http://localhost:9999/noop" \
    --set apitestrig.configmaps.apitestrig.eSignetDeployed="no" \
    --set apitestrig.configmaps.apitestrig.NS="$NS" \
    --set enable_insecure=true \
    $module_overrides \
    --timeout 5m

  # Patch cronjob init containers — chart hardcodes openjdk:11-jre (removed from
  # Docker Hub) and the SSL import script references paths that don't exist in
  # replacement images. For local dev (HTTP, no SSL), skip the init entirely.
  echo "  Patching cronjob init containers (skip cacerts for local dev)..."
  for cj in $(kubectl -n $NS get cronjob --no-headers 2>/dev/null | awk '{print $1}'); do
    kubectl -n $NS patch cronjob "$cj" --type='json' \
      -p='[{"op":"replace","path":"/spec/jobTemplate/spec/template/spec/initContainers/0/image","value":"eclipse-temurin:11-jre"},{"op":"replace","path":"/spec/jobTemplate/spec/template/spec/initContainers/0/command","value":["/bin/bash","-c","echo skipping cacerts for local dev"]}]' \
      2>/dev/null || true
  done

  # Add hostAliases so test pods can reach api-internal.mosip.localhost and
  # iam.mosip.localhost via the in-cluster ingress-nginx ClusterIP.
  echo "  Patching cronjobs with hostAliases for ingress resolution..."
  local ingress_ip
  ingress_ip=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.clusterIP}')
  for cj in $(kubectl -n $NS get cronjob --no-headers 2>/dev/null | awk '{print $1}'); do
    kubectl -n $NS patch cronjob "$cj" --type='json' \
      -p="[{\"op\":\"add\",\"path\":\"/spec/jobTemplate/spec/template/spec/hostAliases\",\"value\":[{\"ip\":\"$ingress_ip\",\"hostnames\":[\"api-internal.mosip.localhost\",\"iam.mosip.localhost\",\"api.mosip.localhost\"]}]}]" \
      2>/dev/null || true
  done

  # Apply ingress rules so api-internal.mosip.localhost routes to MOSIP services
  echo "  Applying MOSIP ingress rules..."
  kubectl apply -f "$SCRIPT_DIR/ingress-mosip.yaml" 2>/dev/null || true

  echo "  Apitestrig installed (cronjob: every 6 hours)."
}

# ---------- run now ----------

run_now() {
  echo "=== Running tests NOW ==="
  local job_name="testrun-$(date +%s)"

  # Find cronjobs and trigger them
  local cronjobs
  cronjobs=$(kubectl -n $NS get cronjob --no-headers 2>/dev/null | awk '{print $1}')

  if [ -z "$cronjobs" ]; then
    echo "  No cronjobs found. Install first with: $0 minimal"
    return 1
  fi

  for cj in $cronjobs; do
    local jname="${cj}-${job_name}"
    echo "  Triggering $cj -> $jname"
    kubectl -n $NS create job "$jname" --from="cronjob/$cj"
  done

  echo ""
  echo "Tests started. Monitor with:"
  echo "  kubectl -n $NS get jobs"
  echo "  kubectl -n $NS logs job/<job-name> -f"
  echo ""
  echo "Or run: $0 status"
}

# ---------- status ----------

show_status() {
  echo "=== Apitestrig Status ==="

  echo ""
  echo "CronJobs:"
  kubectl -n $NS get cronjobs --no-headers 2>/dev/null | \
    awk '{printf "  %-40s schedule=%-15s last=%s\n", $1, $2, $6}' || echo "  None"

  echo ""
  echo "Recent Jobs:"
  kubectl -n $NS get jobs --no-headers 2>/dev/null | \
    awk '{printf "  %-50s %s\n", $1, $2}' | tail -10 || echo "  None"

  echo ""
  echo "Running Pods:"
  kubectl -n $NS get pods --no-headers 2>/dev/null | grep -v Completed | \
    awk '{printf "  %-50s %s %s\n", $1, $3, $4}' || echo "  None"

  echo ""
  echo "Completed Pods (last 5):"
  kubectl -n $NS get pods --no-headers 2>/dev/null | grep Completed | tail -5 | \
    awk '{printf "  %-50s %s\n", $1, $3}' || echo "  None"
}

# ---------- logs ----------

show_logs() {
  echo "=== Latest test logs ==="
  local latest_pod
  latest_pod=$(kubectl -n $NS get pods --sort-by=.metadata.creationTimestamp --no-headers 2>/dev/null | tail -1 | awk '{print $1}')
  if [ -n "$latest_pod" ]; then
    echo "  Pod: $latest_pod"
    echo "  ---"
    kubectl -n $NS logs "$latest_pod" --tail=50 2>&1
  else
    echo "  No pods found."
  fi
}

# ---------- teardown ----------

teardown() {
  echo "=== Tearing down apitestrig ==="
  helm uninstall apitestrig -n $NS 2>/dev/null || true
  kubectl delete ns $NS 2>/dev/null || true
  echo "  Teardown complete."
}

# ---------- main ----------

case "$PROFILE" in
  status)   show_status ;;
  logs)     show_logs ;;
  teardown) teardown ;;
  run)      run_now ;;
  minimal|poc|all)
    helm repo update 2>/dev/null || true
    run_prereqs
    setup_testrig_ns
    install_testrig
    echo ""
    echo "Run tests now with: $0 run"
    echo "Check status with:  $0 status"
    echo "View logs with:     $0 logs"
    ;;
  *)
    echo "Usage: $0 [minimal|poc|all|run|status|logs|teardown]"
    echo ""
    echo "Profiles (match your install-services.sh profile):"
    echo "  minimal — masterdata + idrepo tests"
    echo "  poc     — + auth tests"
    echo "  all     — + prereg + partner + resident tests"
    echo ""
    echo "Commands:"
    echo "  run      — trigger tests immediately"
    echo "  status   — show cronjobs, jobs, pods"
    echo "  logs     — show latest test pod logs"
    echo "  teardown — remove apitestrig"
    exit 1
    ;;
esac

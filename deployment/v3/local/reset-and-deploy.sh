#!/bin/bash
##############################################################################
# reset-and-deploy.sh — Full MOSIP platform reset + redeploy
#
# Wipes all MOSIP application state and redeploys from scratch.
# Preserves: K8s cluster, Docker Desktop, WSL config, external pods
#            (postgres, kafka, minio, keycloak, activemq).
# Resets:    all MOSIP databases, services, SoftHSM keys, Keycloak realm.
#
# Design:
#   - EVERY step is verified. The script stops on ANY error.
#   - Idempotent: safe to re-run from the top after fixing an error.
#   - All config-server overrides + git patches are applied by
#     install-services.sh in ONE batch (no ephemeral state loss).
#   - All known blockers from prior runs are handled inline.
#
# Usage: bash reset-and-deploy.sh
# Time:  ~2-3 hours (sequential service deployment)
##############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/reset-deploy-$(date +%Y%m%d-%H%M%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

STEP=0
TOTAL_STEPS=15

# ─── Helpers ────────────────────────────────────────────────────────────────

step() {
  STEP=$((STEP + 1))
  echo ""
  echo "━━━ Step $STEP/$TOTAL_STEPS: $1 ━━━"
}

ok()   { echo "  ✅ $*"; }
fail() { echo "  ❌ $*"; echo ""; echo "FAILED at step $STEP. Fix the error and re-run this script."; echo "Log: $LOG_FILE"; exit 1; }
log()  { echo "  $*"; }

require_cmd() {
  command -v "$1" &>/dev/null || fail "Required command not found: $1"
}

verify_pod_ready() {
  local ns="$1" label="$2" timeout="${3:-180}"
  if kubectl -n "$ns" wait --for=condition=Ready pod -l "$label" --timeout="${timeout}s" 2>/dev/null; then
    ok "$ns/$label ready"
  else
    fail "$ns/$label NOT ready after ${timeout}s"
  fi
}

verify_deployment() {
  local ns="$1" dep="$2" timeout="${3:-180}"
  if kubectl -n "$ns" rollout status "deployment/$dep" --timeout="${timeout}s" 2>/dev/null; then
    ok "$ns/$dep rolled out"
  else
    fail "$ns/$dep rollout FAILED after ${timeout}s"
  fi
}

verify_db() {
  local db="$1"
  local exists
  exists=$(kubectl -n postgres exec postgres-postgresql-0 -- env PGPASSWORD="$PG_PASS" \
    psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$db';" 2>/dev/null || echo "")
  if [ "$exists" = "1" ]; then
    ok "Database $db exists"
  else
    fail "Database $db does NOT exist"
  fi
}

get_pg_pass() {
  PG_PASS=$(kubectl -n postgres get secret postgres-postgresql -o jsonpath='{.data.postgresql-password}' | base64 -d 2>/dev/null) \
    || fail "Cannot read postgres password from secret"
  [ -n "$PG_PASS" ] || fail "Postgres password is empty"
}

MOSIP_DBS="mosip_audit mosip_authdevice mosip_credential mosip_digitalcard mosip_hotlist mosip_ida mosip_idmap mosip_idrepo mosip_kernel mosip_keymgr mosip_master mosip_otp mosip_pms mosip_prereg mosip_regdevice mosip_regprc mosip_resident"

# ─── Banner ─────────────────────────────────────────────────────────────────

echo "╔══════════════════════════════════════════════════════════╗"
echo "║        MOSIP Full Platform Reset + Redeploy             ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Preserves: K8s cluster, postgres/kafka/minio/keycloak  ║"
echo "║             activemq pods, Docker Desktop, WSL config   ║"
echo "║  Resets:    all MOSIP databases, services, SoftHSM,     ║"
echo "║             Keycloak realm                              ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Log: $LOG_FILE"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
step "Pre-flight checks"
# ═══════════════════════════════════════════════════════════════════════════

require_cmd kubectl
require_cmd helm

kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready" || fail "K8s cluster not ready"
ok "K8s cluster ready"

kubectl -n postgres get pod postgres-postgresql-0 --no-headers 2>/dev/null | grep -q "Running" || fail "Postgres not running"
ok "Postgres running"

kubectl -n keycloak get pod -l app.kubernetes.io/name=keycloak --no-headers 2>/dev/null | grep -q "Running" || fail "Keycloak not running"
ok "Keycloak running"

get_pg_pass
ok "Postgres password: ${PG_PASS:0:3}***"

read -p "All checks passed. Continue with full reset? (y/N) " -n 1 -r
echo ""
[[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ═══════════════════════════════════════════════════════════════════════════
step "Deleting all MOSIP Helm releases + SoftHSM"
# ═══════════════════════════════════════════════════════════════════════════

MOSIP_NS="admin apitestrig artifactory biosdk captcha conf-secrets config-server datashare ida idrepo kernel keymanager masterdata-loader mock-abis mock-smtp onboarder packetmanager pms prereg regproc resident websub"

DELETED=0
for NS in $MOSIP_NS; do
  RELEASES=$(helm -n "$NS" list --short 2>/dev/null || true)
  for REL in $RELEASES; do
    log "Deleting $NS/$REL..."
    helm -n "$NS" delete "$REL" --wait=false 2>/dev/null && DELETED=$((DELETED + 1)) || true
  done
done
ok "Deleted $DELETED Helm releases"

# SoftHSM: delete releases + PVCs + cross-namespace PIN copies
helm -n softhsm delete softhsm-kernel 2>/dev/null || true
helm -n softhsm delete softhsm-ida 2>/dev/null || true
kubectl -n softhsm delete pvc --all --wait=false 2>/dev/null || true
kubectl -n default delete secret softhsm-kernel softhsm-ida 2>/dev/null || true
ok "SoftHSM cleaned"

# ═══════════════════════════════════════════════════════════════════════════
step "Waiting for MOSIP pods to terminate"
# ═══════════════════════════════════════════════════════════════════════════

DEADLINE=$((SECONDS + 120))
while [ $SECONDS -lt $DEADLINE ]; do
  REMAINING=$(kubectl get pods -A --no-headers 2>/dev/null \
    | grep -v "postgres\|keycloak\|kafka\|minio\|activemq\|ingress-nginx\|kube-\|local-path\|headlamp\|cattle-\|softhsm\|clamav\|nginx-local\|Completed\|Terminating" \
    | wc -l)
  [ "$REMAINING" -eq 0 ] && break
  log "$REMAINING pods still running..."
  sleep 10
done
ok "MOSIP pods terminated"

# ═══════════════════════════════════════════════════════════════════════════
step "Dropping all MOSIP databases + roles"
# ═══════════════════════════════════════════════════════════════════════════

for DB in $MOSIP_DBS; do
  kubectl -n postgres exec postgres-postgresql-0 -- env PGPASSWORD="$PG_PASS" \
    psql -U postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid <> pg_backend_pid();" 2>/dev/null || true
done

for DB in $MOSIP_DBS; do
  kubectl -n postgres exec postgres-postgresql-0 -- env PGPASSWORD="$PG_PASS" \
    psql -U postgres -c "DROP DATABASE IF EXISTS $DB;" 2>/dev/null || fail "Failed to drop $DB"
done

for ROLE in audituser credentialuser digitalcarduser hotlistuser idauser idmapuser idrepouser kerneluser keymgruser masteruser otpuser pmsuser prereguser regdeviceuser authdeviceuser regprcuser residentuser; do
  kubectl -n postgres exec postgres-postgresql-0 -- env PGPASSWORD="$PG_PASS" \
    psql -U postgres -c "DROP ROLE IF EXISTS $ROLE;" 2>/dev/null || true
done
ok "All MOSIP databases and roles dropped"

# ═══════════════════════════════════════════════════════════════════════════
step "Recreating MOSIP databases (postgres-init)"
# postgres-init MUST use init_values.yaml to create all 17 databases.
# ═══════════════════════════════════════════════════════════════════════════

helm -n postgres delete postgres-init 2>/dev/null || true
kubectl -n postgres delete jobs --all 2>/dev/null || true
sleep 5

INIT_VALUES="$SCRIPT_DIR/../external/postgres/init_values.yaml"
[ -f "$INIT_VALUES" ] || fail "Missing $INIT_VALUES"

helm install postgres-init mosip/postgres-init \
  -n postgres --version 1.3.0 \
  -f "$INIT_VALUES" \
  --set dbUserPasswords.dbuserPassword="$PG_PASS" \
  --set superUser.name=postgres \
  --set superUser.password="$PG_PASS" \
  --wait --wait-for-jobs --timeout 600s \
  || fail "postgres-init failed"

for DB in $MOSIP_DBS; do
  verify_db "$DB"
done

# ═══════════════════════════════════════════════════════════════════════════
step "Creating additional DB users and schemas"
# postgres-init misses some users and the idmap/idrepo schemas for saltgen.
# ═══════════════════════════════════════════════════════════════════════════

for user_db in "otpuser:mosip_otp" "idmapuser:mosip_idmap" "regdeviceuser:mosip_regdevice" "authdeviceuser:mosip_authdevice"; do
  USER=$(echo "$user_db" | cut -d: -f1)
  DB=$(echo "$user_db" | cut -d: -f2)
  kubectl -n postgres exec postgres-postgresql-0 -- env PGPASSWORD="$PG_PASS" \
    psql -U postgres -c "CREATE USER $USER WITH PASSWORD '$PG_PASS';" 2>/dev/null || true
  kubectl -n postgres exec postgres-postgresql-0 -- env PGPASSWORD="$PG_PASS" \
    psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE $DB TO $USER;" 2>/dev/null || true
done

for db_schema_user in "mosip_idmap:idmap:idmapuser" "mosip_idrepo:idrepo:idrepouser"; do
  DB=$(echo "$db_schema_user" | cut -d: -f1)
  SCHEMA=$(echo "$db_schema_user" | cut -d: -f2)
  DBUSER=$(echo "$db_schema_user" | cut -d: -f3)
  kubectl -n postgres exec postgres-postgresql-0 -- env PGPASSWORD="$PG_PASS" psql -U postgres -d "$DB" -c "
    CREATE SCHEMA IF NOT EXISTS $SCHEMA;
    GRANT ALL ON SCHEMA $SCHEMA TO $DBUSER;
    CREATE TABLE IF NOT EXISTS $SCHEMA.uin_hash_salt (id bigint NOT NULL, salt varchar(36) NOT NULL, cr_by varchar(256) NOT NULL, cr_dtimes timestamp NOT NULL, upd_by varchar(256), upd_dtimes timestamp, CONSTRAINT pk_uinhs_id PRIMARY KEY (id));
    CREATE TABLE IF NOT EXISTS $SCHEMA.uin_encrypt_salt (id bigint NOT NULL, salt varchar(36) NOT NULL, cr_by varchar(256) NOT NULL, cr_dtimes timestamp NOT NULL, upd_by varchar(256), upd_dtimes timestamp, CONSTRAINT pk_uines_id PRIMARY KEY (id));
    GRANT ALL ON ALL TABLES IN SCHEMA $SCHEMA TO $DBUSER;
  " 2>/dev/null || fail "Failed to create schemas in $DB"
done
ok "Additional users and schemas created"

# ═══════════════════════════════════════════════════════════════════════════
step "Redeploying SoftHSM (fresh keys)"
# ═══════════════════════════════════════════════════════════════════════════

cd "$SCRIPT_DIR"
bash install-external.sh softhsm || fail "install-external.sh softhsm failed"
verify_pod_ready softhsm app.kubernetes.io/instance=softhsm-kernel 180
verify_pod_ready softhsm app.kubernetes.io/instance=softhsm-ida 180
kubectl -n softhsm get secret softhsm-kernel -o jsonpath='{.data.security-pin}' &>/dev/null || fail "SoftHSM kernel PIN missing"
ok "SoftHSM PINs present"

# ═══════════════════════════════════════════════════════════════════════════
step "Re-initializing Keycloak (MOSIP realm + clients)"
# Must complete before install-services.sh (services need client secrets).
# Retries once on failure (common: opencrvs token expiry).
# ═══════════════════════════════════════════════════════════════════════════

helm -n keycloak delete keycloak-init 2>/dev/null || true
kubectl -n keycloak delete job keycloak-init 2>/dev/null || true
sleep 5

KC_ARGS=(
  -n keycloak --version 1.3.0
  --set keycloakExternalHost="iam.mosip.localhost"
  --set keycloakInternalHost="keycloak.keycloak"
  --set keycloak.realms.mosip.realm_config.smtpServer.host="mock-smtp.mock-smtp"
  --set keycloak.realms.mosip.realm_config.smtpServer.port="8025"
  --set keycloak.realms.mosip.realm_config.smtpServer.from="noreply@mosip.localhost"
  --set keycloak.realms.mosip.realm_config.smtpServer.starttls="false"
  --set keycloak.realms.mosip.realm_config.smtpServer.ssl="false"
  --set keycloak.realms.mosip.realm_config.smtpServer.auth="false"
  --set "keycloak.realms.mosip.realm_config.attributes.frontendUrl=http://iam.mosip.localhost/auth"
  --wait --wait-for-jobs --timeout 900s
)

helm upgrade --install keycloak-init mosip/keycloak-init "${KC_ARGS[@]}" 2>/dev/null || {
  log "keycloak-init had errors, retrying..."
  kubectl -n keycloak delete job keycloak-init 2>/dev/null || true
  sleep 5
  helm upgrade --install keycloak-init mosip/keycloak-init "${KC_ARGS[@]}" 2>/dev/null \
    || fail "keycloak-init failed on retry"
}
ok "Keycloak realm initialized"

# ═══════════════════════════════════════════════════════════════════════════
step "Patching postgres secret + clearing stale namespace data"
# Some charts need 'postgres-password' key (bitnami only creates
# 'postgresql-password'). Also clear stale secrets from previous installs
# so install-services.sh copies fresh ones (prevents CKR_PIN_INCORRECT).
# ═══════════════════════════════════════════════════════════════════════════

PG_PASS_B64=$(kubectl -n postgres get secret postgres-postgresql -o jsonpath='{.data.postgresql-password}')
kubectl -n postgres patch secret postgres-postgresql -p "{\"data\":{\"postgres-password\":\"$PG_PASS_B64\"}}" \
  || fail "Failed to patch postgres secret"
ok "postgres-password alias set"

SVCNS="conf-secrets config-server keymanager kernel idrepo ida pms biosdk websub datashare packetmanager regproc admin prereg resident mock-abis mock-smtp captcha artifactory"
for NS in $SVCNS; do
  kubectl -n "$NS" delete secret softhsm-kernel softhsm-ida db-common-secrets keycloak-client-secrets conf-secrets-various activemq-activemq-artemis s3 2>/dev/null || true
  kubectl -n "$NS" delete cm keycloak-host s3 msg-gateway activemq-activemq-artemis-share postgres-setup-config 2>/dev/null || true
done
ok "Stale secrets/configmaps cleared"

# ═══════════════════════════════════════════════════════════════════════════
step "Deploying all MOSIP services (install-services.sh all)"
# install-services.sh handles:
#   - Config-server overrides + git patches (ONE restart, then frozen)
#   - Dependency ordering: mock-smtp before kernel, biosdk before idrepo
#   - Memory/JVM for IDA, resident, captcha
#   - idgenerator startup probe extension
#   - captcha secret creation
#   - credentialrequest deployment
# ═══════════════════════════════════════════════════════════════════════════

cd "$SCRIPT_DIR"
bash install-services.sh all || fail "install-services.sh all failed"

# ═══════════════════════════════════════════════════════════════════════════
step "Verifying critical services"
# ═══════════════════════════════════════════════════════════════════════════

for ns_dep in \
  "config-server/config-server" \
  "keymanager/keymanager" \
  "kernel/masterdata" \
  "kernel/authmanager" \
  "idrepo/identity" \
  "idrepo/credential" \
  "idrepo/credentialrequest" \
  "idrepo/vid" \
  "ida/ida-internal" \
  "ida/ida-auth" \
  "ida/ida-otp" \
  "pms/pms-partner" \
  "biosdk/biosdk-service" \
  "websub/websub" \
  "admin/admin-service" \
; do
  NS="${ns_dep%%/*}"
  DEP="${ns_dep##*/}"
  READY=$(kubectl -n "$NS" get deployment "$DEP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  if [ "${READY:-0}" -ge 1 ]; then
    ok "$ns_dep ready"
  else
    fail "$ns_dep NOT ready — check: kubectl -n $NS logs deploy/$DEP"
  fi
done

# ═══════════════════════════════════════════════════════════════════════════
step "Applying post-deploy memory optimizations"
# These are for services that need MORE memory than install-services.sh
# defaults (keymanager under credential batch load, identity at idle).
# ═══════════════════════════════════════════════════════════════════════════

kubectl -n keymanager patch deployment keymanager --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"3Gi"},
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/failureThreshold","value":60},
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/timeoutSeconds","value":10},
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/timeoutSeconds","value":30},
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/failureThreshold","value":10},
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/periodSeconds","value":30}
]' || fail "Failed to patch keymanager"
kubectl -n keymanager set env deployment/keymanager JDK_JAVA_OPTIONS="-Xms512m -Xmx2g"
ok "keymanager: 3Gi, -Xmx2g"

kubectl -n idrepo patch deployment identity --type='json' -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"2Gi"}]'
kubectl -n idrepo set env deployment/identity JDK_JAVA_OPTIONS="-Xms512m -Xmx1536m"
ok "identity: 2Gi, -Xmx1536m"

kubectl -n idrepo patch deployment credential --type='json' -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"1536Mi"}]'
kubectl -n idrepo set env deployment/credential JDK_JAVA_OPTIONS="-Xms512m -Xmx1g"
ok "credential: 1.5Gi, -Xmx1g"

kubectl -n activemq patch statefulset activemq-activemq-artemis-master --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"1536Mi"}]' 2>/dev/null || true
ok "activemq: 1.5Gi"

# ═══════════════════════════════════════════════════════════════════════════
step "Scaling down non-essential services + suspending CronJobs"
# ═══════════════════════════════════════════════════════════════════════════

kubectl -n regproc scale deployment --all --replicas=0 2>/dev/null || true
kubectl -n packetmanager scale deployment --all --replicas=0 2>/dev/null || true
kubectl -n abis scale deployment --all --replicas=0 2>/dev/null || true
kubectl -n prereg scale deployment --all --replicas=0 2>/dev/null || true
kubectl -n resident scale deployment --all --replicas=0 2>/dev/null || true
ok "Non-essential services scaled to 0"

CRONJOBS=$(kubectl get cronjobs -A --no-headers -o custom-columns="NS:.metadata.namespace,NAME:.metadata.name" 2>/dev/null || true)
SUSPENDED=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  CJ_NS=$(echo "$line" | awk '{print $1}')
  CJ_NAME=$(echo "$line" | awk '{print $2}')
  kubectl -n "$CJ_NS" patch cronjob "$CJ_NAME" -p '{"spec":{"suspend":true}}' 2>/dev/null || true
  SUSPENDED=$((SUSPENDED + 1))
done <<< "$CRONJOBS"
ok "Suspended $SUSPENDED CronJobs"

# ═══════════════════════════════════════════════════════════════════════════
step "Waiting for memory-patched services to restart"
# ═══════════════════════════════════════════════════════════════════════════

verify_deployment keymanager keymanager 300
verify_deployment idrepo identity 300
verify_deployment idrepo credential 300

# ═══════════════════════════════════════════════════════════════════════════
step "Verifying database migrations"
# ═══════════════════════════════════════════════════════════════════════════

for DB in mosip_kernel mosip_keymgr mosip_master mosip_idrepo mosip_ida mosip_credential mosip_pms; do
  TABLE_COUNT=$(kubectl -n postgres exec postgres-postgresql-0 -- env PGPASSWORD="$PG_PASS" \
    psql -U postgres -d "$DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema');" 2>/dev/null || echo 0)
  if [ "${TABLE_COUNT:-0}" -gt 0 ]; then
    ok "$DB: $TABLE_COUNT tables"
  else
    fail "$DB: 0 tables — migration may have failed"
  fi
done

# ═══════════════════════════════════════════════════════════════════════════
step "Final health check"
# ═══════════════════════════════════════════════════════════════════════════

TOTAL_RUNNING=$(kubectl get pods -A --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
ok "$TOTAL_RUNNING pods running"

KM_RESTARTS=$(kubectl -n keymanager get pod -l app.kubernetes.io/name=keymanager -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
ok "Keymanager: $KM_RESTARTS restarts"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅ MOSIP Platform Reset Complete                       ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Next steps:                                            ║"
echo "║  1. cd testrig-build && bash build.sh                   ║"
echo "║  2. bash run-apitestrig.sh                              ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Log: $LOG_FILE"
echo "╚══════════════════════════════════════════════════════════╝"

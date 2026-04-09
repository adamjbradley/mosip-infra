#!/bin/bash
##############################################################################
# configure-config-server.sh — Single source of truth for config-server setup
#
# Sets ALL persistent env var overrides in ONE operation. No ephemeral git
# clone patches — everything is in env vars or SPRING_APPLICATION_JSON.
# Config-server can restart freely without losing state.
#
# DESIGN:
#   1. Resolve dynamic secrets from K8s secrets (postgres, minio)
#   2. Apply ALL env var overrides in a single `kubectl set env` (ONE restart)
#   3. Wait for config-server to be Ready
#   4. Disable nginx upstream retries
#   5. Restart all services to refresh cached Keycloak tokens
#
# USAGE:
#   bash configure-config-server.sh
#
# CALLED BY: install-services.sh, install-apitestrig.sh, reset-and-deploy.sh
# These scripts should NEVER set config-server env vars directly.
##############################################################################

set -euo pipefail

NS=config-server

# ─── Resolve dynamic values ────────────────────────────────────────────────

PGPASS=$(kubectl -n postgres get secret postgres-postgresql -o jsonpath='{.data.postgresql-password}' | base64 -d 2>/dev/null || echo "")
MINIO_PASS=$(kubectl -n minio get secret minio -o jsonpath='{.data.root-password}' | base64 -d 2>/dev/null || echo "")

# ─── Step 1: Persistent env var overrides (ONE batch) ──────────────────────

echo "  Setting ALL config-server persistent overrides (single restart)..."
{

  # Remove .git suffix from git URI (prevents property source name mismatch)
  CURRENT_URI=$(kubectl -n $NS get deployment config-server -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null \
    | python3 -c "import sys,json; envs=json.load(sys.stdin); [print(e['value']) for e in envs if e['name']=='SPRING_CLOUD_CONFIG_SERVER_COMPOSITE_0_URI']" 2>/dev/null || true)
  GIT_URI_OVERRIDE=""
  if echo "$CURRENT_URI" | grep -q '\.git$'; then
    FIXED_URI=$(echo "$CURRENT_URI" | sed 's/\.git$//')
    GIT_URI_OVERRIDE="SPRING_CLOUD_CONFIG_SERVER_COMPOSITE_0_URI=$FIXED_URI"
    echo "  Removing .git suffix from git URI: $FIXED_URI"
  fi

  kubectl -n $NS set env deployment/config-server \
    ${GIT_URI_OVERRIDE:+"$GIT_URI_OVERRIDE"} \
    `# --- Enable periodic git re-read so file patches take effect ---` \
    "SPRING_CLOUD_CONFIG_SERVER_COMPOSITE_0_REFRESH_RATE=30" \
    \
    `# --- Keycloak URLs (no /auth suffix — config properties add it) ---` \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_KEYCLOAK_INTERNAL_URL=http://keycloak.keycloak" \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_KEYCLOAK_EXTERNAL_URL=http://iam.mosip.localhost" \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_KEYCLOAK_EXTERNAL_HOST=iam.mosip.localhost" \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_IAM_EXTERNAL_HOST=iam.mosip.localhost" \
    \
    `# --- API hostnames ---` \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_API_INTERNAL_HOST=api-internal.mosip.localhost" \
    \
    `# --- Database hostnames (all point to local postgres) ---` \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_KERNEL_DATABASE_HOSTNAME=postgres-postgresql.postgres" \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_IDA_DATABASE_HOSTNAME=postgres-postgresql.postgres" \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_IDREPO_DATABASE_HOSTNAME=postgres-postgresql.postgres" \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_MASTER_DATABASE_HOSTNAME=postgres-postgresql.postgres" \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_KEYMGR_DATABASE_HOSTNAME=postgres-postgresql.postgres" \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_POSTGRES_HOST=postgres-postgresql.postgres" \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_DB_DBUSER_PASSWORD=$PGPASS" \
    \
    `# --- Language config ---` \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_MANDATORY__LANGUAGES=eng" \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_OPTIONAL__LANGUAGES=" \
    \
    `# --- Performance: IDA timeout 1s (default 180s makes auth tests take 90+ min) ---` \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_IDA_REQUEST_TIMEOUT_SECS=1" \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_IDA_REQUEST_TIMEOUT_SECS=1" \
    \
    `# --- Performance: credential processing tuning ---` \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_CREDENTIAL_REQUEST_JOB_TIMEDELAY=10000" \
    \
    `# --- Biosdk URL fix (default has wrong path) ---` \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_IDREPO_BIO__EXTRACTOR__SERVICE_REST_URI=http://biosdk-service.biosdk/biosdk-service/extract-template" \
    \
    `# --- MinIO/S3 credentials and bucket fix ---` \
    `# Default config has minioadmin/minioadmin and s3a:// prefix on bucket name` \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_S3_ACCESSKEY=admin" \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_S3_SECRETKEY=$MINIO_PASS" \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_S3_PRETEXT_VALUE=" \
    \
    `# --- JDBC driver (missing from keygen config, causes NPE) ---` \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_JAVAX_PERSISTENCE_JDBC_DRIVER=org.postgresql.Driver" \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_JAVAX_PERSISTENCE_JDBC_DRIVERCLASSNAME=org.postgresql.Driver" \
    \
    `# --- UIN/VID pool thresholds (200K default takes hours on constrained nodes) ---` \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_KERNEL_UIN_MIN__UNUSED__THRESHOLD_OVERRIDE=1000" \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_KERNEL_VID_MIN__UNUSED__THRESHOLD_OVERRIDE=1000" \
    \
    `# --- Regproc agegroup config ---` \
    'SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_REGPROC_PACKET_CLASSIFIER_TAGGING_AGEGROUP_RANGES={"INFANT":"0-5","MINOR":"6-17","ADULT":"18-200"}' \
    \
    `# --- SPRING_APPLICATION_JSON for properties that can't be env vars ---` \
    `# Includes: hyphenated names, underscore names (hibernate), admin batch delimiters` \
    'SPRING_APPLICATION_JSON={"spring":{"cloud":{"config":{"server":{"overrides":{"mosip.optional-languages":"ara,fra","mosip.kernel.otp.expiry-time":"10","hibernate.cache.use_second_level_cache":"false","hibernate.cache.use_query_cache":"false","mosip.admin.batch.line.delimiter":",","mosip.admin.batch.name.delimiter":","}}}}}}' \
    2>/dev/null

  echo "  Waiting for config-server restart..."
  kubectl -n $NS rollout status deployment/config-server --timeout=180s 2>/dev/null
  echo "  Config-server restarted with all overrides."
}

# ─── Step 2: (Retired) Git clone patches ─────────────────────────────────
# All config overrides are now in env vars or SPRING_APPLICATION_JSON above.
# No ephemeral git clone patches needed. Config-server can restart freely.

# ─── Step 3: Disable nginx upstream retries ──────────────────────────────────
# Without this, nginx retries timed-out requests on the same backend forever,
# and the test rig client never gets a response (even a 504).
echo "  Disabling nginx upstream retries..."
kubectl -n ingress-nginx patch cm ingress-nginx-controller --type merge \
  -p '{"data":{"proxy-next-upstream":"off","proxy-next-upstream-tries":"1"}}' 2>/dev/null || true

# ─── Step 4: Restart all services to refresh cached Keycloak tokens ──────────
# After config-server changes, services have stale cached Keycloak tokens.
# Most critically, auditmanager's token becomes invalid which causes every
# masterdata write/update API call to block for 180s (the audit retry timeout).
# Datashare must also restart to pick up corrected S3 credentials and keycloak URL.
echo "  Restarting all services (token + config refresh)..."
kubectl -n kernel rollout restart deployment --all 2>/dev/null || true
kubectl -n idrepo rollout restart deployment --all 2>/dev/null || true
kubectl -n ida rollout restart deployment --all 2>/dev/null || true
kubectl -n pms rollout restart deployment --all 2>/dev/null || true
kubectl -n admin rollout restart deployment --all 2>/dev/null || true
kubectl -n datashare rollout restart deployment --all 2>/dev/null || true

echo "  Config-server fully configured (all overrides in env vars, restart-safe)."

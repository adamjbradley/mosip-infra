#!/bin/bash
##############################################################################
# configure-config-server.sh — Single source of truth for config-server setup
#
# Sets ALL persistent env var overrides and ephemeral git clone patches
# in ONE operation. This avoids the "multiple restarts lose git patches"
# problem that occurs when different scripts modify config-server independently.
#
# DESIGN:
#   1. Collect ALL env var overrides into one batch
#   2. Apply them in a single `kubectl set env` (triggers exactly ONE restart)
#   3. Wait for config-server to be Ready
#   4. Apply git clone patches ONCE
#   5. NEVER touch config-server env vars again
#
# USAGE:
#   bash configure-config-server.sh              # full setup
#   bash configure-config-server.sh --patches-only  # re-apply git patches (no restart)
#
# CALLED BY: install-services.sh, install-apitestrig.sh, reset-and-deploy.sh
# These scripts should NEVER set config-server env vars directly.
##############################################################################

set -euo pipefail

PATCHES_ONLY=false
[ "${1:-}" = "--patches-only" ] && PATCHES_ONLY=true

NS=config-server

# ─── Resolve dynamic values ────────────────────────────────────────────────

PGPASS=$(kubectl -n postgres get secret postgres-postgresql -o jsonpath='{.data.postgresql-password}' | base64 -d 2>/dev/null || echo "")

# ─── Step 1: Persistent env var overrides (ONE batch) ──────────────────────

if [ "$PATCHES_ONLY" = false ]; then
  echo "  Setting ALL config-server persistent overrides (single restart)..."

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
    `# --- UIN/VID pool thresholds (200K default takes hours on constrained nodes) ---` \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_KERNEL_UIN_MIN__UNUSED__THRESHOLD_OVERRIDE=1000" \
    "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_KERNEL_VID_MIN__UNUSED__THRESHOLD_OVERRIDE=1000" \
    \
    `# --- Regproc agegroup config ---` \
    'SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_REGPROC_PACKET_CLASSIFIER_TAGGING_AGEGROUP_RANGES={"INFANT":"0-5","MINOR":"6-17","ADULT":"18-200"}' \
    \
    `# --- SPRING_APPLICATION_JSON for properties that can't be env vars ---` \
    `# Includes: hyphenated names, underscore names (hibernate), etc.` \
    'SPRING_APPLICATION_JSON={"spring":{"cloud":{"config":{"server":{"overrides":{"mosip.optional-languages":"","mosip.kernel.otp.expiry-time":"10"}}}}}}' \
    2>/dev/null

  echo "  Waiting for config-server restart..."
  kubectl -n $NS rollout status deployment/config-server --timeout=180s 2>/dev/null
  echo "  Config-server restarted with all overrides."
fi

# ─── Step 2: Wait for git clone to complete ────────────────────────────────

echo "  Waiting for git clone..."
sleep 20

# ─── Step 3: Apply git clone patches (ephemeral but only done ONCE) ────────

echo "  Applying git clone patches..."
kubectl -n $NS exec deploy/config-server -c config-server -- sh -c '
PATCHED=0
for REPO in /tmp/config-repo-*/; do
  [ -d "$REPO" ] || continue

  # Optional languages = empty
  sed -i "s/^mosip.optional-languages=.*/mosip.optional-languages=/" "$REPO/application-default.properties" 2>/dev/null

  # OTP expiry 10s (test rig reads from git source, not overrides)
  sed -i "s/^mosip.kernel.otp.expiry-time=.*/mosip.kernel.otp.expiry-time=10/" "$REPO/application-default.properties" 2>/dev/null

  # Enable Hibernate L2 cache (improves warm performance after first queries)
  # NOTE: With refreshRate=0, this only takes effect if config-server is restarted
  # AFTER this patch. The env var restart in Step 1 handles this.
  sed -i "s/hibernate.cache.use_second_level_cache=false/hibernate.cache.use_second_level_cache=true/" "$REPO/kernel-default.properties" 2>/dev/null
  sed -i "s/hibernate.cache.use_query_cache=false/hibernate.cache.use_query_cache=true/" "$REPO/kernel-default.properties" 2>/dev/null

  # Biosdk URL fix in id-repository properties
  sed -i "s|/biosdk-service/{extractionFormat}/extracttemplates|/biosdk-service/extract-template|" "$REPO/id-repository-default.properties" 2>/dev/null

  # Admin batch delimiter: pipe → comma
  grep -q "mosip.admin.batch.line.delimiter=," "$REPO/admin-default.properties" 2>/dev/null || \
    echo "mosip.admin.batch.line.delimiter=," >> "$REPO/admin-default.properties"
  grep -q "mosip.admin.batch.name.delimiter=," "$REPO/admin-default.properties" 2>/dev/null || \
    echo "mosip.admin.batch.name.delimiter=," >> "$REPO/admin-default.properties"

  # Add mosip-testrig-client to allowed audience in all relevant property files
  for f in id-authentication-internal-default.properties \
           id-authentication-default.properties \
           kernel-default.properties \
           partner-management-default.properties \
           data-share-default.properties \
           admin-default.properties; do
    if [ -f "$REPO/$f" ] && grep -q "^auth.server.admin.allowed.audience=" "$REPO/$f" && \
       ! grep -q "mosip-testrig-client" "$REPO/$f"; then
      sed -i "s/^auth.server.admin.allowed.audience=.*/&,mosip-testrig-client/" "$REPO/$f"
    fi
  done

  PATCHED=$((PATCHED + 1))
done
echo "Patched $PATCHED config repos"
' 2>/dev/null

# Force config-server to re-read the patched git clone files
kubectl -n $NS exec deploy/config-server -c config-server -- \
  wget -q -O /dev/null --timeout=5 --post-data="" "http://localhost:8088/config-server/actuator/refresh" 2>/dev/null || true

# ─── Step 4: Disable nginx upstream retries ─────────────────────────────────
# Without this, nginx retries timed-out requests on the same backend forever,
# and the test rig client never gets a response (even a 504).
echo "  Disabling nginx upstream retries..."
kubectl -n ingress-nginx patch cm ingress-nginx-controller --type merge \
  -p '{"data":{"proxy-next-upstream":"off","proxy-next-upstream-tries":"1"}}' 2>/dev/null || true

# ─── Step 5: Restart all kernel services to refresh Keycloak tokens ─────────
# After config-server changes, services have stale cached Keycloak tokens.
# Most critically, auditmanager's token becomes invalid which causes every
# masterdata write/update API call to block for 180s (the audit retry timeout).
# This single issue caused ALL tests to hang on the fresh deployment.
echo "  Restarting kernel + IDA services (token refresh)..."
kubectl -n kernel rollout restart deployment --all 2>/dev/null || true
kubectl -n idrepo rollout restart deployment --all 2>/dev/null || true
kubectl -n ida rollout restart deployment --all 2>/dev/null || true
kubectl -n pms rollout restart deployment --all 2>/dev/null || true
kubectl -n admin rollout restart deployment --all 2>/dev/null || true

echo "  Config-server fully configured."
echo "  WARNING: Do not set env vars on config-server after this point."
echo "           Use configure-config-server.sh to add new overrides."

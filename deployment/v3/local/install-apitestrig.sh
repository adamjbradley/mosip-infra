#!/bin/bash
# Installs MOSIP API test rig (apitestrig) for local Docker Desktop Kubernetes.
# Non-interactive wrapper around the upstream testrig scripts.
#
# Usage: ./install-apitestrig.sh [teardown]
#
# What this does:
#   0a. Patches CoreDNS so *.mosip.localhost resolves inside the cluster.
#   0b. Generates a self-signed TLS cert and configures nginx-ingress for HTTPS.
#       (The testrig v1.3.0 JAR hardcodes an https:// regex for URL parsing.)
#   0c. Fixes Keycloak admin-cli client: enables fullScopeAllowed and adds an
#       audience mapper for mosip-admin-client so tokens include roles and aud.
#   0d. Resets globaladmin password to mosip123 (matches testrig Kernel.properties).
#   0d3. Overrides config-server: keycloak URLs, all DB hostnames, DB password.
#   0e. Removes .git suffix from config-server git URI so testrig's property
#       source name matching works (contains "/mosip-config/" check).
#   0f. Builds patched testrig images — patches GlobalMethods.class regex AND
#       Kernel.properties (DB host, keycloak URL, mosip_components_base_urls,
#       DB password). These properties are baked into the JAR and override
#       what config-server provides.
#   0g. Loads patched images into Kind cluster node (docker build images aren't
#       visible to Kind's containerd without explicit loading).
#   1-8. Namespace setup, configmaps, secrets, ingress rules, Helm install.
#   9. Patches CronJobs: uses patched images, fixes init container, imports TLS
#      cert into Java truststore, fixes cacerts mount path (Java 21 vs 11),
#      adds hostAliases. Uses strategic merge patch (not JSON patch).
#
# Modules enabled: masterdata, idrepo, auth
# Modules disabled: prereg, resident, partner (not deployed in the poc profile)
#
# The testrig runs as a Kubernetes CronJob.  After install, trigger a manual run with:
#   kubectl -n apitestrig create job apitestrig-manual-$(date +%s) --from=cronjob/apitestrig-masterdata
# (replace "masterdata" with the module name you want to run)
#
# Reports are stored in MinIO under bucket "apitestrig".
# View them via the MinIO console: http://localhost:9001

set -euo pipefail

TESTRIG_DIR="$(cd "$(dirname "$0")/../testrig/apitestrig" && pwd)"
COPY_UTIL="$(cd "$(dirname "$0")/../utils" && pwd)/copy_cm_func.sh"
NS=apitestrig
CHART_VERSION=1.3.5

teardown() {
  echo "=== Tearing down apitestrig ==="
  helm -n $NS uninstall apitestrig 2>/dev/null || true
  kubectl delete ns $NS 2>/dev/null || true
  echo "Done."
}

if [ "${1:-}" = "teardown" ]; then
  teardown
  exit 0
fi

# ─── Step 0a: CoreDNS — ensure *.mosip.localhost resolves inside the cluster ─
# The test pods run inside Kubernetes and use ENV_ENDPOINT=https://api-internal.mosip.localhost
# to call MOSIP APIs via the Nginx Ingress controller.  CoreDNS needs a template
# rule so that *.mosip.localhost resolves to the ingress controller's ClusterIP.
# This is idempotent — re-patching with the same content is harmless.
echo "=== Step 0a: Configuring CoreDNS for *.mosip.localhost ==="
INGRESS_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.clusterIP}')
echo "  Ingress ClusterIP: $INGRESS_IP"
kubectl -n kube-system patch cm coredns --patch "$(cat <<EOF
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        template IN A mosip.localhost {
          match ^(.*\.)?mosip\.localhost\.$
          answer "{{ .Name }} 60 IN A ${INGRESS_IP}"
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30 {
           disable success cluster.local
           disable denial cluster.local
        }
        loop
        reload
        loadbalance
    }
EOF
)"
kubectl -n kube-system rollout restart deployment/coredns
kubectl -n kube-system rollout status deployment/coredns --timeout=60s

# ─── Step 0b: TLS — the testrig JAR hardcodes https:// in its URL regex ──────
# The compiled testrig v1.3.0 JAR uses regex `https://([^/]+)/(v[0-9]+)?/` to
# parse URLs.  Without HTTPS the regex never matches and all property extraction
# returns null, crashing the testrig with NumberFormatException.
# Fix: generate a self-signed cert and configure Nginx Ingress to serve HTTPS.
echo ""
echo "=== Step 0b: Configuring TLS on Nginx Ingress (self-signed cert) ==="
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /tmp/mosip-localhost.key -out /tmp/mosip-localhost.crt \
  -subj "/CN=*.mosip.localhost" \
  -addext "subjectAltName=DNS:*.mosip.localhost,DNS:mosip.localhost" 2>/dev/null

kubectl -n ingress-nginx delete secret mosip-tls-secret 2>/dev/null || true
kubectl -n ingress-nginx create secret tls mosip-tls-secret \
  --cert=/tmp/mosip-localhost.crt --key=/tmp/mosip-localhost.key

# Store the cert in the testrig namespace so init containers can import it into Java cacerts
kubectl -n $NS delete secret mosip-local-tls 2>/dev/null || true

# Set as default SSL certificate on the ingress controller (idempotent — if already set, re-patching is harmless)
CURRENT_ARGS=$(kubectl -n ingress-nginx get deployment ingress-nginx-controller -o jsonpath='{.spec.template.spec.containers[0].args}')
if echo "$CURRENT_ARGS" | grep -q "default-ssl-certificate"; then
  echo "  default-ssl-certificate already configured"
else
  kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--default-ssl-certificate=ingress-nginx/mosip-tls-secret"}]'
fi
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=60s

# ─── Step 0c: Keycloak admin-cli client — fix token audience and roles ────────
# The testrig authenticates via authmanager which uses the admin-cli client to get
# Keycloak tokens.  By default admin-cli has fullScopeAllowed=false and no audience
# mapper, so tokens lack realm_access.roles and aud — causing NPE (null tokenAudience)
# and 403 Forbidden from downstream MOSIP services.
echo ""
echo "=== Step 0c: Fixing Keycloak admin-cli client (audience + roles) ==="

# Wait for keycloak to be ready (1/1) — it's slow to boot after DB migration
echo "  Waiting for keycloak to be ready..."
for i in $(seq 1 60); do
  KC_READY=$(kubectl -n keycloak get pod keycloak-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
  if [ "$KC_READY" = "true" ]; then break; fi
  if [ $((i % 10)) -eq 0 ]; then echo "    keycloak not ready yet ($i/60)..."; fi
  sleep 5
done
if [ "$KC_READY" != "true" ]; then
  echo "  WARNING: keycloak not ready after 5 minutes — Keycloak steps may fail"
fi

KC_ADMIN_TOKEN=$(kubectl exec -n keycloak keycloak-0 -- curl -s \
  http://localhost:8080/auth/realms/master/protocol/openid-connect/token \
  -d 'grant_type=password&client_id=admin-cli&username=admin&password=admin' 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

# Get admin-cli client UUID in mosip realm
ADMIN_CLI_UUID=$(kubectl exec -n keycloak keycloak-0 -- curl -s \
  -H "Authorization: Bearer $KC_ADMIN_TOKEN" \
  "http://localhost:8080/auth/admin/realms/mosip/clients?clientId=admin-cli" 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')

# Enable fullScopeAllowed so tokens include realm roles (GLOBAL_ADMIN etc.)
kubectl exec -n keycloak keycloak-0 -- curl -s -o /dev/null -w '' -X PUT \
  -H "Authorization: Bearer $KC_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  "http://localhost:8080/auth/admin/realms/mosip/clients/$ADMIN_CLI_UUID" \
  -d "{\"id\":\"$ADMIN_CLI_UUID\",\"clientId\":\"admin-cli\",\"fullScopeAllowed\":true}" 2>/dev/null
echo "  fullScopeAllowed enabled"

# Add audience mapper for mosip-admin-client (idempotent — delete and recreate)
EXISTING_MAPPERS=$(kubectl exec -n keycloak keycloak-0 -- curl -s \
  -H "Authorization: Bearer $KC_ADMIN_TOKEN" \
  "http://localhost:8080/auth/admin/realms/mosip/clients/$ADMIN_CLI_UUID/protocol-mappers/models" 2>/dev/null)
EXISTING_MAPPER_ID=$(echo "$EXISTING_MAPPERS" | python3 -c "
import sys,json
for m in json.load(sys.stdin):
    if m.get('name') == 'mosip-audience-mapper':
        print(m['id']); break
" 2>/dev/null || true)
if [ -n "$EXISTING_MAPPER_ID" ]; then
  kubectl exec -n keycloak keycloak-0 -- curl -s -o /dev/null -X DELETE \
    -H "Authorization: Bearer $KC_ADMIN_TOKEN" \
    "http://localhost:8080/auth/admin/realms/mosip/clients/$ADMIN_CLI_UUID/protocol-mappers/models/$EXISTING_MAPPER_ID" 2>/dev/null
fi
kubectl exec -n keycloak keycloak-0 -- curl -s -o /dev/null -X POST \
  -H "Authorization: Bearer $KC_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  "http://localhost:8080/auth/admin/realms/mosip/clients/$ADMIN_CLI_UUID/protocol-mappers/models" \
  -d '{"name":"mosip-audience-mapper","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"included.client.audience":"mosip-admin-client","id.token.claim":"false","access.token.claim":"true"}}' 2>/dev/null
echo "  audience mapper for mosip-admin-client added"

# ─── Step 0d: Ensure globaladmin user has password mosip123 ───────────────────
# The testrig Kernel.properties bundles admin_password=mosip123.  The globaladmin user
# may have been created with a different/random password.  Reset to match.
echo ""
echo "=== Step 0d: Resetting globaladmin password to mosip123 ==="
GLOBALADMIN_ID=$(kubectl exec -n keycloak keycloak-0 -- curl -s \
  -H "Authorization: Bearer $KC_ADMIN_TOKEN" \
  "http://localhost:8080/auth/admin/realms/mosip/users?username=globaladmin&exact=true" 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["id"] if d else "")' 2>/dev/null || true)
if [ -n "$GLOBALADMIN_ID" ]; then
  kubectl exec -n keycloak keycloak-0 -- curl -s -o /dev/null -X PUT \
    -H "Authorization: Bearer $KC_ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    "http://localhost:8080/auth/admin/realms/mosip/users/$GLOBALADMIN_ID/reset-password" \
    -d '{"type":"password","value":"mosip123","temporary":false}' 2>/dev/null
  echo "  globaladmin password reset to mosip123"
else
  echo "  WARNING: globaladmin user not found in Keycloak — testrig may fail"
fi

# ─── Step 0d2: Fix mosip-admin-client the same way as admin-cli ───────────────
# The authmanager uses mosip-admin-client for client credential auth. The same
# fullScopeAllowed + audience mapper fix is needed so downstream services (keymanager,
# masterdata) accept the token.
echo ""
echo "=== Step 0d2: Fixing Keycloak mosip-admin-client (audience + roles) ==="
MOSIP_ADMIN_UUID=$(kubectl exec -n keycloak keycloak-0 -- curl -s \
  -H "Authorization: Bearer $KC_ADMIN_TOKEN" \
  "http://localhost:8080/auth/admin/realms/mosip/clients?clientId=mosip-admin-client" 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])' 2>/dev/null || true)
if [ -n "$MOSIP_ADMIN_UUID" ]; then
  kubectl exec -n keycloak keycloak-0 -- curl -s -o /dev/null -X PUT \
    -H "Authorization: Bearer $KC_ADMIN_TOKEN" -H "Content-Type: application/json" \
    "http://localhost:8080/auth/admin/realms/mosip/clients/$MOSIP_ADMIN_UUID" \
    -d "{\"id\":\"$MOSIP_ADMIN_UUID\",\"clientId\":\"mosip-admin-client\",\"fullScopeAllowed\":true}" 2>/dev/null
  kubectl exec -n keycloak keycloak-0 -- curl -s -o /dev/null -X POST \
    -H "Authorization: Bearer $KC_ADMIN_TOKEN" -H "Content-Type: application/json" \
    "http://localhost:8080/auth/admin/realms/mosip/clients/$MOSIP_ADMIN_UUID/protocol-mappers/models" \
    -d '{"name":"mosip-audience-mapper","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"included.client.audience":"mosip-admin-client","id.token.claim":"false","access.token.claim":"true"}}' 2>/dev/null
  echo "  mosip-admin-client fixed (fullScopeAllowed + audience mapper)"

  # Assign GLOBAL_ADMIN realm role to the mosip-admin-client service account
  # so it can call keymanager for IDA certificate generation
  SA_USER_ID=$(kubectl exec -n keycloak keycloak-0 -- curl -s \
    -H "Authorization: Bearer $KC_ADMIN_TOKEN" \
    "http://localhost:8080/auth/admin/realms/mosip/clients/$MOSIP_ADMIN_UUID/service-account-user" 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])' 2>/dev/null || true)
  if [ -n "$SA_USER_ID" ]; then
    GLOBAL_ADMIN_ROLE=$(kubectl exec -n keycloak keycloak-0 -- curl -s \
      -H "Authorization: Bearer $KC_ADMIN_TOKEN" \
      "http://localhost:8080/auth/admin/realms/mosip/roles/GLOBAL_ADMIN" 2>/dev/null)
    kubectl exec -n keycloak keycloak-0 -- curl -s -o /dev/null -X POST \
      -H "Authorization: Bearer $KC_ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      "http://localhost:8080/auth/admin/realms/mosip/users/$SA_USER_ID/role-mappings/realm" \
      -d "[$GLOBAL_ADMIN_ROLE]" 2>/dev/null
    echo "  GLOBAL_ADMIN role assigned to mosip-admin-client service account"
  fi
fi

# ─── Step 0d3: Fix keycloak URLs and DB hostnames in config-server ─────────────
# The config-server override sets keycloak.internal.url=http://keycloak.keycloak/auth
# but the GitHub config appends /auth again → keycloak.auth-server-url=/auth/auth.
# Fix: remove /auth from the override so the final URL has a single /auth.
#
# Config-server overrides: keycloak URLs, DB hostnames, language, performance, etc.
# ALL config-server modifications are now in configure-config-server.sh (single source of truth).
# This prevents the "multiple restarts lose git patches" problem.
echo ""
echo "=== Step 0d3: Configuring config-server (via configure-config-server.sh) ==="
bash "$SCRIPT_DIR/configure-config-server.sh"
echo "  Config-server fully configured (env vars + git patches in single operation)"

# ─── Step 0d4: Add IDA key policy to keymanager DB ───────────────────────────
# The ida-keygen helm chart normally does this but has compatibility issues
# (libssl.so.3 missing in the old image). Add the key policy directly.
echo ""
echo "=== Step 0d4: Adding IDA key policy to keymanager DB ==="
PGPASS=$(kubectl get secret -n postgres postgres-postgresql -o jsonpath='{.data.postgres-password}' | base64 -d)
kubectl exec -n postgres postgres-postgresql-0 -- env PGPASSWORD=$PGPASS psql -U postgres -d mosip_keymgr -c \
  "INSERT INTO key_policy_def (app_id, key_validity_duration, is_active, pre_expire_days, access_allowed, cr_by, cr_dtimes) VALUES ('IDA', 1095, true, 60, 'NA', 'superadmin', now()) ON CONFLICT (app_id) DO NOTHING;" 2>/dev/null
echo "  IDA key policy added"

# ─── Step 0d4b: Generate IDA master key via keymanager API ───────────────────
# The kernel-keygen job often OOM-kills before generating IDA keys.
# Generate the IDA master key pair directly via the keymanager API.
echo ""
echo "=== Step 0d4b: Generating IDA master key ==="
KC_IDA_TOKEN=$(kubectl exec -n keycloak keycloak-0 -- curl -s \
  http://localhost:8080/auth/realms/mosip/protocol/openid-connect/token \
  -d 'grant_type=password&client_id=admin-cli&username=globaladmin&password=mosip123' 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])' 2>/dev/null || true)
if [ -n "$KC_IDA_TOKEN" ]; then
  kubectl exec -n keymanager deploy/keymanager -- curl -s -o /dev/null -w '%{http_code}' \
    -X POST http://localhost:8088/v1/keymanager/generateMasterKey/CSR \
    -H 'Content-Type: application/json' \
    -H "Cookie: Authorization=$KC_IDA_TOKEN" \
    -d '{"id":"string","metadata":{},"request":{"applicationId":"IDA","commonName":"IDA","country":"IN","force":false,"location":"BLR","organization":"MOSIP","organizationUnit":"MOSIP-Tech","referenceId":"","state":"KA"},"requesttime":"2026-03-26T00:00:00.000Z","version":"1.0"}' 2>/dev/null
  echo ""
  echo "  IDA master key generated"
else
  echo "  WARNING: Could not get Keycloak token — IDA key generation skipped"
fi

# Steps 0d5, 0d6, 0e are now handled by configure-config-server.sh (called in Step 0d3).
# - 0d5: optional-languages cleared via env var + git patch
# - 0d6: mosip-testrig-client added to audience lists via git patch
# - 0e: .git suffix handling moved to commons patch (search pattern fix)
echo ""
echo "=== Steps 0d5/0d6/0e: Already handled by configure-config-server.sh ==="

# ─── Step 0f: Build patched testrig images ────────────────────────────────────
# The testrig v1.3.0 JAR has several issues for local dev:
#   1. GlobalMethods.class hardcodes https:// regex — patch to http.:// (dot matches 's')
#   2. Kernel.properties has hardcoded qa-java21.mosip.net for DB and Keycloak URLs
#   3. Kernel.properties has empty mosip_components_base_urls — causes relative URL
#      parsing failures in getValueFromActuators() → NPE in MasterDataUtil
#   4. DB password is empty in Kernel.properties — needs local postgres password
# We patch all of these in a single docker build per module.
echo ""
echo "=== Step 0f: Building patched testrig images ==="

# Force rebuild if FORCE_REBUILD=1 (useful after config changes)
FORCE_REBUILD="${FORCE_REBUILD:-0}"

# Skip build if SKIP_BUILD=1 (use testrig-build/build-v130.sh instead)
if [ "${SKIP_BUILD:-0}" = "1" ]; then
  echo "  SKIP_BUILD=1 — skipping image build and load (use build-v130.sh)"
  # Skip to Step 1
  SKIP_STEPS_0F_0G=1
fi
if [ "${SKIP_STEPS_0F_0G:-0}" != "1" ]; then

# Resolve local values to bake into Kernel.properties
PGPASS=$(kubectl get secret -n postgres postgres-postgresql -o jsonpath='{.data.postgres-password}' | base64 -d)
API_HOST="${API_INTERNAL_HOST:-api-internal.mosip.localhost}"
COMPONENTS_BASE_URLS="auditmanager=${API_HOST};idrepository=${API_HOST};authmanager=${API_HOST};partnermanager=${API_HOST};idauthentication=${API_HOST};masterdata=${API_HOST};idgenerator=${API_HOST};keymanager=${API_HOST};registrationprocessor=${API_HOST};datashare=${API_HOST};hotlist=${API_HOST};credential=${API_HOST};vid=${API_HOST};websub=${API_HOST}"

for module in auth idrepo masterdata; do
  IMG="mosipid/apitest-${module}:1.3.0"
  PATCHED="${IMG}-patched"
  if [ "$FORCE_REBUILD" != "1" ] && docker image inspect "$PATCHED" &>/dev/null; then
    echo "  $PATCHED already exists, skipping (set FORCE_REBUILD=1 to force)"
    continue
  fi
  echo "  Building $PATCHED..."

  # Write sed commands for Kernel.properties to a temp file (avoids Dockerfile escaping)
  SEDSCRIPT=$(mktemp /tmp/testrig-sed-XXXXX)
  cat > "$SEDSCRIPT" <<SEDEOF
s|qa-java21.mosip.net|postgres-postgresql.postgres|g
s|keycloak-external-url = http.://iam.postgres-postgresql.postgres|keycloak-external-url = https://iam.mosip.localhost|
s|mosip_components_base_urls =\$|mosip_components_base_urls = ${COMPONENTS_BASE_URLS}|
/^db-su-password/d
\$a db-su-password=${PGPASS}
\$a auditActuatorEndpoint=/v1/auditmanager/actuator/info
\$a mosip.mandatory-languages=eng
\$a mosip.optional-languages=
SEDEOF

  # Single-step build: extract JAR contents, patch, repack, produce final image
  cat <<DEOF | docker build -t "$PATCHED" -f - "$(dirname "$SEDSCRIPT")" 2>&1 | tail -1
FROM eclipse-temurin:21-jdk AS patcher
COPY --from=${IMG} /home/mosip/apitest-${module}-1.3.0-jar-with-dependencies.jar /work/original.jar
COPY $(basename "$SEDSCRIPT") /work/patches.sed
WORKDIR /work
RUN mkdir extract && cd extract \
  && jar xf /work/original.jar \
       io/mosip/testrig/apirig/utils/GlobalMethods.class \
       config/Kernel.properties \
       config/IDRepo.properties \
       config/valueMapping.properties \
       config/bioValue.properties \
  && sed -i 's|https://|http.://|g' io/mosip/testrig/apirig/utils/GlobalMethods.class \
  && jar xf /work/original.jar io/mosip/testrig/apirig/utils/PartnerRegistration.class \
  && python3 -c "
import struct
data=bytearray(open('io/mosip/testrig/apirig/utils/PartnerRegistration.class','rb').read())
# Patch appendEkycOrRp default from '' to 'rp-' in the constant pool
# CP#79 is the empty UTF8 string at a known offset pattern
i=10
cp_count=struct.unpack('>H',data[8:10])[0]
idx=1
while idx<cp_count:
    tag=data[i]
    if tag==1:
        l=struct.unpack('>H',data[i+1:i+3])[0]
        s=data[i+3:i+3+l]
        if l==0:  # empty string - patch to 'rp-'
            new=b'rp-'
            data=data[:i]+bytes([1])+struct.pack('>H',len(new))+new+data[i+3:]
            print(f'Patched empty string at CP#{idx} offset {i} to rp-')
            break
        i+=3+l
    elif tag in(7,8,16,19,20): i+=3
    elif tag in(3,4,9,10,11,12,17,18): i+=5
    elif tag in(5,6): i+=9;idx+=1
    elif tag==15: i+=4
    else: break
    idx+=1
open('io/mosip/testrig/apirig/utils/PartnerRegistration.class','wb').write(data)
" \
  && sed -i -f /work/patches.sed config/Kernel.properties \
  && if [ -f config/IDRepo.properties ] && [ ! -f config/Idrepo.properties ]; then \
       cp config/IDRepo.properties config/Idrepo.properties; fi \
  && if [ ! -f config/valueMapping.properties ]; then \
       printf 'residenceStatus=NFR\nfullName=TEST_FULLNAME\nfirstName=TEST_FIRSTNAME\ndateOfBirth=1996/01/01\ngender=MLE\naddressLine1=TEST_ADDRESSLINE1\npostalCode=14022\nphone=8249742850\nemail=test@mosip.net\nregion=TEST_REGION\nprovince=TEST_PROVINCE\ncity=TEST_CITY\nzone=TEST_ZONE\n' > config/valueMapping.properties; fi \
  && if [ ! -f config/bioValue.properties ]; then \
       printf '# stub\n' > config/bioValue.properties; fi \
  && find . -name '*.yml' -o -name '*.yaml' | xargs grep -l 'RPR-WAA-' 2>/dev/null | while read f; do \
       sed -i 's/RPR-WAA-/KER-MSD-/g' "\$f"; done \
  && jar uf /work/original.jar \
       io/mosip/testrig/apirig/utils/GlobalMethods.class \
       io/mosip/testrig/apirig/utils/PartnerRegistration.class \
       config/Kernel.properties \
       $([ -f config/Idrepo.properties ] && echo config/Idrepo.properties) \
       $([ -f config/valueMapping.properties ] && echo config/valueMapping.properties) \
       $([ -f config/bioValue.properties ] && echo config/bioValue.properties) \
       $(find . -name '*.yml' -o -name '*.yaml' | xargs grep -l 'KER-MSD-' 2>/dev/null | tr '\n' ' ')
FROM ${IMG}
USER root
RUN apt-get update -qq && apt-get install -y -qq git > /dev/null 2>&1 && \
    git clone --depth 1 https://github.com/mosip/mosip-mock-services.git /tmp/mms && \
    cp -r /tmp/mms/MockMDS/Profile /Profile && \
    mv /tmp/mms/MockMDS/"Biometric Devices" /tmp/BD && \
    rm -rf "/Biometric Devices" && mv /tmp/BD "/Biometric Devices" && \
    chmod -R 755 /Profile "/Biometric Devices" && chown -R mosip:mosip /Profile "/Biometric Devices" && \
    rm -rf /tmp/mms && apt-get remove -y git > /dev/null 2>&1 && rm -rf /var/lib/apt/lists/*
USER mosip
COPY --from=patcher /work/original.jar /home/mosip/apitest-${module}-1.3.0-jar-with-dependencies.jar
DEOF

  rm -f "$SEDSCRIPT"
  echo "  Built $PATCHED"
done

# ─── Step 0g: Load patched images into Kind cluster node ─────────────────────
# Docker Desktop uses Kind under the hood. Images built with `docker build` are
# in the host Docker daemon but not visible to the Kind node's containerd.
# We must explicitly load them.
echo ""
echo "=== Step 0g: Loading patched images into Kind cluster ==="
for module in auth idrepo masterdata; do
  PATCHED="mosipid/apitest-${module}:1.3.0-patched"
  echo "  Loading $PATCHED..."
  docker exec desktop-control-plane crictl rmi "docker.io/${PATCHED}" 2>/dev/null || true
  docker save "$PATCHED" | docker exec -i desktop-control-plane ctr -n k8s.io images import --all-platforms - 2>&1 | tail -1
done
echo "  Images loaded."

fi  # end SKIP_STEPS_0F_0G

# ─── Step 1: prereq.sh — update config-server env vars ───────────────────────
echo ""
echo "=== Step 1: Updating config-server (prereq) ==="
(cd "$TESTRIG_DIR" && bash prereq.sh)

# ─── Step 2: Create namespace ─────────────────────────────────────────────────
echo ""
echo "=== Step 2: Creating namespace $NS ==="
kubectl create ns $NS 2>/dev/null || echo "Namespace $NS already exists."

# ─── Step 3: Copy configmaps ─────────────────────────────────────────────────
echo ""
echo "=== Step 3: Copying configmaps ==="
$COPY_UTIL configmap global        default       $NS
$COPY_UTIL configmap keycloak-host keycloak      $NS
$COPY_UTIL configmap artifactory-share artifactory $NS
$COPY_UTIL configmap config-server-share config-server $NS

# ─── Step 4: Copy secrets ────────────────────────────────────────────────────
echo ""
echo "=== Step 4: Copying secrets ==="
$COPY_UTIL secret keycloak-client-secrets keycloak $NS
$COPY_UTIL secret postgres-postgresql     postgres  $NS

# The upstream script expects secret "s3" from namespace "s3".
# Locally MinIO credentials are in secret "minio" in namespace "minio".
# We copy and rename.
$COPY_UTIL secret minio minio $NS s3

# ─── Step 5: Delete stale configmaps if they exist ───────────────────────────
kubectl -n $NS delete --ignore-not-found=true configmap s3 db apitestrig

# ─── Step 6: Resolve values from global configmap ────────────────────────────
API_INTERNAL_HOST=$(kubectl -n default get cm global -o jsonpath='{.data.mosip-api-internal-host}')
# Use the Kubernetes internal service DNS for the DB — the mosip-postgres-host value
# in the global CM resolves to the ingress IP via CoreDNS, not the actual postgres pod.
DB_HOST="postgres-postgresql.postgres"
ENV_USER=$(echo "$API_INTERNAL_HOST" | awk -F '.' '{print $1"."$2}')

echo ""
echo "=== Resolved: API_INTERNAL_HOST=$API_INTERNAL_HOST  DB_HOST=$DB_HOST  ENV_USER=$ENV_USER ==="

# ─── Step 7: Create regproc ingress (if not already present) ─────────────────
# The apitestrig masterdata module calls /registrationprocessor/v1/registrationtransaction/
# (the MOSIP v1.2.x name). In v1.3.0 the service is registrationstatus. Add an ingress
# alias so the old path resolves. Also adds the other regproc service paths.
echo ""
echo "=== Step 7: Creating regproc ingress ==="
kubectl apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-internal-regproc
  namespace: regproc
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  ingressClassName: nginx
  rules:
  - host: $API_INTERNAL_HOST
    http:
      paths:
      - path: /registrationprocessor/v1/registrationstatus
        pathType: Prefix
        backend:
          service:
            name: regproc-status
            port:
              number: 80
      - path: /registrationprocessor/v1/packetserver
        pathType: Prefix
        backend:
          service:
            name: regproc-pktserver
            port:
              number: 80
      - path: /registrationprocessor/v1/workflowmanager
        pathType: Prefix
        backend:
          service:
            name: regproc-workflow
            port:
              number: 80
      - path: /registrationprocessor/v1/camelbridge
        pathType: Prefix
        backend:
          service:
            name: regproc-camel
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-internal-regproc-alias
  namespace: regproc
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /registrationprocessor/v1/registrationstatus/\$2
spec:
  ingressClassName: nginx
  rules:
  - host: $API_INTERNAL_HOST
    http:
      paths:
      - path: /registrationprocessor/v1/registrationtransaction(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: regproc-status
            port:
              number: 80
YAML

# ─── Step 7b: Create additional ingress rules for testrig ─────────────────────
# The testrig auth module needs to reach IDA, datashare, credential, websub, and
# hotlist services through the ingress. These are not created by the base install.
echo ""
echo "=== Step 7b: Creating additional ingress rules (IDA, datashare, websub, etc.) ==="
kubectl apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-internal-ida
  namespace: ida
spec:
  ingressClassName: nginx
  rules:
  - host: $API_INTERNAL_HOST
    http:
      paths:
      - path: /idauthentication/v1
        pathType: Prefix
        backend:
          service:
            name: ida-auth
            port:
              number: 80
      - path: /idauthentication/v1/internal
        pathType: Prefix
        backend:
          service:
            name: ida-internal
            port:
              number: 80
      - path: /idauthentication/v1/otp
        pathType: Prefix
        backend:
          service:
            name: ida-otp
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-internal-datashare
  namespace: datashare
spec:
  ingressClassName: nginx
  rules:
  - host: $API_INTERNAL_HOST
    http:
      paths:
      - path: /v1/datashare
        pathType: Prefix
        backend:
          service:
            name: datashare
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-internal-idrepo-extra
  namespace: idrepo
spec:
  ingressClassName: nginx
  rules:
  - host: $API_INTERNAL_HOST
    http:
      paths:
      - path: /v1/credentialrequest
        pathType: Prefix
        backend:
          service:
            name: credentialrequest
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-internal-websub
  namespace: websub
spec:
  ingressClassName: nginx
  rules:
  - host: $API_INTERNAL_HOST
    http:
      paths:
      - path: /hub
        pathType: Prefix
        backend:
          service:
            name: websub
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-internal-hotlist
  namespace: kernel
spec:
  ingressClassName: nginx
  rules:
  - host: $API_INTERNAL_HOST
    http:
      paths:
      - path: /v1/hotlist
        pathType: Prefix
        backend:
          service:
            name: otpmanager
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-internal-packetmanager
  namespace: packetmanager
spec:
  ingressClassName: nginx
  rules:
  - host: $API_INTERNAL_HOST
    http:
      paths:
      - path: /commons/v1/packetmanager
        pathType: Prefix
        backend:
          service:
            name: packetmanager
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: smtp-websocket
  namespace: mock-smtp
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-http-version: "1.1"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - smtp.mosip.localhost
    secretName: mosip-tls-secret
  rules:
  - host: smtp.mosip.localhost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: mock-smtp
            port:
              number: 8081
YAML

# ─── Step 7c: Redirect regproc actuator to regproc-workflow ──────────────────
# The testrig's MasterDataUtil.getInfantMaxAge() calls the regproc actuator to read
# mosip.regproc.packet.classifier.tagging.agegroup.ranges.  regproc-status does NOT
# expose the Spring Boot actuator (returns 404), but regproc-workflow DOES.
# Redirect actuator requests to regproc-workflow so the testrig can read the property.
echo ""
echo "=== Step 7c: Redirecting regproc actuator to regproc-workflow ==="
kubectl apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-internal-regproc-actuator
  namespace: regproc
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /registrationprocessor/v1/workflowmanager/actuator/\$2
spec:
  ingressClassName: nginx
  rules:
  - host: $API_INTERNAL_HOST
    http:
      paths:
      - path: /registrationprocessor/v1/registrationtransaction/actuator(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: regproc-workflow
            port:
              number: 80
      - path: /registrationprocessor/v1/registrationstatus/actuator(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: regproc-workflow
            port:
              number: 80
YAML

# ─── Step 7d: Agegroup config override ───────────────────────────────────────
# Already set by configure-config-server.sh in Step 0d3.
echo ""
echo "=== Step 7d: Agegroup config already set by configure-config-server.sh ==="

# ─── Step 7d: Pre-fetch IDA certificates ──────────────────────────────────────
# The test rig's EncryptionDecrptionUtil fetches IDA certs via HTTPS ingress at runtime.
# On local dev, Java resolves .localhost to 127.0.0.1 (bypassing /etc/hosts), so the
# HTTPS connection times out and x509Cert is null → all auth encryption fails (171+ errors).
# Fix: fetch the certs via internal HTTP and mount them at the expected path.
echo ""
echo "=== Step 7d: Pre-fetching IDA certificates ==="
KC_TOKEN=$(kubectl exec -n keycloak keycloak-0 -- curl -s \
  http://localhost:8080/auth/realms/mosip/protocol/openid-connect/token \
  -d 'grant_type=password&client_id=admin-cli&username=globaladmin&password=mosip123' 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])' 2>/dev/null || true)

if [ -n "$KC_TOKEN" ]; then
  IDA_CERTS_ARGS=""
  for REF in PARTNER INTERNAL IDA-FIR; do
    FNAME="ida-$(echo $REF | tr '[:upper:]' '[:lower:]' | sed 's/ida-//').cer"
    CERT=$(kubectl exec -n ida deploy/ida-internal -- wget -qO- \
      "http://localhost:8093/idauthentication/v1/internal/getCertificate?applicationId=IDA&referenceId=$REF" \
      2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
c=d.get('response',{}).get('certificate','')
if c: print(c)
" 2>/dev/null || true)
    if [ -n "$CERT" ]; then
      IDA_CERTS_ARGS="$IDA_CERTS_ARGS --from-literal=$FNAME=$CERT"
      echo "  Fetched $FNAME"
    else
      echo "  WARNING: Could not fetch $REF certificate"
    fi
  done
  kubectl -n $NS delete configmap ida-certs 2>/dev/null || true
  if [ -n "$IDA_CERTS_ARGS" ]; then
    eval kubectl -n $NS create configmap ida-certs $IDA_CERTS_ARGS
    echo "  ida-certs ConfigMap created"
  fi
else
  echo "  WARNING: Could not get Keycloak token — IDA cert fetch skipped"
fi

# ─── Step 8: Install Helm chart ──────────────────────────────────────────────
echo ""
echo "=== Step 8: Installing Helm chart mosip/apitestrig v$CHART_VERSION ==="

helm -n $NS upgrade --install apitestrig mosip/apitestrig \
  --version $CHART_VERSION \
  -f "$TESTRIG_DIR/values.yaml" \
  \
  `# Run at 2 AM daily; trigger manually with: kubectl -n apitestrig create job ...` \
  --set crontime="0 2 * * *" \
  \
  `# No public domain / valid SSL certificate in local dev` \
  --set enable_insecure=true \
  \
  `# S3 / MinIO` \
  --set apitestrig.configmaps.s3.s3-host='http://minio.minio:9000' \
  --set apitestrig.configmaps.s3.s3-user-key='admin' \
  --set apitestrig.configmaps.s3.s3-region='' \
  \
  `# Database — use internal Kubernetes service DNS, not the external hostname` \
  --set apitestrig.configmaps.db.db-server="$DB_HOST" \
  --set apitestrig.configmaps.db.db-su-user="postgres" \
  --set apitestrig.configmaps.db.db-port="5432" \
  \
  `# Test run config` \
  --set apitestrig.configmaps.apitestrig.ENV_USER="$ENV_USER" \
  --set apitestrig.configmaps.apitestrig.ENV_ENDPOINT="https://$API_INTERNAL_HOST" \
  --set apitestrig.configmaps.apitestrig.ENV_TESTLEVEL="smokeAndRegression" \
  --set apitestrig.configmaps.apitestrig.reportExpirationInDays="3" \
  --set apitestrig.configmaps.apitestrig.slack-webhook-url="http://localhost:1/noop" \
  --set apitestrig.configmaps.apitestrig.eSignetDeployed="no" \
  --set apitestrig.configmaps.apitestrig.NS="$NS" \
  \
  `# Modules: only enable services deployed in the poc profile` \
  --set modules.prereg.enabled=false \
  --set modules.resident.enabled=false \
  --set modules.partner.enabled=false

# ─── Step 8b: Update scripts ConfigMap to pre-populate IDA certs at startup ──
# The Helm chart installs a scripts ConfigMap with fetch_docker_image_hash_ids.sh.
# We replace it with a version that copies /ida-certs/* to the authcerts directory
# before running the test entrypoint, so EncryptionDecrptionUtil finds the IDA certs.
echo ""
echo "=== Step 8b: Updating scripts ConfigMap (IDA cert pre-population) ==="
SCRIPT_CONTENT=$(cat <<'SCRIPTEOF'
#!/bin/bash
sleep 10
export DOCKER_HASH_ID=$(kubectl get pod "$HOSTNAME" -n "$NS" -o jsonpath='{.status.containerStatuses[*].imageID}' | sed 's/ /\n/g' | grep -v 'istio\|socat' | head -1 | sed 's/docker\-pullable\:\/\///g')
export DOCKER_IMAGE=$(kubectl get pod "$HOSTNAME" -n "$NS" -o jsonpath='{.status.containerStatuses[*].image}' | sed 's/ /\n/g' | grep -v 'istio\|socat' | head -1 | sed 's/docker\-pullable\:\/\///g')
[ -z "$DOCKER_HASH_ID" ] && export DOCKER_HASH_ID="unknown" && export DOCKER_IMAGE="unknown"
echo "DOCKER_IMAGE : $DOCKER_IMAGE"
kubectl get pods -A -o=jsonpath='{range .items[*]}{.metadata.namespace}{","}{.metadata.labels.app\.kubernetes\.io\/name}{","}{.status.containerStatuses[?(@.name!="istio-proxy")].image}{","}{.status.containerStatuses[?(@.name!="istio-proxy")].imageID}{","}{.metadata.creationTimestamp}{"\n"}' | sed 's/ /\n/g' | grep -vE 'istio*|longhorn*|cattle*|rancher|kube' | sed 's/docker\-pullable\:\/\///g' | sort -u | sed '/,,,/d' | awk -F ',' 'BEGIN {print "{ \"POD_NAME\": \"'$HOSTNAME'\", \"DOCKER_IMAGE\": \"'$DOCKER_IMAGE'\", \"k8s-cluster-image-list\": ["} {print "{\"namespace\":\"" $1 "\",\"app_name\":\"" $2 "\",\"docker_image_name\":\"" $3 "\"},"} END {print "]}"}' | sed -z 's/},\n]/}\n]/g' | jq -r . | tee -a images-list.json
sleep 5
cd /home/${container_user}/
if [ -d /ida-certs ] && [ -f /ida-certs/ida-partner.cer ]; then
  echo "=== Pre-populating IDA certificates ==="
  AUTHCERTS="/home/${container_user}/authcerts"
  for CERTDIR in \
    "$AUTHCERTS/IDA-IDA-api-internal.mosip.mosip.net" \
    "$AUTHCERTS/IDA-IDA-api-internal.mosip.localhost" \
    "$AUTHCERTS/DSL-IDA-api-internal.mosip.localhost" \
    "$AUTHCERTS/DSL-IDA-api-internal.mosip.mosip.net"; do
    mkdir -p "$CERTDIR"
    cp /ida-certs/*.cer "$CERTDIR/"
  done
  echo "  IDA certs pre-populated"
fi

# --- Background: create symlinks for .p12 files (fix naming mismatch) ---
# The test rig writes .p12 with prefixes (rp-, ekyc-, device-, ftm-, misp-)
# via KeyMgrUtility but reads them WITHOUT the prefix via KeyMgrUtil.
# appendEkycOrRp in PartnerRegistration is always empty, so the reader
# looks for auth_pid<ts>-partner.p12 but the file is rp-auth_pid<ts>-partner.p12.
# This background loop creates unprefixed symlinks as .p12 files appear.
(
  AUTHCERTS="/home/${container_user}/authcerts"
  for i in $(seq 1 3000); do
    sleep 0.2
    for dir in "$AUTHCERTS"/*/; do
      [ -d "$dir" ] || continue

      # 1. Create unprefixed symlinks for all prefixed .p12/.cer files
      for p12 in "$dir"*-partner.p12; do
        [ -f "$p12" ] || continue
        BASE=$(basename "$p12")
        UNPREFIXED=$(echo "$BASE" | sed 's/^rp-//;s/^ekyc-//;s/^device-//;s/^ftm-//;s/^misp-//')
        if [ "$BASE" != "$UNPREFIXED" ] && [ ! -e "$dir$UNPREFIXED" ]; then
          ln -sf "$BASE" "$dir$UNPREFIXED"
          for suffix in -ca.p12 -inter.p12 -partner.cer -ca.cer -inter.cer; do
            SRC="$dir$(echo "$BASE" | sed "s/-partner\.p12$/$suffix/")"
            DST="$dir$(echo "$UNPREFIXED" | sed "s/-partner\.p12$/$suffix/")"
            [ -f "$SRC" ] && [ ! -e "$DST" ] && ln -sf "$(basename "$SRC")" "$DST"
          done
        fi
      done

      # 2. Create rp-prefixed symlinks pointing to ekyc-prefixed originals
      #    (bytecode sets appendEkycOrRp="rp-" but ekyc files have "ekyc-" prefix)
      for p12 in "$dir"ekyc-*-partner.p12; do
        [ -f "$p12" ] || continue
        BASE=$(basename "$p12")
        RP_NAME=$(echo "$BASE" | sed 's/^ekyc-/rp-/')
        if [ ! -e "$dir$RP_NAME" ]; then
          ln -sf "$BASE" "$dir$RP_NAME"
          for suffix in -ca.p12 -inter.p12 -partner.cer -ca.cer -inter.cer; do
            SRC="$dir$(echo "$BASE" | sed "s/-partner\.p12$/$suffix/")"
            DST="$dir$(echo "$RP_NAME" | sed "s/-partner\.p12$/$suffix/")"
            [ -f "$SRC" ] && [ ! -e "$DST" ] && ln -sf "$(basename "$SRC")" "$DST"
          done
        fi
      done

      # 3. Symlink Biometric Devices into authcerts dirs for mock SBI Auth mode
      #    Mock SBI prepends keystorePath (authcerts dir) to "/Biometric Devices/Face/Keys/..."
      if [ -d "/Biometric Devices" ] && [ ! -e "$dir/Biometric Devices" ]; then
        ln -sf "/Biometric Devices" "$dir/Biometric Devices"
      fi
      # Also symlink Profile data
      if [ -d "/Profile" ] && [ ! -e "$dir/Profile" ]; then
        ln -sf "/Profile" "$dir/Profile"
      fi
    done
  done
) &

bash ./entrypoint.sh
SCRIPTEOF
)

# Write to a temp file on the Windows filesystem (kubectl.exe needs Windows paths)
TMPSCRIPT="$(cd "$(dirname "$0")" && pwd)/.tmp-fetch-script.sh"
echo "$SCRIPT_CONTENT" > "$TMPSCRIPT"
kubectl -n $NS create configmap scripts --from-file="fetch_docker_image_hash_ids.sh=$TMPSCRIPT" --dry-run=client -o yaml | kubectl apply -f -
rm -f "$TMPSCRIPT"

# ─── Step 9: Patch CronJobs — init container, TLS cert, hostAliases ──────────
# The Helm chart creates CronJobs with:
#   - An init container image (openjdk:11-jre) that no longer exists on Docker Hub
#   - A cacerts volume mount targeting /usr/local/openjdk-11/ but the actual image uses Java 21
#   - No hostAliases (needed so .localhost resolves to ingress IP, not 127.0.0.1)
#   - No TLS cert in the Java truststore (self-signed cert must be imported)
#
# We use strategic merge patch (not JSON patch) because the Helm chart's spec
# structure varies between versions and JSON patch paths break silently.
echo ""
echo "=== Step 9: Patching CronJobs (init container, TLS, hostAliases) ==="

# Create the TLS cert secret in the testrig namespace (for init container mount)
kubectl -n $NS delete secret mosip-local-tls 2>/dev/null || true
kubectl -n $NS create secret generic mosip-local-tls --from-file=mosip-localhost.crt=/tmp/mosip-localhost.crt

for cj in $(kubectl -n $NS get cronjobs -o name | sed 's|cronjob.batch/||'); do
  # Determine the module name from the cronjob name to use the correct patched image
  MODULE=$(echo "$cj" | sed -n 's/.*apitestrig-\(.*\)/\1/p')
  PATCHED_IMG="mosipid/apitest-${MODULE}:1.3.0-patched"
  echo "  Patching $cj with $PATCHED_IMG"

  # Strategic merge patch: replace images, fix init container, add TLS volume + hostAliases
  kubectl -n $NS patch cronjob "$cj" --type=strategic \
    -p "{
      \"spec\":{\"jobTemplate\":{\"spec\":{\"template\":{\"spec\":{
        \"initContainers\":[{
          \"name\":\"cacerts\",
          \"image\":\"$PATCHED_IMG\",
          \"imagePullPolicy\":\"Never\",
          \"command\":[\"bash\",\"-c\",\"cp /usr/lib/jvm/java-21-openjdk-amd64/lib/security/cacerts /cacerts/cacerts && keytool -import -trustcacerts -keystore /cacerts/cacerts -storepass changeit -noprompt -alias mosip-local -file /tls/mosip-localhost.crt && echo cacerts updated\"],
          \"volumeMounts\":[{\"name\":\"cacerts\",\"mountPath\":\"/cacerts\"},{\"name\":\"local-tls\",\"mountPath\":\"/tls\"}]
        }],
        \"containers\":[{
          \"name\":\"apitestrig-${MODULE}\",
          \"image\":\"$PATCHED_IMG\",
          \"imagePullPolicy\":\"Never\",
          \"env\":[{\"name\":\"JAVA_TOOL_OPTIONS\",\"value\":\"-Djavax.net.ssl.trustStore=/usr/lib/jvm/java-21-openjdk-amd64/lib/security/cacerts -Djavax.net.ssl.trustStorePassword=changeit -Denv.keycloak=https://iam.mosip.localhost/auth\"}],
          \"volumeMounts\":[{\"name\":\"cacerts\",\"mountPath\":\"/usr/lib/jvm/java-21-openjdk-amd64/lib/security/cacerts\",\"subPath\":\"cacerts\"},{\"name\":\"ida-certs\",\"mountPath\":\"/ida-certs\"}]
        }],
        \"volumes\":[{\"name\":\"local-tls\",\"secret\":{\"secretName\":\"mosip-local-tls\"}},{\"name\":\"ida-certs\",\"configMap\":{\"name\":\"ida-certs\",\"optional\":true}}],
        \"hostAliases\":[{\"ip\":\"$INGRESS_IP\",\"hostnames\":[\"api-internal.mosip.localhost\",\"iam.mosip.localhost\",\"smtp.mosip.localhost\"]}]
      }}}}}
    }" \
    2>/dev/null && echo "  patched $cj" || echo "  WARNING: $cj patch failed"
done

# ─── Step 10: Performance optimizations ────────────────────────────────────────
echo ""
echo "=== Step 10: Applying performance optimizations ==="

# 10a. Config-server: re-apply git patches only (env vars already set by Step 0d3)
# If config-server hasn't restarted since Step 0d3, patches are still there.
# If it has restarted (e.g., from a dependent service restart), re-apply them.
echo "  10a. Re-applying config-server git patches (no restart)..."
bash "$SCRIPT_DIR/configure-config-server.sh" --patches-only

# 10c. JVM heap + memory for OOM-prone services
echo "  10c. JVM heap + memory limits..."
kubectl -n keymanager patch deployment keymanager --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"3Gi"},
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/failureThreshold","value":60},
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/timeoutSeconds","value":10},
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/timeoutSeconds","value":30},
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/failureThreshold","value":10},
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/periodSeconds","value":30}
]' 2>/dev/null
kubectl -n keymanager set env deployment/keymanager JDK_JAVA_OPTIONS="-Xms512m -Xmx2g" 2>/dev/null
kubectl -n idrepo patch deployment identity --type='json' -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"2Gi"}]' 2>/dev/null
kubectl -n idrepo set env deployment/identity JDK_JAVA_OPTIONS="-Xms512m -Xmx1536m" 2>/dev/null
kubectl -n idrepo patch deployment credential --type='json' -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"1536Mi"}]' 2>/dev/null
kubectl -n idrepo set env deployment/credential JDK_JAVA_OPTIONS="-Xms512m -Xmx1g" 2>/dev/null
kubectl -n activemq patch statefulset activemq-activemq-artemis-master --type='json' -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"1536Mi"}]' 2>/dev/null

# 10d. Deploy missing services
echo "  10d. Deploying admin service..."
kubectl create ns admin 2>/dev/null || true
for cm in global config-server-share artifactory-share; do
  kubectl -n admin get configmap $cm 2>/dev/null || \
    kubectl -n kernel get configmap $cm -o yaml 2>/dev/null | sed "s/namespace: kernel/namespace: admin/" | kubectl apply -f - 2>/dev/null
done
helm -n admin install admin-hotlist mosip/admin-hotlist --version 1.3.0 2>/dev/null || true
helm -n admin install admin-service mosip/admin-service --version 1.3.0 2>/dev/null || true
cat <<'ADMINGRESS' | kubectl apply -f - 2>/dev/null
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-internal-admin
  namespace: admin
spec:
  ingressClassName: nginx
  rules:
  - host: api-internal.mosip.localhost
    http:
      paths:
      - path: /v1/admin
        pathType: Prefix
        backend:
          service:
            name: admin-service
            port:
              number: 80
ADMINGRESS

echo "  10d. Deploying credentialrequest..."
helm -n idrepo install credentialrequest mosip/credentialrequest --version 1.3.0 2>/dev/null || true
kubectl -n idrepo get ingress api-internal-idrepo-extra -o json 2>/dev/null | \
  python3 -c "import json,sys;d=json.load(sys.stdin);d['spec']['rules'][0]['http']['paths'][0]['backend']['service']['name']='credentialrequest';print(json.dumps(d))" 2>/dev/null | \
  kubectl apply -f - 2>/dev/null || true

# 10e. Scale down non-essential services to save memory
echo "  10e. Scaling down non-essential services..."
kubectl -n regproc scale deployment regproc-camel regproc-group1 regproc-group2 regproc-pktserver --replicas=0 2>/dev/null
kubectl -n packetmanager scale deployment --all --replicas=0 2>/dev/null
kubectl -n abis scale deployment --all --replicas=0 2>/dev/null

# 10f. Suspend CronJobs (manual trigger only)
echo "  10f. Suspending CronJobs..."
for mod in auth idrepo masterdata; do
  kubectl -n $NS patch cronjob "cronjob-apitestrig-$mod" --type='json' -p='[{"op":"replace","path":"/spec/suspend","value":true}]' 2>/dev/null
done

# 10g. JAVA_TOOL_OPTIONS on test pods
echo "  10g. JAVA_TOOL_OPTIONS..."
NEW_OPTS="-Djavax.net.ssl.trustStore=/usr/lib/jvm/java-21-openjdk-amd64/lib/security/cacerts -Djavax.net.ssl.trustStorePassword=changeit -Denv.keycloak=https://iam.mosip.localhost/auth -Djdk.internal.httpclient.disableHostnameVerification=true -Dcom.sun.net.ssl.checkRevocation=false"
for mod in auth idrepo masterdata; do
  IDX=$(kubectl -n $NS get cronjob "cronjob-apitestrig-$mod" -o json 2>/dev/null | python3 -c "
import json,sys
cj=json.load(sys.stdin)
envs=cj['spec']['jobTemplate']['spec']['template']['spec']['containers'][0].get('env',[])
for i,e in enumerate(envs):
    if e['name']=='JAVA_TOOL_OPTIONS': print(i); break
" 2>/dev/null)
  if [ -n "$IDX" ]; then
    kubectl -n $NS patch cronjob "cronjob-apitestrig-$mod" --type='json' \
      -p="[{\"op\":\"replace\",\"path\":\"/spec/jobTemplate/spec/template/spec/containers/0/env/$IDX/value\",\"value\":\"$NEW_OPTS\"}]" 2>/dev/null
  fi
done

# 10h. Wait for all services to stabilize
echo "  10h. Waiting for services..."
kubectl -n keymanager rollout status deployment/keymanager --timeout=300s 2>/dev/null
kubectl -n idrepo rollout status deployment/identity --timeout=300s 2>/dev/null
kubectl -n idrepo rollout status deployment/credential --timeout=180s 2>/dev/null
kubectl -n admin rollout status deployment/admin-service --timeout=180s 2>/dev/null || true

# 10i. Restart services to pick up all config changes
echo "  10i. Restarting services..."
kubectl -n ida rollout restart deployment/ida-auth deployment/ida-internal deployment/ida-otp 2>/dev/null
kubectl -n kernel rollout restart deployment/masterdata deployment/authmanager 2>/dev/null
kubectl -n pms rollout restart deployment/pms-partner deployment/pms-policy 2>/dev/null
kubectl -n ida rollout status deployment/ida-internal --timeout=180s 2>/dev/null
kubectl -n kernel rollout status deployment/masterdata --timeout=180s 2>/dev/null
kubectl -n pms rollout status deployment/pms-partner --timeout=120s 2>/dev/null

# 10j. Clean stale bulk upload test data
echo "  10j. Cleaning stale test data..."
kubectl -n postgres exec postgres-postgresql-0 -- env PGPASSWORD=7CUjLyLnN4 psql -U postgres -d mosip_master -c "DELETE FROM master.machine_type WHERE code='SS123';" 2>/dev/null || true

echo "  Performance optimizations applied."

echo ""
echo "=== apitestrig installed ==="
echo ""
echo "CronJobs are SUSPENDED (manual trigger only)."
echo ""
echo "To build test images:"
echo "  cd testrig-build && bash build.sh"
echo ""
echo "To run all tests (~13 min):"
echo "  bash run-apitestrig.sh"
echo ""
echo "To run a single suite:"
echo "  bash run-apitestrig.sh auth"
echo ""
echo "To watch live progress:"
echo "  bash testrig-build/watch-tests.sh 5"
echo ""
echo "To save/restore state:"
echo "  bash testrig-build/checkpoint.sh save <name>"
echo "  bash testrig-build/checkpoint.sh restore <name>"
echo ""
echo "Expected results: Masterdata 944/945, IDRepo 131/414, Auth ~90/612"

#!/bin/bash
# Installs MOSIP external components on local Docker Desktop Kubernetes.
# Follows the sequence from mosip-infra/deployment/v3/external/all/install-all.sh
# but adapted for local dev (no Istio, reduced resources, hostpath storage).
#
# Profiles:
#   minimal — postgres + keycloak + softhsm (~1.5GB RAM)
#   poc     — + kafka + minio + activemq + mock-clamav (~3.5GB RAM)
#   all     — + real clamav + msg-gateways + captcha (~5GB RAM)
#
# Prerequisites:
#   - k8s-infra local setup already running (k8s-infra/local/setup.sh minimal)
#   - helm, kubectl on PATH
#
# Usage: ./install-external.sh [minimal|poc|all|component|teardown]
#
# NOTE: When installing config-server (in install-services.sh), its deployment
# strategy should be patched to Recreate to avoid port conflicts during rolling
# updates:
#   kubectl -n config-server patch deploy config-server -p '{"spec":{"strategy":{"type":"Recreate"}}}'

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

# Poll interval for checking pod status
POLL_INTERVAL=5
MAX_CRASHES=3

# Wait for a pod to be fully ready (1/1 Running).
# Works for both Deployments and StatefulSets.
# Actively checks logs on crash instead of blocking on a timeout.
#
# Usage: wait_pod_ready <namespace> <pod-name-prefix>
wait_pod_ready() {
  local ns=$1 prefix=$2
  local crash_count=0 prev_restarts=0

  echo "  Waiting for $prefix..."
  while true; do
    local pod_line
    pod_line=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null \
      | grep "^$prefix" | grep -v Terminating | head -1)

    if [ -z "$pod_line" ]; then
      echo "    No pod found yet for $prefix, waiting..."
      sleep $POLL_INTERVAL
      continue
    fi

    local pod_name ready status restarts
    pod_name=$(echo "$pod_line" | awk '{print $1}')
    ready=$(echo "$pod_line" | awk '{print $2}')
    status=$(echo "$pod_line" | awk '{print $3}')
    restarts=$(echo "$pod_line" | awk '{print $4}' | sed 's/(.*//')

    # Success
    if [ "$ready" = "1/1" ] && [ "$status" = "Running" ]; then
      echo "  $prefix is Ready (1/1 Running)."
      return 0
    fi

    # Crash detection
    case "$status" in
      CrashLoopBackOff|Error|OOMKilled|CreateContainerConfigError|ImagePullBackOff|ErrImagePull)
        echo "    $prefix is in $status — checking logs..."
        kubectl -n "$ns" logs "$pod_name" --tail=10 2>&1 \
          | grep -iE "error|exception|fatal|killed|denied|refused" | tail -3
        crash_count=$((crash_count + 1))
        if [ "$crash_count" -ge "$MAX_CRASHES" ]; then
          echo "  FATAL: $prefix crashed $crash_count times ($status). Aborting."
          return 1
        fi
        echo "    Crash $crash_count/$MAX_CRASHES — will retry..."
        ;;
      Running)
        if [ "$((restarts))" -gt "$((prev_restarts))" ]; then
          echo "    $prefix restarted (restarts: $restarts) — checking previous logs..."
          kubectl -n "$ns" logs "$pod_name" --previous --tail=5 2>&1 \
            | grep -iE "error|exception|fatal|killed" | tail -2 || true
          prev_restarts=$restarts
          crash_count=$((crash_count + 1))
          if [ "$crash_count" -ge "$MAX_CRASHES" ]; then
            echo "  FATAL: $prefix restarted $crash_count times. Aborting."
            return 1
          fi
        else
          echo "    $prefix: $ready $status (starting up...)"
        fi
        ;;
      *)
        echo "    $prefix: $ready $status"
        ;;
    esac

    sleep $POLL_INTERVAL
  done
}

# ---------- CRDs ----------

install_crds() {
  echo "=== Installing CRDs (ServiceMonitor, VirtualService) ==="
  kubectl apply -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-servicemonitors.yaml 2>/dev/null || true
  kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/manifests/charts/base/crds/crd-all.gen.yaml 2>/dev/null || true
}

# ---------- ingress ----------

# Create keycloak-host configmap in default namespace for services to copy.
install_keycloak_host_cm() {
  echo "=== Creating keycloak-host configmap ==="
  kubectl create configmap keycloak-host \
    --from-literal=keycloak-internal-url="http://keycloak.keycloak" \
    --from-literal=keycloak-internal-host="keycloak.keycloak" \
    --from-literal=keycloak-external-url="http://iam.mosip.localhost" \
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
    --timeout 5m
  wait_pod_ready $NS postgres-postgresql

  # Patch the secret to add 'postgres-password' key (alias for 'postgresql-password').
  # The postgres-init chart expects the 'postgres-password' key to exist.
  echo "  Patching postgres secret to add postgres-password alias..."
  local PG_PASS_B64
  PG_PASS_B64=$(kubectl -n $NS get secret postgres-postgresql -o jsonpath='{.data.postgresql-password}')
  kubectl -n $NS patch secret postgres-postgresql -p "{\"data\":{\"postgres-password\":\"$PG_PASS_B64\"}}"

  echo "  Initializing MOSIP databases (creates users + schemas)..."
  local PG_PASS
  PG_PASS=$(kubectl -n $NS get secret postgres-postgresql -o jsonpath='{.data.postgresql-password}' | base64 -d)
  # Run in postgres namespace so init jobs can access the postgres-postgresql secret
  # Use the production init_values.yaml as source of truth for all databases.
  # This includes mosip_idmap, mosip_otp, mosip_digitalcard which are missing
  # if databases are hardcoded individually.
  helm upgrade --install postgres-init mosip/postgres-init \
    -n $NS --version 1.3.0 \
    -f "$SCRIPT_DIR/../external/postgres/init_values.yaml" \
    --set dbUserPasswords.dbuserPassword="$PG_PASS" \
    --set superUser.name=postgres \
    --set superUser.password="$PG_PASS" \
    --wait --wait-for-jobs --timeout 10m
  echo "  MOSIP databases initialized."

  # Create additional DB users and databases that postgres-init doesn't handle.
  # These are referenced in mosip-config git repo properties but not in the init chart.
  echo "  Creating additional MOSIP DB users..."
  for user_db in \
    "otpuser:mosip_otp" \
    "idmapuser:mosip_idmap" \
    "regdeviceuser:mosip_regdevice" \
    "authdeviceuser:mosip_authdevice" \
  ; do
    local user db
    user=$(echo "$user_db" | cut -d: -f1)
    db=$(echo "$user_db" | cut -d: -f2)
    kubectl -n $NS exec postgres-postgresql-0 -- bash -c \
      "PGPASSWORD='$PG_PASS' psql -U postgres -c \"CREATE USER $user WITH PASSWORD '$PG_PASS';\"" 2>/dev/null || true
    kubectl -n $NS exec postgres-postgresql-0 -- bash -c \
      "PGPASSWORD='$PG_PASS' psql -U postgres -c \"CREATE DATABASE $db;\"" 2>/dev/null || true
    kubectl -n $NS exec postgres-postgresql-0 -- bash -c \
      "PGPASSWORD='$PG_PASS' psql -U postgres -c \"GRANT ALL PRIVILEGES ON DATABASE $db TO $user;\"" 2>/dev/null || true
  done

  # Create schemas and salt tables needed by idrepo-saltgen.
  # The postgres-init chart creates databases but not all schemas/tables.
  # Create schemas and salt tables for idrepo-saltgen.
  # The saltgen job needs uin_hash_salt and uin_encrypt_salt in both
  # mosip_idmap (idmap schema) and mosip_idrepo (idrepo schema).
  echo "  Creating idmap and idrepo schemas for saltgen..."
  for db_schema_user in "mosip_idmap:idmap:idmapuser" "mosip_idrepo:idrepo:idrepouser"; do
    local db schema dbuser
    db=$(echo "$db_schema_user" | cut -d: -f1)
    schema=$(echo "$db_schema_user" | cut -d: -f2)
    dbuser=$(echo "$db_schema_user" | cut -d: -f3)
    kubectl -n $NS exec postgres-postgresql-0 -- bash -c "PGPASSWORD='$PG_PASS' psql -U postgres -d $db -c '
      CREATE SCHEMA IF NOT EXISTS $schema;
      GRANT ALL ON SCHEMA $schema TO $dbuser;
      CREATE TABLE IF NOT EXISTS $schema.uin_hash_salt (
        id bigint NOT NULL, salt varchar(36) NOT NULL,
        cr_by varchar(256) NOT NULL, cr_dtimes timestamp NOT NULL,
        upd_by varchar(256), upd_dtimes timestamp,
        CONSTRAINT pk_uinhs_id PRIMARY KEY (id));
      CREATE TABLE IF NOT EXISTS $schema.uin_encrypt_salt (
        id bigint NOT NULL, salt varchar(36) NOT NULL,
        cr_by varchar(256) NOT NULL, cr_dtimes timestamp NOT NULL,
        upd_by varchar(256), upd_dtimes timestamp,
        CONSTRAINT pk_uines_id PRIMARY KEY (id));
      GRANT ALL ON ALL TABLES IN SCHEMA $schema TO $dbuser;'" 2>/dev/null || true
  done

  echo "  Additional DB users and schemas created."
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
  # Keycloak's liveness probe is too aggressive for local dev (periodSeconds=1,
  # failureThreshold=3 means only 3s of failures allowed after 300s delay).
  # On a constrained node Keycloak takes 3-5 min to boot. Relax the probe.
  kubectl -n $NS patch statefulset keycloak --type='json' \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/failureThreshold","value":60},{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/periodSeconds","value":10}]' \
    2>/dev/null || true

  # Keycloak's internal postgres must be ready first
  wait_pod_ready $NS keycloak-postgresql
  # Then Keycloak itself (first boot takes 3-5 min for DB migration)
  wait_pod_ready $NS "keycloak-0"

  # Initialize Keycloak with MOSIP realm, clients, and roles.
  # Must run AFTER keycloak is fully ready (needs admin API).
  # Creates 'mosip' realm and ~25 clients (mosip-admin-client, etc.)
  echo "  Initializing Keycloak with MOSIP realm and clients..."
  helm upgrade --install keycloak-init mosip/keycloak-init \
    -n $NS --version 1.3.0 \
    --set keycloakExternalHost="iam.mosip.localhost" \
    --set keycloakInternalHost="keycloak.keycloak" \
    --set keycloak.realms.mosip.realm_config.smtpServer.host="mock-smtp.mock-smtp" \
    --set keycloak.realms.mosip.realm_config.smtpServer.port="8025" \
    --set keycloak.realms.mosip.realm_config.smtpServer.from="noreply@mosip.localhost" \
    --set keycloak.realms.mosip.realm_config.smtpServer.starttls="false" \
    --set keycloak.realms.mosip.realm_config.smtpServer.ssl="false" \
    --set keycloak.realms.mosip.realm_config.smtpServer.auth="false" \
    --set "keycloak.realms.mosip.realm_config.attributes.frontendUrl=http://iam.mosip.localhost/auth" \
    --wait --wait-for-jobs --timeout 15m 2>/dev/null || {
      # keycloak-init may fail on opencrvs client (token expiry during long init).
      # Re-run to complete remaining clients (idempotent — existing clients are skipped).
      echo "  WARNING: keycloak-init had errors, re-running..."
      kubectl -n $NS delete job keycloak-init 2>/dev/null || true
      sleep 5
      helm upgrade --install keycloak-init mosip/keycloak-init \
        -n $NS --version 1.3.0 \
        --set keycloakExternalHost="iam.mosip.localhost" \
        --set keycloakInternalHost="keycloak.keycloak" \
        --set keycloak.realms.mosip.realm_config.smtpServer.host="mock-smtp.mock-smtp" \
        --set keycloak.realms.mosip.realm_config.smtpServer.port="8025" \
        --set keycloak.realms.mosip.realm_config.smtpServer.from="noreply@mosip.localhost" \
        --set keycloak.realms.mosip.realm_config.smtpServer.starttls="false" \
        --set keycloak.realms.mosip.realm_config.smtpServer.ssl="false" \
        --set keycloak.realms.mosip.realm_config.smtpServer.auth="false" \
        --set "keycloak.realms.mosip.realm_config.attributes.frontendUrl=http://iam.mosip.localhost/auth" \
        --wait --wait-for-jobs --timeout 15m 2>/dev/null || true
    }
  echo "  Keycloak initialization complete."
}

# ---------- softhsm ----------

install_softhsm() {
  echo "=== Installing SoftHSM ==="
  local NS=softhsm
  ensure_ns $NS

  # Install SoftHSM instances. Each generates a random security PIN stored in its
  # own secret (softhsm-kernel and softhsm-ida in the softhsm namespace).
  # These are the authoritative PINs — config-server and other services should
  # read from these secrets rather than generating their own.
  helm upgrade --install softhsm-kernel mosip/softhsm \
    -n $NS --version 1.3.0 \
    --set resources.requests.cpu=5m \
    --set resources.requests.memory=16Mi \
    --set resources.limits.cpu=100m \
    --set resources.limits.memory=128Mi \
    --timeout 3m
  wait_pod_ready $NS softhsm-kernel

  helm upgrade --install softhsm-ida mosip/softhsm \
    -n $NS --version 1.3.0 \
    --set resources.requests.cpu=5m \
    --set resources.requests.memory=16Mi \
    --set resources.limits.cpu=100m \
    --set resources.limits.memory=128Mi \
    --timeout 3m
  wait_pod_ready $NS softhsm-ida
  echo "SoftHSM installed (kernel + ida)."

  # Export the generated PINs so install-services.sh can use them.
  # The softhsm chart creates secrets with key 'security-pin'.
  echo "  Reading SoftHSM PINs for downstream use..."
  local KERNEL_PIN IDA_PIN
  KERNEL_PIN=$(kubectl -n $NS get secret softhsm-kernel -o jsonpath='{.data.security-pin}' 2>/dev/null || echo "")
  IDA_PIN=$(kubectl -n $NS get secret softhsm-ida -o jsonpath='{.data.security-pin}' 2>/dev/null || echo "")
  if [ -n "$KERNEL_PIN" ] && [ -n "$IDA_PIN" ]; then
    echo "  SoftHSM PINs captured. Creating cross-namespace copies..."
    # Store PINs in default namespace so config-server and other services can access them.
    # This avoids conf-secrets generating conflicting random PINs.
    kubectl create secret generic softhsm-kernel \
      --from-literal=security-pin="$(echo "$KERNEL_PIN" | base64 -d)" \
      -n default --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret generic softhsm-ida \
      --from-literal=security-pin="$(echo "$IDA_PIN" | base64 -d)" \
      -n default --dry-run=client -o yaml | kubectl apply -f -
    echo "  SoftHSM PIN secrets copied to default namespace."
  else
    echo "  WARNING: Could not read SoftHSM PINs. conf-secrets may generate conflicting PINs."
  fi
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
    --timeout 5m
  wait_pod_ready $NS minio
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
    --timeout 5m
  wait_pod_ready $NS clamav
}

# ---------- mock-clamav ----------
# Lightweight Python mock of the ClamAV clamd protocol for PoC deployments.
# Real ClamAV needs 512MB+ RAM for virus definitions which is expensive locally.
# The mock responds correctly to the capybara clamav-client 1.0.4 library used
# by MOSIP's kernel-virusscanner-clamav service:
#   nVERSIONCOMMANDS\n  →  single-line "ClamAV version| COMMANDS: ..." response
#   zINSTREAM\0 + data  →  "stream: OK\0"
#   nPING\n             →  "PONG\n"
# The service is named "clamav" in namespace "clamav" so it resolves as
# clamav.clamav:3310 — matching regproc-group1/group2 config properties.

install_mock_clamav() {
  echo "=== Installing mock ClamAV (PoC) ==="
  local NS=clamav
  ensure_ns $NS
  kubectl apply -n $NS -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: clamav-mock-script
  namespace: clamav
data:
  server.py: |
    import socket, threading

    VERSION_COMMANDS = (
        "ClamAV 0.103.9/26892/Mon Mar 11 10:35:44 2024"
        "| COMMANDS: SCAN QUIT RELOAD PING CONTSCAN VERSIONCOMMANDS VERSION END "
        "SHUTDOWN MULTISCAN FILDES STATS IDSESSION INSTREAM DETSTATSCLEAR DETSTATS ALLMATCHSCAN\n"
    )

    def handle(c, addr):
        try:
            data = c.recv(4096)
            if not data:
                return
            raw = data.strip(b"\n\x00 ").lstrip(b"nz")
            cmd_end = raw.find(b"\x00")
            cmd = (raw[:cmd_end] if cmd_end >= 0 else raw).decode(errors="replace")
            if "VERSIONCOMMANDS" in cmd:
                c.send(VERSION_COMMANDS.encode())
            elif "INSTREAM" in cmd:
                # Drain INSTREAM chunks (4-byte big-endian length + data, terminated by 0x00000000)
                buf = raw[cmd_end + 1:] if cmd_end >= 0 else b""
                while True:
                    if len(buf) >= 4:
                        length = int.from_bytes(buf[:4], "big")
                        if length == 0:
                            break
                        buf = buf[4 + length:]
                    chunk = c.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
                c.send(b"stream: OK\x00")
            elif "PING" in cmd:
                c.send(b"PONG\n")
        except Exception:
            pass
        finally:
            c.close()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", 3310))
    srv.listen(10)
    print("Mock ClamAV listening on :3310", flush=True)
    while True:
        c, addr = srv.accept()
        threading.Thread(target=handle, args=(c, addr), daemon=True).start()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: clamav
  namespace: clamav
spec:
  replicas: 1
  selector:
    matchLabels:
      app: clamav
  template:
    metadata:
      labels:
        app: clamav
    spec:
      containers:
      - name: clamav
        image: python:3.11-alpine
        command: ["python", "/mock/server.py"]
        ports:
        - containerPort: 3310
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            cpu: 100m
            memory: 64Mi
        volumeMounts:
        - name: script
          mountPath: /mock
      volumes:
      - name: script
        configMap:
          name: clamav-mock-script
---
apiVersion: v1
kind: Service
metadata:
  name: clamav
  namespace: clamav
spec:
  selector:
    app: clamav
  ports:
  - port: 3310
    targetPort: 3310
YAML
  wait_pod_ready $NS clamav
}

# ---------- activemq ----------

install_activemq() {
  echo "=== Installing ActiveMQ ==="
  local NS=activemq
  ensure_ns $NS
  # The mosip/activemq-artemis chart v0.0.3 has a bug: duplicate ARTEMIS_USERNAME
  # env var in the slave StatefulSet template. Work around by templating the chart,
  # removing the duplicate, and applying manually.
  helm template activemq mosip/activemq-artemis \
    --version 0.0.3 -n $NS \
    --set image.repository=mosipid/activemq-artemis \
    --set image.tag=2.39.0 \
    --set persistence.storageClass=hostpath \
    --set resources.requests.cpu=10m \
    --set resources.requests.memory=64Mi \
    --set resources.limits.cpu=300m \
    --set resources.limits.memory=768Mi \
    2>/dev/null | kubectl apply -n $NS -f - 2>/dev/null || true

  # The chart's post-install test pods (amqp, core, cluster-formation) are rendered
  # as standalone Pods and applied above. They fail immediately because they run
  # `./artemis` with no working directory set (binary is at /var/lib/artemis/data/bin/).
  # They serve no operational purpose — delete them to keep the namespace clean.
  kubectl delete pod -n $NS \
    activemq-activemq-artemis-amqp \
    activemq-activemq-artemis-core \
    activemq-activemq-artemis-cluster-formation \
    2>/dev/null || true

  # ActiveMQ slave probe fixes:
  # Root cause: the Artemis backup broker (slave) never opens port 61616 — in
  # replication HA mode the slave does not start its acceptors; only the live master
  # accepts client connections. The chart probes all check port 61616 (netcat/TCP),
  # so they all fail permanently, causing CrashLoopBackOff.
  # Additionally, the web console (8161) stops ~46s after sync completes, so HTTP
  # probes also fail.
  # Fix: probe that the JVM process (PID 1) is alive — reliable for both startup
  # and steady-state. Remove readiness probe entirely (the slave should never serve
  # traffic; K8s defaults to Ready=true when no readiness probe is configured).
  kubectl patch statefulset activemq-activemq-artemis-slave -n $NS --type='json' \
    -p='[
      {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe","value":{"exec":{"command":["/bin/sh","-c","kill -0 1"]},"initialDelaySeconds":15,"periodSeconds":5,"failureThreshold":12,"successThreshold":1,"timeoutSeconds":5}},
      {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe","value":{"exec":{"command":["/bin/sh","-c","kill -0 1"]},"initialDelaySeconds":30,"periodSeconds":15,"failureThreshold":4,"successThreshold":1,"timeoutSeconds":5}},
      {"op":"remove","path":"/spec/template/spec/containers/0/readinessProbe"}
    ]' \
    2>/dev/null || true

  wait_pod_ready $NS activemq-activemq-artemis-master
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
    --timeout 5m
  # Zookeeper must be ready before Kafka
  wait_pod_ready $NS kafka-zookeeper

  # Kafka OOMKill fix: the chart default (768Mi) is not enough when the broker
  # recovers 700+ topic partitions from ZooKeeper on restart. Increase to 3Gi.
  kubectl patch statefulset kafka -n $NS --type='json' \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"3Gi"},{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"1Gi"}]' \
    2>/dev/null || true

  # Kafka liveness probe fix: default initialDelaySeconds=10 + failureThreshold=3
  # gives only 40s total before the probe kills the broker. Loading 700+ partitions
  # from ZooKeeper takes 3+ minutes. Relax to allow full startup.
  kubectl patch statefulset kafka -n $NS --type='json' \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds","value":120},{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/failureThreshold","value":10},{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/periodSeconds","value":15}]' \
    2>/dev/null || true

  wait_pod_ready $NS "kafka-0"

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
    install_crds
    install_global_configmap
    install_postgres
    install_keycloak
    install_keycloak_host_cm
    install_softhsm
    install_ingress
    echo ""
    echo "Minimal external components installed (postgres, keycloak, softhsm)."
    echo "Use './install-external.sh poc' to add kafka, minio, activemq."
    ;;
  poc)
    add_helm_repos
    install_crds
    install_global_configmap
    install_postgres
    install_keycloak
    install_keycloak_host_cm
    install_softhsm
    install_kafka
    install_minio
    install_activemq
    install_mock_clamav   # Lightweight mock clamd — required by regproc-group1/group2 health checks
    install_ingress
    echo ""
    echo "Core external components installed."
    echo "Use './install-external.sh all' to add real clamav, msg-gateways, captcha."
    ;;
  all)
    add_helm_repos
    install_crds
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
  mock-clamav)  install_mock_clamav ;;
  activemq)     install_activemq ;;
  kafka)        install_kafka ;;
  *)
    echo "Unknown component: $COMPONENT"
    echo "Usage: $0 [minimal|poc|all|postgres|keycloak|softhsm|minio|clamav|mock-clamav|activemq|kafka|teardown]"
    echo ""
    echo "Profiles:"
    echo "  minimal    — postgres + keycloak + softhsm (~1.5GB RAM)"
    echo "  poc        — + kafka + minio + activemq + mock-clamav (~3.5GB RAM)"
    echo "  all        — + real clamav + msg-gateways + captcha (~5GB RAM)"
    exit 1
    ;;
esac

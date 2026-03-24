#!/bin/bash
# Restarts MOSIP services in dependency order after a Docker Desktop restart.
#
# Unlike install-services.sh, this does NOT create namespaces, configmaps,
# secrets, or run helm install. It only waits for existing pods to recover
# in the correct order, restarting stuck pods as needed.
#
# Usage: ./restart.sh [minimal|poc|all|status]

set -e
set -o pipefail

PROFILE="${1:-minimal}"
POLL_INTERVAL=5

# Wait for a pod to be 1/1 Ready. If stuck in CrashLoopBackOff for too long,
# delete the pod to reset the backoff timer.
wait_pod() {
  local ns=$1 prefix=$2
  local crash_count=0 max_crashes=5

  for i in $(seq 1 120); do
    local line
    line=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null \
      | grep "^$prefix" | grep -v Terminating | head -1)

    if [ -z "$line" ]; then
      echo "    $prefix: no pod found"
      sleep $POLL_INTERVAL
      continue
    fi

    local pod ready status restarts
    pod=$(echo "$line" | awk '{print $1}')
    ready=$(echo "$line" | awk '{print $2}')
    status=$(echo "$line" | awk '{print $3}')
    restarts=$(echo "$line" | awk '{print $4}' | sed 's/(.*//')

    if [ "$ready" = "1/1" ] && [ "$status" = "Running" ]; then
      echo "  $prefix Ready"
      return 0
    fi

    # If stuck in CrashLoopBackOff with high restart count, delete to reset backoff
    if [ "$status" = "CrashLoopBackOff" ] && [ "$((restarts))" -ge 3 ]; then
      crash_count=$((crash_count + 1))
      if [ "$crash_count" -ge 3 ]; then
        echo "    $prefix: stuck in CrashLoopBackOff (restarts=$restarts), deleting to reset..."
        kubectl -n "$ns" delete pod "$pod" 2>/dev/null || true
        crash_count=0
        sleep $POLL_INTERVAL
        continue
      fi
    fi

    # Only print every 4th iteration to reduce noise
    if [ $((i % 4)) -eq 0 ]; then
      echo "    $prefix: $ready $status (restarts=$restarts)"
    fi

    sleep $POLL_INTERVAL
  done

  echo "  WARNING: $prefix did not become ready"
  return 1
}

wait_layer() {
  local label=$1
  shift
  echo "=== $label ==="
  for ns_dep in "$@"; do
    local ns dep
    ns=$(echo "$ns_dep" | cut -d/ -f1)
    dep=$(echo "$ns_dep" | cut -d/ -f2)
    wait_pod "$ns" "$dep"
  done
}

show_status() {
  local ok=0 total=0
  for ns_dep in \
    "postgres/postgres-postgresql" "keycloak/keycloak" "softhsm/softhsm-kernel" \
    "config-server/config-server" "keymanager/keymanager" "mock-smtp/mock-smtp" "biosdk/biosdk-service" \
    "kernel/authmanager" "kernel/auditmanager" "kernel/idgenerator" "kernel/masterdata" \
    "kernel/otpmanager" "kernel/pridgenerator" "kernel/ridgenerator" "kernel/syncdata" "kernel/notifier" \
    "idrepo/identity" "idrepo/credential" "idrepo/vid" \
  ; do
    total=$((total+1))
    local ns dep r
    ns=$(echo "$ns_dep" | cut -d/ -f1); dep=$(echo "$ns_dep" | cut -d/ -f2)
    r=$(kubectl -n "$ns" get pods --no-headers 2>&1 | grep "^$dep" | grep -v Terminating | head -1 | awk '{print $2}')
    if [ "$r" = "1/1" ]; then ok=$((ok+1)); else
      local s
      s=$(kubectl -n "$ns" get pods --no-headers 2>&1 | grep "^$dep" | grep -v Terminating | head -1 | awk '{print $3}')
      printf "  [  ] %-15s %-20s %s\n" "$ns" "$dep" "$s"
    fi
  done
  echo ""
  echo "$ok/$total Ready"
}

case "$PROFILE" in
  status) show_status; exit 0 ;;
esac

echo "Waiting for services to recover in dependency order..."
echo ""

# Layer 0: Infrastructure (no MOSIP dependencies)
wait_layer "Layer 0: Infrastructure" \
  "postgres/postgres-postgresql" \
  "softhsm/softhsm-kernel" \
  "softhsm/softhsm-ida" \
  "mock-smtp/mock-smtp"

# Layer 1: Keycloak (needs its own postgres, slow to boot)
wait_layer "Layer 1: Keycloak" \
  "keycloak/keycloak-postgresql" \
  "keycloak/keycloak-0"

# Layer 2: Config-server (needs postgres)
wait_layer "Layer 2: Config-server" \
  "config-server/config-server"

# Layer 3: Keymanager + BioSDK (need config-server + softhsm)
wait_layer "Layer 3: Keymanager + BioSDK" \
  "keymanager/keymanager" \
  "biosdk/biosdk-service"

# Layer 4: Kernel (needs config-server + keymanager)
if [ "$PROFILE" != "minimal" ] && [ "$PROFILE" != "poc" ] && [ "$PROFILE" != "all" ]; then
  echo "Unknown profile: $PROFILE"; exit 1
fi

wait_layer "Layer 4: Kernel" \
  "kernel/authmanager" "kernel/auditmanager" "kernel/idgenerator" \
  "kernel/masterdata" "kernel/otpmanager" "kernel/pridgenerator" \
  "kernel/ridgenerator" "kernel/syncdata" "kernel/notifier"

# Layer 5: IdRepo (needs kernel + biosdk)
wait_layer "Layer 5: IdRepo" \
  "idrepo/identity" "idrepo/credential" "idrepo/vid"

# Core profile adds these
if [ "$PROFILE" = "poc" ] || [ "$PROFILE" = "all" ]; then
  wait_layer "Layer 6: Core services" \
    "websub/websub-consolidator" "websub/websub" \
    "packetmanager/packetmanager" "datashare/datashare" \
    "ida/ida-auth" "ida/ida-internal" "ida/ida-otp"
fi

# All profile adds these
if [ "$PROFILE" = "all" ]; then
  wait_layer "Layer 7: Full stack" \
    "regproc/regproc-workflow" "regproc/regproc-status" \
    "pms/pms-partner" "pms/pms-policy" \
    "admin/admin-service" "admin/admin-hotlist" \
    "resident/resident"
fi

echo ""
echo "=== All services recovered ==="
show_status

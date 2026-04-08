#!/bin/bash
set -euo pipefail

##############################################################################
# run-apitestrig.sh — Run MOSIP API test rigs (optimized)
#
# Config patches are now persistent env vars on config-server.
# No git clone patching needed. Only restarts services if explicitly requested.
#
# Usage:
#   bash run-apitestrig.sh                  # run all 3 suites
#   bash run-apitestrig.sh masterdata       # run one suite
#   bash run-apitestrig.sh --restart auth   # restart services then run auth
##############################################################################

SUITES=""
DO_RESTART=false

for arg in "$@"; do
  case "$arg" in
    --restart) DO_RESTART=true ;;
    *) SUITES="$SUITES $arg" ;;
  esac
done
SUITES="${SUITES:-masterdata idrepo auth}"
SUITES=$(echo $SUITES | xargs)  # trim

NS="apitestrig"
TS=$(date +%s)

if $DO_RESTART; then
  echo "=== Restarting services ==="
  kubectl -n kernel rollout restart deployment/masterdata deployment/authmanager 2>/dev/null
  kubectl -n ida rollout restart deployment/ida-auth deployment/ida-internal deployment/ida-otp 2>/dev/null
  kubectl -n pms rollout restart deployment/pms-partner deployment/pms-policy 2>/dev/null
  echo "Waiting for services..."
  kubectl -n kernel rollout status deployment/masterdata --timeout=180s 2>/dev/null
  kubectl -n kernel rollout status deployment/authmanager --timeout=120s 2>/dev/null
  kubectl -n ida rollout status deployment/ida-internal --timeout=180s 2>/dev/null
  kubectl -n pms rollout status deployment/pms-partner --timeout=120s 2>/dev/null
  echo "Services ready."
fi

echo "=== Service Health ==="
ALL_OK=true
for svc in "keymanager/keymanager" "idrepo/identity" "idrepo/credential" "pms/pms-partner" "kernel/authmanager" "kernel/masterdata"; do
  NS_SVC=$(echo $svc | cut -d/ -f1)
  DEP=$(echo $svc | cut -d/ -f2)
  READY=$(kubectl -n $NS_SVC get deployment/$DEP -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  if [ "${READY:-0}" = "0" ]; then
    printf "  %-30s NOT READY\n" "$svc"
    ALL_OK=false
  else
    printf "  %-30s OK\n" "$svc"
  fi
done
if ! $ALL_OK; then
  echo "WARNING: Some services not ready. Tests may fail."
fi

echo ""
echo "=== Launching tests: $SUITES ==="
kubectl -n "$NS" delete jobs --all --wait=false 2>/dev/null || true
sleep 2

JOBS=""
for SUITE in $SUITES; do
  JOB="t-${SUITE}-${TS}"
  CJ="cronjob-apitestrig-${SUITE}"
  kubectl -n "$NS" create job "$JOB" --from="cronjob/$CJ" 2>/dev/null
  JOBS="$JOBS job/$JOB"
  echo "  Created $JOB"
done

echo ""
echo "=== Waiting for tests (timeout 120 min) ==="
kubectl -n "$NS" wait --for=condition=complete $JOBS --timeout=7200s 2>/dev/null || true

echo ""
echo "========================================="
echo "            TEST RESULTS"
echo "========================================="

TOTAL_PASS=0 TOTAL_FAIL=0 TOTAL_SKIP=0
for SUITE in $SUITES; do
  JOB="t-${SUITE}-${TS}"
  RESULT=$(kubectl -n "$NS" logs "job/$JOB" 2>/dev/null | grep "^Total tests run:" | tail -1)
  [ -z "$RESULT" ] && RESULT="(no results)"
  P=$(echo "$RESULT" | grep -oP 'Passes: \K[0-9]+' || echo 0)
  F=$(echo "$RESULT" | grep -oP 'Failures: \K[0-9]+' || echo 0)
  S=$(echo "$RESULT" | grep -oP 'Skips: \K[0-9]+' || echo 0)
  TOTAL_PASS=$((TOTAL_PASS + P))
  TOTAL_FAIL=$((TOTAL_FAIL + F))
  TOTAL_SKIP=$((TOTAL_SKIP + S))
  printf "  %-12s %s\n" "${SUITE^^}:" "$RESULT"
done

echo ""
echo "  TOTAL: Passes=$TOTAL_PASS, Failures=$TOTAL_FAIL, Skips=$TOTAL_SKIP"
OTP=$(kubectl -n "$NS" logs "job/t-auth-${TS}" 2>/dev/null | grep -c "Not Able To Fetch OTP" || echo "?")
echo "  OTP errors: $OTP"
echo "========================================="

# Push results to Elasticsearch for Kibana dashboard
PUSH_SCRIPT="$(cd "$(dirname "$0")/../../../.." && pwd)/testrig-build/push-testrig-results.sh"
if [ -f "$PUSH_SCRIPT" ]; then
  echo ""
  echo "=== Pushing results to Kibana dashboard ==="
  for SUITE in $SUITES; do
    bash "$PUSH_SCRIPT" "t-${SUITE}-${TS}" 2>/dev/null || true
  done
fi

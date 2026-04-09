# MOSIP Local Development Guide

Local deployment of MOSIP v1.3.0 on Docker Desktop Kubernetes (single node, 48GB+ RAM).

## Quick Start

```bash
# 1. Infrastructure (k8s-infra repo)
cd k8s-infra/local && ./setup.sh minimal

# 2. External components + MOSIP services (mosip-infra repo)
cd mosip-infra/deployment/v3/local
./reset-and-deploy.sh            # Full fresh deployment (~45 min)

# 3. Test rig
./install-apitestrig.sh          # Build images + deploy tests (~20 min)
```

## Script Reference

| Script | Purpose | When to use |
|--------|---------|-------------|
| `reset-and-deploy.sh` | Full platform reset | Fresh start, recover from broken state |
| `install-external.sh` | Postgres, Keycloak, MinIO, SoftHSM | First-time setup or external component changes |
| `install-services.sh` | MOSIP services by dependency layer | After external components are running |
| `configure-config-server.sh` | ALL config overrides (single batch) | Called by install-services.sh; never run directly |
| `install-apitestrig.sh` | Test rig images and CronJobs | After services are running |
| `watch-tests.sh` (testrig-build/) | Live test dashboard | During test execution |

## Architecture

### Dependency Layers

Services deploy sequentially to avoid memory thrashing:

```
Layer 0: conf-secrets (configmaps/secrets only)
Layer 1: config-server (all services depend on this)
Layer 2: keymanager + keygen Job (master keys + 10K ZK encryption keys)
Layer 3: kernel (authmanager, auditmanager, idgenerator, otpmanager, etc.)
Layer 4: idrepo (identity, credential, credentialrequest, vid)
Layer 5: websub, biosdk, packetmanager, datashare
Layer 6: ida, regproc, pms, admin, resident
```

### Config Flow

All service configuration flows through config-server:

```
Kubernetes Secrets (postgres, minio, keycloak)
    |
    v
configure-config-server.sh  --- resolves secrets at runtime
    |
    v
Config-server env vars  --- persistent, survive pod restarts
    |
    v
Spring Cloud Config overrides  --- applied to ALL services
    |
    v
Individual services  --- read config at startup, cache tokens
```

**Key principle**: No ephemeral git clone patches. All overrides are in env vars or `SPRING_APPLICATION_JSON`. Config-server can restart freely.

### Secret Lifecycle

| Secret | Source | Persists across | Lost on |
|--------|--------|-----------------|---------|
| Postgres password | `postgres-postgresql` secret | Pod restart | DB recreate |
| MinIO password | `minio` secret | Pod restart | MinIO recreate |
| SoftHSM keys | SoftHSM PVC | Pod restart | PVC wipe |
| Keycloak clients | `keycloak-client-secrets` secret | Pod restart | keycloak-init rerun |
| ZK encryption keys | `mosip_keymgr.data_encrypt_keystore` table | Always | DB drop |

## Recovery Procedures

### Config-server restarted unexpectedly
**Impact**: None. All overrides are in env vars.
**Action**: No action needed. Services auto-reconnect.

### Service pod OOMKilled or crashed
**Impact**: Temporary 401 errors until token renewal (~5s).
**Action**: Pod auto-restarts. Self-healing.

### Keycloak restarted
**Impact**: All services get 401 for ~60s until Keycloak is back.
**Action**: Wait. Services auto-renew tokens.

### PostgreSQL restarted
**Impact**: Brief DB connection errors.
**Action**: Wait. HikariCP auto-reconnects.

### Full Docker Desktop restart
**Impact**: All pods restart. May take 5-10 minutes to stabilize.
**Action**: Wait. All PVCs persist. Services recover via restart policy.

### SoftHSM data lost (PVC wiped)
**Impact**: All encryption keys lost. Services fail with key errors.
**Action**: Run `reset-and-deploy.sh` for full fresh deployment.

### "Tests were passing, now they fail"
1. Check `watch-tests.sh` for service health
2. Check config-server is running: `kubectl -n config-server get pods`
3. Check for stale tokens: restart the failing service's namespace
4. Check MinIO: `kubectl -n minio get pods`
5. If all else fails: `reset-and-deploy.sh`

## Known Limitations

1. **v1.3.0 response format**: Identity API returns `response.entity` not `response.uin`. Test rig (v1.3.3 commons) expects `response.uin`.
2. **Partner auto-approval**: v1.3.0 requires admin approval. Handled by SQL UPDATE in install-apitestrig.sh.
3. **OTP WebSocket**: Requires ssl-redirect=false on smtp ingress. Baked into install-apitestrig.sh.
4. **SoftHSM is stateful**: PVC wipe requires full reset. No hot-key-rotation.
5. **Memory pressure**: 48GB+ recommended. Services use ~35GB at peak with all tests running.

## Config-server Overrides

All overrides set by `configure-config-server.sh`:

| Category | What | Why |
|----------|------|-----|
| Keycloak URLs | No `/auth` suffix | Config properties add `/auth/realms/mosip` |
| DB hostnames | `postgres-postgresql.postgres` | Local postgres service |
| DB password | From postgres secret | Dynamic, survives rotation |
| MinIO/S3 | `admin` + password from secret, no `s3a://` prefix | Local MinIO credentials |
| IDA timeout | 1 second | Default 180s makes tests take 90+ min |
| UIN/VID thresholds | 1000 | Default 200K takes hours to generate |
| JDBC driver | `org.postgresql.Driver` | Fixes keygen NPE in Spring Boot 3.x |
| Biosdk URL | `/extract-template` | Default has wrong path |
| Languages | `eng` mandatory, `ara,fra` optional | Test rig configuration |
| Admin batch delimiters | Comma | Default pipe causes parse errors |
| Audience lists | Includes `mosip-testrig-client` | Test rig auth |

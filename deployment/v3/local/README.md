# Local Development Setup

Scripts and value overrides for running the MOSIP stack on Docker Desktop Kubernetes.

## Prerequisites

- Docker Desktop with Kubernetes enabled
- `kubectl`, `helm` on PATH
- k8s-infra local setup running: `k8s-infra/local/setup.sh minimal`

## Profiles

Pick a profile based on your machine's RAM. All scripts support `minimal`, `core`, and `all`.

| Machine RAM | k8s-infra | external | services | What you get |
|-------------|-----------|----------|----------|--------------|
| 8GB | `minimal` | `minimal` | `minimal` | Identity store + kernel APIs |
| 16GB | `dev` | `core` | `core` | + ID verification + data pipeline |
| 24GB+ | `all` | `all` | `all` | Full stack incl. registration + portals |

### External component profiles

| Profile | Components | ~RAM |
|---------|-----------|------|
| `minimal` | postgres, keycloak, softhsm | ~1.5GB |
| `core` | + kafka, minio, activemq | ~3.5GB |
| `all` | + clamav, msg-gateways, captcha | ~5GB |

### Service profiles

| Profile | Services | ~RAM |
|---------|----------|------|
| `minimal` | config-server, kernel (9), idrepo (3), keymanager | ~6GB |
| `core` | + websub, biosdk, packetmanager, datashare, ida (3) | ~10GB |
| `all` | + regproc (6), prereg (4), admin, pms, mock-abis, resident | ~16GB |

## Quick Start

```bash
# Minimal (8GB machine) — identity store + kernel APIs
cd k8s-infra/local && ./setup.sh minimal
cd mosip-infra/deployment/v3/local
./install-external.sh minimal
./install-services.sh minimal

# Core (16GB machine) — adds ID auth, data pipeline
./install-external.sh core
./install-services.sh core

# Full (24GB+ machine) — everything
./install-external.sh all
./install-services.sh all
```

Profiles are additive — `helm upgrade --install` is idempotent, so running
`core` after `minimal` just adds the extra services without reinstalling.

```bash
# Check health
./install-services.sh status
```

## Individual Components

```bash
./install-external.sh postgres     # just PostgreSQL
./install-external.sh kafka        # just Kafka
./install-services.sh kernel       # just kernel services
./install-services.sh ida          # just IDA
```

## Teardown

```bash
./install-services.sh teardown     # remove MOSIP core services
./install-external.sh teardown     # remove external components
```

## Local Dev Gotchas

- **JVM heap**: MOSIP images hardcode 1.5GB heap. Scripts override to 512MB via `JDK_JAVA_OPTIONS`.
- **Init containers**: `openjdk:11-jre` removed from Docker Hub. Scripts patch to `eclipse-temurin:11-jre` or skip entirely.
- **Bitnami images**: MOSIP custom images fail Bitnami verification. Scripts pass `allowInsecureImages=true`.
- **Storage**: Uses `hostpath` (Docker Desktop default). No NFS/EBS needed.
- **Docker Hub rate limits**: If pods get stuck in `ImagePullBackOff`, pre-pull images via `docker pull mosipid/<image>:1.3.0`.

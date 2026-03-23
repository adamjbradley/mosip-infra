# Local Development Setup

Scripts and value overrides for running the full MOSIP stack on Docker Desktop Kubernetes.

## Prerequisites

- Docker Desktop with Kubernetes enabled (24GB+ RAM recommended)
- `kubectl`, `helm` on PATH
- k8s-infra local setup running (`k8s-infra/local/setup.sh`) — provides ingress-nginx
- Helm repo added: `helm repo add mosip https://mosip.github.io/mosip-helm && helm repo update`

## Quick Start

```bash
# 1. Install external components (postgres, keycloak, kafka, activemq, etc.)
./install-external.sh

# 2. Install MOSIP core services (kernel, idrepo, ida, regproc, etc.)
./install-services.sh

# 3. Check health
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
- **Memory**: Scale down monitoring/logging if memory-constrained. 16GB minimum, 24GB+ recommended.

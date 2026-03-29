# aegis-deploy

Podman-based deployment for the [AEGIS](https://docs.100monkeys.ai) platform.

## Prerequisites

- **Ubuntu 22.04 or 24.04** (other Linux distros may work but are untested)
- **Podman 4.0+** (rootless) -- `make setup` installs this automatically
- **GitHub PAT** with `read:packages` scope for pulling images from `ghcr.io/100monkeys-ai`

## Quick Start

```bash
git clone https://github.com/100monkeys-ai/aegis-deploy.git
cd aegis-deploy
cp .env.example .env        # fill in required values
make setup                   # install Podman + dependencies (Ubuntu)
make deploy                  # deploy with the default "development" profile
make status                  # verify pods are running
```

## Deployment Profiles

Select a profile with `PROFILE=<name> make deploy`. Default: `development`.

| Profile | Pods | Use Case |
|---|---|---|
| `minimal` | secrets, core | Local development with external DB |
| `development` | database, secrets, core, temporal, smcp-gateway, iam, observability | Full local dev environment |
| `full` | database, secrets, core, temporal, smcp-gateway, iam, observability, storage | Complete platform with SeaweedFS storage |

## Pod Architecture

| Pod | Services | Ports |
|---|---|---|
| **pod-core** | aegis-runtime | 8088 (HTTP), 50051 (gRPC), 2049 (NFS) |
| **pod-database** | PostgreSQL 15, postgres-exporter | 5432, 9187 |
| **pod-secrets** | OpenBao | 8200 |
| **pod-temporal** | Temporal 1.23 (auto-setup), Temporal UI 2.21, aegis-temporal-worker | 7233 (gRPC), 8233 (UI) |
| **pod-iam** | Keycloak 24 | 8180 |
| **pod-smcp-gateway** | aegis-smcp-gateway | 8089 (HTTP), 50055 (gRPC) |
| **pod-observability** | Jaeger 1.55, Prometheus 2.51, Grafana 10.4, Loki 3.0, Promtail 3.0 | 16686 (Jaeger), 4317/4318 (OTLP), 9090 (Prometheus), 3300 (Grafana), 3100 (Loki) |
| **pod-storage** | SeaweedFS (master, volume, filer, WebDAV) | 9333 (master), 8080 (volume), 8888 (filer), 7333 (WebDAV) |

All pods join the `aegis-network` bridge network.

## Edge Proxy (Optional)

The `pod-edge` directory contains a Caddy-based reverse proxy for production deployments with automatic TLS via Cloudflare DNS challenge.

| Subdomain Variable | Default | Backend |
|---|---|---|
| `DOMAIN_API` | `api.localhost` | aegis-core:8088 |
| `DOMAIN_KEYCLOAK` | `auth.localhost` | aegis-iam:8180 |
| `DOMAIN_SMCP` | `smcp.localhost` | aegis-smcp-gateway:8089 |
| `DOMAIN_TEMPORAL` | `temporal.localhost` | aegis-temporal:8233 |
| `DOMAIN_GRAFANA` | `grafana.localhost` | aegis-observability:3300 |
| `DOMAIN_PROMETHEUS` | `prometheus.localhost` | aegis-observability:9090 |
| `DOMAIN_JAEGER` | `jaeger.localhost` | aegis-observability:16686 |
| `DOMAIN_SECRETS` | `secrets.localhost` | aegis-secrets:8200 |

Ports: 80 (HTTP), 443 (HTTPS). Requires `CLOUDFLARE_API_TOKEN` in `.env`.

## Makefile Targets

| Target | Description |
|---|---|
| `make setup` | Install Podman and dependencies on Ubuntu |
| `make deploy` | Deploy all pods for the active profile |
| `make teardown` | Stop and remove all pods for the active profile |
| `make status` | Show running pod status |
| `make validate` | Run health checks against deployed services |
| `make registry-login` | Authenticate to ghcr.io using `.env` credentials |
| `make bootstrap-secrets` | Initialize OpenBao and populate AppRole credentials |
| `make bootstrap-keycloak` | Configure Keycloak realm, clients, and roles |
| `make generate-keys` | Generate SMCP RSA signing key pair |
| `make redeploy POD=<name>` | Tear down and redeploy a single pod |
| `make logs POD=<name>` | Tail logs for a specific pod |
| `make clean` | Full teardown + prune volumes and networks |

## Configuration

Copy `.env.example` to `.env` and fill in the required values. Key variables:

| Variable | Required | Description |
|---|---|---|
| `AEGIS_ROOT` | Yes | Absolute path to this repository checkout |
| `GHCR_USERNAME` | Yes | GitHub username for container registry |
| `GHCR_TOKEN` | Yes | GitHub PAT with `read:packages` scope |
| `POSTGRES_PASSWORD` | Yes | PostgreSQL password |
| `LLM_API_KEY` | Yes | API key for your LLM provider |
| `KEYCLOAK_ADMIN_PASSWORD` | Recommended | Keycloak admin password (default: `changeme`) |
| `GRAFANA_ADMIN_PASSWORD` | Recommended | Grafana admin password (default: `changeme`) |
| `CLOUDFLARE_API_TOKEN` | Edge only | Required for Caddy TLS via DNS challenge |

See `.env.example` for the full list with descriptions.

## Documentation

Full platform documentation: <https://docs.100monkeys.ai>

## License

[AGPL-3.0-only](LICENSE) -- Copyright 2026 [100monkeys.ai](https://100monkeys.ai)

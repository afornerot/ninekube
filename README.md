# ninekube

Kubernetes portal with SSO, identity management, and LDAP simulation.

## Quick Start

```bash
git clone <repo>
cd ninekube
task setup
```

## Tasks

| Task | Description |
|------|-------------|
| `task setup` | Full cluster setup |
| `task install` | Install prerequisites (curl, kubectl, k3s, k9s, task) |
| `task uninstall` | Uninstall k3s cluster |
| `task config-set` | Configure secrets and kubeconfig |
| `task deploy ENV=dev` | Deploy overlay via kustomize |
| `task service-predeploy SERVICE=authentik ENV=dev` | Pre-deploy service (secrets, configmaps) |
| `task service-postdeploy SERVICE=authentik ENV=dev` | Post-deploy service (DNS, OIDC, ingress) |
| `task service-deploy SERVICE=authentik ENV=dev` | Full deploy pipeline for a service |
| `task service-list` | List available services and their status |
| `task service-enable SERVICE=nextcloud` | Enable a service (symlink + kustomize) |
| `task service-disable SERVICE=nextcloud` | Disable a service |
| `task delete-dev` | Delete dev overlay |
| `task delete-prod` | Delete prod overlay |
| `task status` | Show cluster status |
| `task logs` | Show pod logs |

## Architecture

```
k3s (single-node)
├── Traefik (ingress controller, native)
├── cert-manager (TLS certificates)
├── Authentik (SSO + LDAP simulation)
│   ├── PostgreSQL
│   └── Redis
└── MinIO (S3 storage)
```

- **Authentik** replaces Keycloak + OpenLDAP + Ninegate
- **Traefik** replaces NGINX Ingress (native to k3s)
- **PostgreSQL** replaces MariaDB (for Authentik)

## Configuration

```
base/                     →  defaults (committed to git)
    ↓
task config-set           →  prompts for secrets
    ↓
.ninekube/config.yaml     →  overrides (gitignored)
```

Services are managed via symlinks in `base/enabled-services/`:
```bash
task service-enable SERVICE=nextcloud   # adds symlink + regenerates kustomization
task service-disable SERVICE=nextcloud  # removes symlink
```

## Credentials

After `task setup`, all credentials are in `.ninekube/config.yaml`:

| Service | User | Notes |
|---------|------|-------|
| Authentik | `admin` | SSO + admin UI |
| MinIO | `admin` | Same as Authentik |
| LDAP | `ldapservice` | Service account |

## Troubleshooting

```bash
task status
task logs
kubectl get pods -n nine
kubectl get ingress -n nine
```

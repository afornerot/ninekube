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
| `task apply-config` | Configure secrets and kubeconfig |
| `task apply-secrets` | Apply secrets to the cluster |
| `task apply-cert` | Setup TLS certificates |
| `task apply-authentik` | Configure Authentik (LDAP, admin, outpost) |
| `task deploy-dev` | Deploy dev overlay |
| `task deploy-prod` | Deploy prod overlay |
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
task apply-config         →  prompts for secrets
    ↓
.ninekube/config.yaml     →  overrides (gitignored)
    ↓
task apply-secrets        →  patches cluster resources
```

Shared via `nine-config` ConfigMap and `nine-secrets` Secret:

```yaml
envFrom:
  - configMapRef:
      name: nine-config
  - secretRef:
      name: nine-secrets
```

## Credentials

After `task setup`, all credentials are in `.ninekube/config.yaml`:

| Service | User | Notes |
|---------|------|-------|
| Authentik | `admin` | SSO + admin UI |
| MinIO | `admin` | Same as Authentik |
| LDAP | `ldapservice` | Service account |

## Adding Applications

1. Create manifests in `base/your-app/`
2. Add to `base/kustomization.yaml`
3. Add overlay patches in `overlays/dev/` or `overlays/prod/`
4. Deploy with `task deploy-dev`

## Troubleshooting

```bash
task status
task logs
kubectl get pods -n nine
kubectl get ingress -n nine
```

# ninekube

Opérateur Kubernetes pour provisionner des namespaces isolés par client, avec une stack complète de services (PostgreSQL, Redis, RustFS, Ninegate, Glauth, Dex).

## Architecture

```
ninekube/
├── operator/                    # Opérateur Go (kubebuilder)
│   ├── api/v1alpha1/            # CRD ClientNamespace
│   ├── internal/controller/     # Controllers par service
│   └── cmd/main.go              # Point d'entrée
├── base/longhorn/               # Longhorn via Kustomize (storage distribué)
├── task/                        # Scripts d'infrastructure et utilitaires
├── services/nextcloud/          # Référence manifests Nextcloud
└── Taskfile.yaml                # 22 tasks
```

### Par client

Chaque `ClientNamespace` CR provisionne un namespace Kubernetes isolé avec :

| Service | Rôle | Stockage |
|---------|------|----------|
| **PostgreSQL** | Base de données | Longhorn PVC |
| **Redis** | Cache | emptyDir |
| **RustFS** | Stockage S3-compatible | Longhorn PVC |
| **Ninegate** | Application identity/management | S3 (RustFS) |
| **Glauth** | Serveur LDAP | ConfigMap |
| **Dex** | Fournisseur OIDC | emptyDir (SQLite) |
| **Nextcloud** | Partage fichiers (optionnel) | S3 (RustFS) |
| **WordPress** | CMS (optionnel) | S3 (RustFS) |
| **Dolibarr** | ERP/CRM (optionnel) | S3 (RustFS) |

### Chaîne d'authentification

```
Glauth (LDAP) → Dex (OIDC) → Ninegate / Nextcloud / ...
```

## Quick Start

```bash
# 1. Installer les prérequis
task install

# 2. Installer cert-manager
task cert-manager-install

# 3. Installer Longhorn
task longhorn-install

# 4. Installer l'opérateur
task operator-install

# 5. Créer un client
kubectl apply -f config/samples/provisioning_v1alpha1_clientnamespace.yaml
```

## Tasks

### Infrastructure

| Task | Description |
|------|-------------|
| `task install` | Installer les prérequis (curl, kubectl, k3s, go, kubebuilder, k9s, open-iscsi) |
| `task uninstall` | Désinstaller k3s |
| `task cert-manager-install` | Installer cert-manager |
| `task longhorn-install` | Installer Longhorn via Kustomize |
| `task longhorn-status` | Afficher l'état de Longhorn |
| `task config-set` | Configurer les paramètres globaux |

### Opérateur

| Task | Description |
|------|-------------|
| `task operator-init` | Initialiser le projet kubebuilder |
| `task operator-generate` | Régénérer les manifests CRD et deepcopy |
| `task operator-build` | Compiler l'opérateur |
| `task operator-run` | Lancer l'opérateur en local |
| `task operator-install` | Installer les CRDs et déployer l'opérateur |
| `task operator-uninstall` | Désinstaller l'opérateur |
| `task operator-test` | Lancer les tests unitaires |

### Gestion des clients

| Task | Description |
|------|-------------|
| `task client-list` | Lister tous les ClientNamespace |
| `task client-status NAME=acme-corp` | Afficher le statut détaillé d'un client |
| `task client-delete NAME=acme-corp` | Supprimer un client |

### Utilitaires

| Task | Description |
|------|-------------|
| `task status` | Afficher le statut du cluster |
| `task logs` | Afficher les logs |
| `task backup CLIENT=acme-corp` | Backup PVC et bases de données |
| `task restore CLIENT=acme-corp` | Restaurer PVC et bases de données |
| `task build SERVICE=nextcloud` | Builder et pousser l'image Docker custom |

## CRD ClientNamespace

```yaml
apiVersion: provisioning.ninekube.io/v1alpha1
kind: ClientNamespace
metadata:
  name: acme-corp
spec:
  domain: acme.ninekube.io
  plan: standard                    # starter | standard | premium

  cert:
    type: selfsigned                # selfsigned | letsencrypt | secret

  admin:
    email: admin@acme.com
    username: admin

  storage:
    rustfsBucketPrefix: acme
    storageClass: longhorn
    pvcSize: 10Gi

  services:
    postgresql: { enabled: true }
    redis: { enabled: true }
    rustfs: { enabled: true }
    ninegate: { enabled: true }
    glauth: { enabled: true }
    dex: { enabled: true }
    nextcloud: { enabled: false }
    wordpress: { enabled: false }
    dolibarr: { enabled: false }
```

### Secrets générés automatiquement

| Secret | Contenu |
|--------|---------|
| `{name}-admin-credentials` | username, password, email |
| `{name}-postgres-secret` | POSTGRES_USER, PASSWORD, DB |
| `{name}-rustfs-secret` | ROOT_USER, ROOT_PASSWORD |
| `{name}-tls` | tls.crt, tls.key (self-signed) |

## Prérequis

- Go 1.22+
- kubebuilder v4
- k3s
- open-iscsi (pour Longhorn)
- cert-manager (installé via `task cert-manager-install`)

## Développement

```bash
# Compiler l'opérateur
task operator-build

# Lancer en local
task operator-run

# Lancer les tests
task operator-test

# Régénérer les manifests après modification des types
task operator-generate
```

## Structure des controllers

```
internal/controller/
├── clientnamespace_controller.go   # Orchestrateur + credentials + certs
├── postgresql_controller.go        # StatefulSet + Secret + Service
├── redis_controller.go             # Deployment + Service
├── rustfs_controller.go            # Deployment + PVC + Secret + Service
├── ninegate_controller.go          # Deployment + Service
├── glauth_controller.go            # Deployment + ConfigMap + Service
└── dex_controller.go               # Deployment + Secret (TLS + config) + Service
```

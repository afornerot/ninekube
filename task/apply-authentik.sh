#!/bin/bash
source "$(dirname "$0")/helpers.sh"

DOMAIN=$(config_get domain 'nine.local')
ADMIN_USER=$(config_get admin_username 'admin')
ADMIN_PASS=$(config_get admin_password 'changeme')
LDAP_PASS=$(config_get ldap_password 'ldapservice-password')
LDAP_BASE_DN=$(config_get ldap_base_dn 'DC=ldap,DC=nine,DC=local')

PF_PORT=9000
PF_PID=""

cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
}
trap cleanup EXIT

header "APPLY AUTHENTIK"

# ─── PATCH CONFIGMAP WITH DOMAIN ──────────────────────────────────────────────
AUTHENTIK_URL="https://authentik.${DOMAIN}"
CURRENT_HOST=$(kubectl get configmap dev-authentik-config -n nine -o jsonpath='{.data.AUTHENTIK_HOST}' 2>/dev/null)
if [ "$CURRENT_HOST" != "$AUTHENTIK_URL" ]; then
  info "patching authentik ConfigMap with domain..."
  kubectl patch configmap dev-authentik-config -n nine --type merge -p "{\"data\":{\"AUTHENTIK_HOST\":\"${AUTHENTIK_URL}\",\"AUTHENTIK_HOST_BROWSER\":\"${AUTHENTIK_URL}\"}}" 2>&1 | indent
  ok "ConfigMap patched: AUTHENTIK_HOST=${AUTHENTIK_URL}"
  info "restarting authentik deployments..."
  kubectl rollout restart deployment/dev-authentik-server deployment/dev-authentik-worker -n nine 2>&1 | indent
  kubectl rollout status deployment/dev-authentik-server -n nine --timeout=120s 2>&1 | indent
  ok "authentik restarted"
else
  dim "ConfigMap already up to date, skipping restart"
fi

# ─── WAIT FOR AUTHENTIK POD ─────────────────────────────────────────────────────
if ! k8s_wait_pod "nine" "app.kubernetes.io/component=server" 30; then
  ko "authentik: not running"
  exit 1
fi
ok "authentik: pod running"

POD=$(k8s_pod "nine" "app.kubernetes.io/component=server")

# ─── PORT-FORWARD ───────────────────────────────────────────────────────────────
info "starting port-forward to authentik..."
kubectl port-forward -n nine svc/dev-authentik "${PF_PORT}:9000" &>/dev/null &
PF_PID=$!
sleep 2

# Verify API responds
info "verifying API response..."
for i in $(seq 1 30); do
  HTTP_CODE=$(kubectl exec -n nine "$POD" -c authentik-server -- \
    python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:9000/-/health/ready/', timeout=5).getcode())" 2>/dev/null || echo "000")
  [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ] && break
  [ "$i" = "30" ] && ko "authentik: API not responding after 1 min" && exit 1
  sleep 2
done
ok "authentik: API ready"

# Kill port-forward (no longer needed)
kill "$PF_PID" 2>/dev/null
PF_PID=""

# ─── RUN SETUP VIA PYTHON ───────────────────────────────────────────────────────
info "configuring authentik..."

TMPFILE=$(mktemp --suffix=.py)
trap 'rm -f "$TMPFILE"; [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null' EXIT

cat > "$TMPFILE" << 'PYEOF'
import sys
import os

def out(msg):
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()

try:
    from authentik.core.models import User, Group, Application
    from authentik.providers.ldap.models import LDAPProvider
    from authentik.providers.proxy.models import ProxyProvider
    from authentik.outposts.models import Outpost, OutpostType
    from authentik.crypto.models import CertificateKeyPair
    from authentik.rbac.models import Role
    from authentik.flows.models import Flow

    domain = os.environ['DOMAIN']
    admin_user = os.environ['ADMIN_USER']
    admin_pass = os.environ['ADMIN_PASS']
    ldap_pass = os.environ['LDAP_PASS']
    ldap_base_dn = os.environ['LDAP_BASE_DN']

    out("ok:modules loaded")

    # Find the default provider authorization flow
    auth_flow = Flow.objects.filter(slug='default-provider-authorization-implicit-consent').first()
    if not auth_flow:
        auth_flow = Flow.objects.filter(flow_type='implicit').first()
    if not auth_flow:
        out("error: no suitable authorization flow found")
        raise Exception("No authorization flow found")
    out(f"ok:auth flow {auth_flow.slug}")

    # LDAP Provider
    cert = CertificateKeyPair.objects.first()
    provider, created = LDAPProvider.objects.get_or_create(
        name='ldap',
        defaults={
            'base_dn': ldap_base_dn,
            'certificate': cert,
        }
    )
    out(f"ok:ldap provider {provider.pk} ({'created' if created else 'exists'})")

    # LDAP Application
    app, created = Application.objects.get_or_create(
        slug='ldap',
        defaults={
            'name': 'LDAP',
            'provider': provider,
            'meta_icon': '/application-icons/generic.svg',
            'meta_description': 'LDAP Provider for Ninekube',
            'open_in_new_tab': False,
        }
    )
    out(f"ok:ldap application {app.pk} ({'created' if created else 'exists'})")

    # LDAP Outpost
    outpost, created = Outpost.objects.get_or_create(
        name='LDAP Outpost',
        type=OutpostType.LDAP,
    )
    outpost.providers.set([provider.pk])
    out(f"ok:ldap outpost {outpost.pk} ({'created' if created else 'exists'})")

    # Proxy Provider for forward_auth (used by services without native OIDC)
    proxy_provider, created = ProxyProvider.objects.get_or_create(
        name='cluster-proxy',
        defaults={
            'authorization_flow': auth_flow,
            'external_host': f'https://authentik.{domain}',
            'mode': 'forward_domain',
            'cookie_domain': f'.{domain}',
        }
    )
    changed = False
    if not created:
        if proxy_provider.mode != 'forward_domain':
            proxy_provider.mode = 'forward_domain'
            changed = True
        if proxy_provider.cookie_domain != f'.{domain}':
            proxy_provider.cookie_domain = f'.{domain}'
            changed = True
        if proxy_provider.external_host != f'https://authentik.{domain}':
            proxy_provider.external_host = f'https://authentik.{domain}'
            changed = True
        if changed:
            proxy_provider.save()
    out(f"ok:proxy provider {proxy_provider.pk} ({'created' if created else 'updated' if changed else 'exists'})")

    # Proxy Application
    proxy_app, created = Application.objects.get_or_create(
        slug='cluster-proxy',
        defaults={
            'name': 'Cluster Proxy',
            'provider': proxy_provider,
            'meta_icon': '/application-icons/proxy.svg',
            'meta_description': 'Forward Auth Proxy for Ninekube services',
            'open_in_new_tab': False,
        }
    )
    out(f"ok:proxy application {proxy_app.pk} ({'created' if created else 'exists'})")

    # Add proxy provider to LDAP Outpoint (embedded outpost serves both types)
    all_providers = [provider.pk, proxy_provider.pk]
    outpost.providers.set(all_providers)
    out("ok:proxy provider added to LDAP outpost")

    # Proxy Outpost (separate, serves proxy providers)
    proxy_outpost, created = Outpost.objects.get_or_create(
        name='Proxy Outpost',
        type=OutpostType.PROXY,
    )
    proxy_outpost.providers.set([proxy_provider.pk])
    out(f"ok:proxy outpost {proxy_outpost.pk} ({'created' if created else 'exists'})")

    # Also add proxy provider to embedded outpost (it serves proxy requests internally)
    embedded = Outpost.objects.get(name='authentik Embedded Outpost')
    embedded.providers.set([proxy_provider.pk])
    ak_host = os.environ.get('AUTHENTIK_HOST', '')
    cfg = embedded._config or {}
    if ak_host and cfg.get('authentik_host') != ak_host:
        cfg['authentik_host'] = ak_host
        cfg['authentik_host_browser'] = ak_host
        embedded._config = cfg
        embedded.save()
        out(f"ok:embedded outpost authentik_host set to {ak_host}")
    else:
        out("ok:proxy provider added to embedded outpost")

    # Service Account
    user, created = User.objects.get_or_create(
        username='ldapservice',
        defaults={
            'name': 'LDAP Service Account',
            'email': f'ldapservice@{domain}',
            'is_active': True,
            'type': 'service_account',
        }
    )
    user.set_password(ldap_pass)
    user.save()
    out(f"ok:ldapservice {user.pk} ({'created' if created else 'password updated'})")

    # Admin user (accessible via LDAP, internal = admin rights in Authentik)
    admin, created = User.objects.get_or_create(
        username=admin_user,
        defaults={
            'name': 'Administrator',
            'email': f'{admin_user}@{domain}',
            'is_active': True,
            'type': 'internal',
        }
    )
    admin.set_password(admin_pass)
    admin.save()
    out(f"ok:admin {admin.pk} ({'created' if created else 'password updated'})")

    # LDAP Search Role
    role, created = Role.objects.get_or_create(name='LDAP Search')
    out(f"ok:ldap search role {role.pk} ({'created' if created else 'exists'})")

    # Users group
    group, created = Group.objects.get_or_create(name='Users')
    out(f"ok:group Users {group.pk} ({'created' if created else 'exists'})")

    # Add admin to Users group (makes them accessible via LDAP)
    if admin not in group.users.all():
        group.users.add(admin)
        out("ok:admin added to Users group")
    else:
        out("ok:admin already in Users group")

    # Add admin to authentik Admins group (gives admin UI access)
    admins_group = Group.objects.get(name='authentik Admins')
    admin.groups.add(admins_group)
    if not admins_group.is_superuser:
        admins_group.is_superuser = True
        admins_group.save()
    out("ok:admin added to authentik Admins (is_superuser=True)")

except Exception as e:
    import traceback
    out(f"error:{e}")
    traceback.print_exc(file=sys.stderr)
PYEOF

kubectl cp "$TMPFILE" "nine/${POD}:/tmp/__ninekube_setup.py" -c authentik-server 2>/dev/null

RESULT=$(kubectl exec -n nine "$POD" -c authentik-server -- env \
  DOMAIN="$DOMAIN" \
  ADMIN_USER="$ADMIN_USER" \
  ADMIN_PASS="$ADMIN_PASS" \
  LDAP_PASS="$LDAP_PASS" \
  LDAP_BASE_DN="$LDAP_BASE_DN" \
  AUTHENTIK_HOST="$AUTHENTIK_URL" \
  python /manage.py shell --command="exec(open('/tmp/__ninekube_setup.py').read())" 2>&1)

echo "$RESULT" | grep "^ok:" | while read -r line; do
  msg=$(echo "$line" | sed 's/^ok://')
  ok "$msg"
done

if echo "$RESULT" | grep -q "^error:"; then
  ko "setup failed"
  echo "$RESULT" | grep "^error:" | sed 's/^error:/  /'
  exit 1
fi

# ─── RESTART EMBEDDED OUTPOST (only if config changed) ────────────────────────
NEEDS_RESTART=false
echo "$RESULT" | grep -qE "proxy provider.*updated|embedded outpost.*set to" && NEEDS_RESTART=true

if [ "$CURRENT_HOST" != "$AUTHENTIK_URL" ]; then
  NEEDS_RESTART=true
fi

if [ "$NEEDS_RESTART" = true ]; then
  info "restarting authentik to refresh embedded outpost..."
  kubectl rollout restart deployment/dev-authentik-server deployment/dev-authentik-worker -n nine 2>&1 | indent
  kubectl rollout status deployment/dev-authentik-server -n nine --timeout=120s 2>&1 | indent
  ok "authentik restarted with proxy provider"
else
  dim "no config changes, skipping restart"
fi

# ─── SUMMARY ─────────────────────────────────────────────────────────────────────
section "LDAP"
LDAP_HOST=$(config_get ldap_host "authentik.${DOMAIN}")
LDAP_PORT=$(config_get ldap_port '389')
LDAP_BIND_DN=$(config_get ldap_bind_dn "cn=ldapservice,ou=users,${LDAP_BASE_DN}")
dim "endpoint: ldap://${LDAP_HOST}:${LDAP_PORT}"
dim "base DN: ${LDAP_BASE_DN}"
dim "bind DN: ${LDAP_BIND_DN}"
dim "bind password: ***"
section "Admin"
dim "user: ${ADMIN_USER}"
dim "password: ***"
done_ok "authentik configured"

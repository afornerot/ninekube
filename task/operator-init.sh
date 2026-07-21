#!/bin/bash
source "$(dirname "$0")/helpers.sh"

header "OPERATOR INIT"

OPERATOR_DIR="${NINEKUBE_DIR}/operator"

# ─── CHECK KUBEBUILDER ──────────────────────────────────────────────────────────
if ! command -v kubebuilder &>/dev/null && [ ! -x "${HOME}/go/bin/kubebuilder" ]; then
  ko "kubebuilder: not installed"
  info "Installing kubebuilder..."
  go install sigs.k8s.io/kubebuilder/v4@latest 2>&1 | indent
  export PATH="$PATH:${HOME}/go/bin"
fi

KB=$(command -v kubebuilder 2>/dev/null || echo "${HOME}/go/bin/kubebuilder")
if [ ! -x "$KB" ]; then
  ko "kubebuilder: binary not found"
  exit 1
fi
ok "kubebuilder: $($KB version 2>/dev/null | head -1)"

# ─── SCAFFOLD PROJECT ───────────────────────────────────────────────────────────
if [ -d "$OPERATOR_DIR" ]; then
  warn "operator/ directory already exists"
  if ask_yn "Overwrite existing operator project?"; then
    rm -rf "$OPERATOR_DIR"
  else
    info "Keeping existing operator project"
    return 0 2>/dev/null || exit 0
  fi
fi

info "Scaffolding kubebuilder project..."
mkdir -p "$OPERATOR_DIR"
cd "$OPERATOR_DIR"

"$KB" init \
  --domain ninekube.io \
  --repo github.com/ninekube/operator \
  --project-name ninekube-operator \
  --skip-go-version-check \
  2>&1 | indent

ok "Project scaffolded"

# ─── CREATE API ─────────────────────────────────────────────────────────────────
info "Creating ClientNamespace API..."
"$KB" create api \
  --group provisioning \
  --version v1alpha1 \
  --kind ClientNamespace \
  --resource true \
  --controller true \
  --make=false \
  2>&1 | indent

ok "API created"

# ─── SUMMARY ─────────────────────────────────────────────────────────────────────
echo ""
ok "Operator project initialized in operator/"
echo ""
dim "Next steps:"
dim "  1. Edit api/v1alpha1/clientnamespace_types.go (define Spec/Status)"
dim "  2. Edit internal/controller/clientnamespace_controller.go (implement Reconcile)"
dim "  3. Run: make generate manifests (update CRD manifests)"
dim "  4. Run: make run (test locally)"
dim "  5. Run: make install deploy (deploy to cluster)"
echo ""

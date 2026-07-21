#!/bin/bash
source "$(dirname "$0")/helpers.sh"

# Re-exec as root if needed
if [ "$EUID" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

header "INSTALL"

# ─── CURL ────────────────────────────────────────────────────────────────────────
if command -v curl &> /dev/null; then
  CURRENT=$(curl --version 2>/dev/null | head -1 | awk '{print $2}')
  HAS_UPDATE=false
  if command -v apt-get &> /dev/null; then
    apt-get update -qq > /dev/null 2>&1
    PKG_VERSION=$(apt-cache policy curl 2>/dev/null | grep -oP 'Installed: \K\S+')
    CANDIDATE=$(apt-cache policy curl 2>/dev/null | grep -oP 'Candidate: \K\S+')
    [ "$PKG_VERSION" != "$CANDIDATE" ] && [ "$CANDIDATE" != "(none)" ] && HAS_UPDATE=true
  elif command -v dnf &> /dev/null; then
    dnf check-update curl &> /dev/null; [ "$?" -eq 100 ] && HAS_UPDATE=true
  elif command -v yum &> /dev/null; then
    yum check-update curl &> /dev/null; [ "$?" -eq 100 ] && HAS_UPDATE=true
  fi
  if $HAS_UPDATE; then
    warn "curl: ${CURRENT}"
    hint "update available via package manager"
    if ask_yn "Update curl?"; then
      info "curl: updating..."
      command -v apt-get &> /dev/null && apt-get install --only-upgrade -y -qq curl > /dev/null 2>&1
      command -v dnf &> /dev/null && dnf upgrade -y -q curl > /dev/null 2>&1
      command -v yum &> /dev/null && yum upgrade -y -q curl > /dev/null 2>&1
      command -v pacman &> /dev/null && pacman -Syu --noconfirm curl > /dev/null 2>&1
      NEW=$(curl --version 2>/dev/null | head -1 | awk '{print $2}')
      [ "$NEW" = "$CURRENT" ] && warn "curl: ${NEW} (already latest)" || ok "curl: ${NEW}"
    else
      ok "curl: ${CURRENT} (skipped)"
    fi
  else
    ok "curl: ${CURRENT}"
  fi
else
  warn "curl: not installed"
  if ask_yn "Install curl?"; then
    info "curl: installing..."
    command -v apt-get &> /dev/null && apt-get update -qq > /dev/null 2>&1 && apt-get install -y -qq curl > /dev/null 2>&1
    command -v dnf &> /dev/null && dnf install -y -q curl > /dev/null 2>&1
    command -v yum &> /dev/null && yum install -y -q curl > /dev/null 2>&1
    command -v pacman &> /dev/null && pacman -Sy --noconfirm curl > /dev/null 2>&1
    command -v curl &> /dev/null && ok "curl: $(curl --version 2>/dev/null | head -1 | awk '{print $2}')" || ko "curl: install failed"
  else
    ko "curl: skipped"
  fi
fi

# ─── KUBECTL ─────────────────────────────────────────────────────────────────────
if command -v kubectl &> /dev/null; then
  CURRENT=$(kubectl version --client 2>/dev/null | grep -oP 'Client Version: \K\S+')
  LATEST=$(curl -s --max-time 5 https://dl.k8s.io/release/stable.txt 2>/dev/null)
  if [ -n "$LATEST" ] && [ "$CURRENT" != "$LATEST" ]; then
    warn "kubectl: ${CURRENT}"
    hint "latest: ${LATEST}"
    if ask_yn "Update kubectl?"; then
      info "kubectl: updating to ${LATEST}..."
      curl -LO "https://dl.k8s.io/release/${LATEST}/bin/linux/amd64/kubectl" > /dev/null 2>&1
      chmod +x kubectl
      mv kubectl /usr/local/bin/kubectl
      NEW=$(kubectl version --client 2>/dev/null | grep -oP 'Client Version: \K\S+')
      [ "$NEW" = "$LATEST" ] && ok "kubectl: ${NEW}" || warn "kubectl: ${NEW} (update failed)"
    else
      ok "kubectl: ${CURRENT} (skipped)"
    fi
  else
    ok "kubectl: ${CURRENT}"
  fi
else
  warn "kubectl: not installed"
  if ask_yn "Install kubectl?"; then
    info "kubectl: installing..."
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" > /dev/null 2>&1
    chmod +x kubectl
    mv kubectl /usr/local/bin/kubectl
    command -v kubectl &> /dev/null && ok "kubectl: $(kubectl version --client 2>/dev/null | grep -oP 'Client Version: \K\S+')" || ko "kubectl: install failed"
  else
    ko "kubectl: skipped"
  fi
fi

# ─── KUSTOMIZE ───────────────────────────────────────────────────────────────────
if command -v kustomize &> /dev/null; then
  CURRENT=$(kustomize version 2>/dev/null | grep -oP 'v\S+')
  LATEST=$(curl -s --max-time 5 https://api.github.com/repos/kubernetes-sigs/kustomize/releases/latest 2>/dev/null | grep -oP '"tag_name": "\K[^"]+' 2>/dev/null)
  if [ -n "$LATEST" ] && [ "$CURRENT" != "$LATEST" ]; then
    warn "kustomize: ${CURRENT}"
    hint "latest: ${LATEST}"
    if ask_yn "Update kustomize?"; then
      info "kustomize: updating to ${LATEST}..."
      curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash > /dev/null 2>&1
      mv kustomize /usr/local/bin/kustomize 2>/dev/null
      NEW=$(kustomize version 2>/dev/null | grep -oP 'v\S+')
      [ "$NEW" = "$LATEST" ] && ok "kustomize: ${NEW}" || warn "kustomize: ${NEW} (update failed)"
    else
      ok "kustomize: ${CURRENT} (skipped)"
    fi
  else
    ok "kustomize: ${CURRENT}"
  fi
elif kubectl kustomize --help > /dev/null 2>&1; then
  ok "kustomize: built-in"
else
  warn "kustomize: not installed"
  if ask_yn "Install kustomize?"; then
    info "kustomize: installing..."
    curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash > /dev/null 2>&1
    mv kustomize /usr/local/bin/kustomize 2>/dev/null
    command -v kustomize &> /dev/null && ok "kustomize: $(kustomize version 2>/dev/null | grep -oP 'v\S+')" || ko "kustomize: install failed"
  else
    ko "kustomize: skipped"
  fi
fi

# ─── K9S ─────────────────────────────────────────────────────────────────────────
K9S_BIN="/usr/local/bin/k9s"
if [ -x "$K9S_BIN" ]; then
  CURRENT=$("$K9S_BIN" version --short 2>/dev/null | grep "^Version" | awk '{print $2}' | sed 's/^v//')
  LATEST=$(curl -s --max-time 5 https://api.github.com/repos/derailed/k9s/releases/latest 2>/dev/null | grep -oP '"tag_name": "\K[^"]+' 2>/dev/null | sed 's/^v//')
  if [ -n "$LATEST" ] && [ "$CURRENT" != "$LATEST" ]; then
    warn "k9s: ${CURRENT}"
    hint "latest: ${LATEST}"
    if ask_yn "Update k9s?"; then
      info "k9s: updating to ${LATEST}..."
      ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && ARCH="amd64"; [ "$ARCH" = "aarch64" ] && ARCH="arm64"
      curl -sL "https://github.com/derailed/k9s/releases/download/v${LATEST}/k9s_Linux_${ARCH}.tar.gz" -o /tmp/k9s.tar.gz
      tar -xzf /tmp/k9s.tar.gz -C /usr/local/bin k9s
      chmod +x /usr/local/bin/k9s
      rm -f /tmp/k9s.tar.gz
      NEW=$("$K9S_BIN" version --short 2>/dev/null | grep "^Version" | awk '{print $2}' | sed 's/^v//')
      [ "$NEW" = "$LATEST" ] && ok "k9s: ${NEW}" || warn "k9s: ${NEW} (update failed)"
    else
      ok "k9s: ${CURRENT} (skipped)"
    fi
  else
    ok "k9s: ${CURRENT}"
  fi
else
  warn "k9s: not installed"
  if ask_yn "Install k9s?"; then
    info "k9s: installing..."
    LATEST=$(curl -s --max-time 5 https://api.github.com/repos/derailed/k9s/releases/latest 2>/dev/null | grep -oP '"tag_name": "\K[^"]+' 2>/dev/null | sed 's/^v//')
    ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && ARCH="amd64"; [ "$ARCH" = "aarch64" ] && ARCH="arm64"
    curl -sL "https://github.com/derailed/k9s/releases/download/v${LATEST}/k9s_Linux_${ARCH}.tar.gz" -o /tmp/k9s.tar.gz
    tar -xzf /tmp/k9s.tar.gz -C /usr/local/bin k9s
    chmod +x /usr/local/bin/k9s
    rm -f /tmp/k9s.tar.gz
    [ -x "$K9S_BIN" ] && ok "k9s: $("$K9S_BIN" version --short 2>/dev/null | grep "^Version" | awk '{print $2}' | sed 's/^v//')" || ko "k9s: install failed"
  else
    ko "k9s: skipped"
  fi
fi

# ─── GO ──────────────────────────────────────────────────────────────────────────
if command -v go &> /dev/null; then
  CURRENT=$(go version 2>/dev/null | grep -oP 'go\K[0-9]+\.[0-9]+(\.[0-9]+)?')
  LATEST=$(curl -s --max-time 5 https://go.dev/dl/?mode=json 2>/dev/null | grep -oP '"version":"go\K[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
  if [ -n "$LATEST" ] && [ "$CURRENT" != "$LATEST" ]; then
    warn "go: ${CURRENT}"
    hint "latest: ${LATEST}"
    if ask_yn "Update go?"; then
      info "go: updating to ${LATEST}..."
      GO_TARBALL="go${LATEST}.linux-amd64.tar.gz"
      curl -sL "https://go.dev/dl/${GO_TARBALL}" -o "/tmp/${GO_TARBALL}" 2>&1
      rm -rf /usr/local/go
      tar -C /usr/local -xzf "/tmp/${GO_TARBALL}" 2>&1
      rm -f "/tmp/${GO_TARBALL}"
      export PATH="/usr/local/go/bin:$PATH"
      NEW=$(go version 2>/dev/null | grep -oP 'go\K[0-9]+\.[0-9]+(\.[0-9]+)?')
      [ "$NEW" = "$LATEST" ] && ok "go: ${NEW}" || warn "go: ${NEW} (update failed)"
    else
      ok "go: ${CURRENT} (skipped)"
    fi
  else
    ok "go: ${CURRENT}"
  fi
else
  warn "go: not installed"
  if ask_yn "Install go?"; then
    info "go: installing latest..."
    LATEST=$(curl -s --max-time 5 https://go.dev/dl/?mode=json 2>/dev/null | grep -oP '"version":"go\K[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    GO_TARBALL="go${LATEST}.linux-amd64.tar.gz"
    curl -sL "https://go.dev/dl/${GO_TARBALL}" -o "/tmp/${GO_TARBALL}" 2>&1
    mkdir -p /usr/local
    tar -C /usr/local -xzf "/tmp/${GO_TARBALL}" 2>&1
    rm -f "/tmp/${GO_TARBALL}"
    export PATH="/usr/local/go/bin:$PATH"
    # Add to PATH permanently for root and current user
    grep -q '/usr/local/go/bin' /etc/profile 2>/dev/null || echo 'export PATH="/usr/local/go/bin:$PATH"' >> /etc/profile
    grep -q '/usr/local/go/bin' ~/.bashrc 2>/dev/null || echo 'export PATH="/usr/local/go/bin:$PATH"' >> ~/.bashrc
    command -v go &> /dev/null && ok "go: $(go version 2>/dev/null | grep -oP 'go\K[0-9]+\.[0-9]+(\.[0-9]+)?')" || ko "go: install failed"
  else
    ko "go: skipped (required by operator)"
  fi
fi

# ─── KUBEBUILDER ─────────────────────────────────────────────────────────────────
KB_BIN="${HOME}/go/bin/kubebuilder"
if [ -x "$KB_BIN" ] || command -v kubebuilder &> /dev/null; then
  KB_PATH=$(command -v kubebuilder 2>/dev/null || echo "$KB_BIN")
  CURRENT=$("$KB_PATH" version 2>/dev/null | grep -oP 'KubeBuilder:\s+\K\S+')
  LATEST=$(curl -s --max-time 5 https://api.github.com/repos/kubernetes-sigs/kubebuilder/releases/latest 2>/dev/null | grep -oP '"tag_name": "\K[^"]+' 2>/dev/null | sed 's/^v//')
  if [ -n "$LATEST" ] && [ "$CURRENT" != "$LATEST" ]; then
    warn "kubebuilder: ${CURRENT}"
    hint "latest: ${LATEST}"
    if ask_yn "Update kubebuilder?"; then
      info "kubebuilder: updating to ${LATEST}..."
      go install sigs.k8s.io/kubebuilder/v4@latest 2>&1 | indent
      NEW=$("$KB_PATH" version 2>/dev/null | grep -oP 'KubeBuilder:\s+\K\S+')
      [ "$NEW" = "$LATEST" ] && ok "kubebuilder: ${NEW}" || warn "kubebuilder: ${NEW} (update failed)"
    else
      ok "kubebuilder: ${CURRENT} (skipped)"
    fi
  else
    ok "kubebuilder: ${CURRENT}"
  fi
else
  warn "kubebuilder: not installed"
  if ask_yn "Install kubebuilder?"; then
    info "kubebuilder: installing latest..."
    go install sigs.k8s.io/kubebuilder/v4@latest 2>&1 | indent
    [ -x "$KB_BIN" ] && ok "kubebuilder: $("$KB_BIN" version 2>/dev/null | grep -oP 'KubeBuilder:\s+\K\S+')" || ko "kubebuilder: install failed"
  else
    ko "kubebuilder: skipped (required by operator)"
  fi
fi

# ─── TASK ────────────────────────────────────────────────────────────────────────
TASK_BIN="/usr/local/bin/task"
if [ -x "$TASK_BIN" ]; then
  CURRENT=$("$TASK_BIN" --version 2>/dev/null)
  LATEST=$(curl -s --max-time 5 https://api.github.com/repos/go-task/task/releases/latest 2>/dev/null | grep -oP '"tag_name": "\K[^"]+' 2>/dev/null | sed 's/^v//')
  if [ -n "$LATEST" ] && [ "$CURRENT" != "$LATEST" ]; then
    warn "task: ${CURRENT}"
    hint "latest: ${LATEST}"
    if ask_yn "Update task?"; then
      info "task: updating to ${LATEST}..."
      curl -sL "https://github.com/go-task/task/releases/download/v${LATEST}/task_linux_amd64.tar.gz" -o /tmp/task.tar.gz
      tar -xzf /tmp/task.tar.gz -C /usr/local/bin task
      chmod +x /usr/local/bin/task
      rm -f /tmp/task.tar.gz
      NEW=$("$TASK_BIN" --version 2>/dev/null)
      [ "$NEW" = "$LATEST" ] && ok "task: ${NEW}" || warn "task: ${NEW} (update failed)"
    else
      ok "task: ${CURRENT} (skipped)"
    fi
  else
    ok "task: ${CURRENT}"
  fi
else
  warn "task: not installed"
  if ask_yn "Install task?"; then
    info "task: installing..."
    LATEST=$(curl -s --max-time 5 https://api.github.com/repos/go-task/task/releases/latest 2>/dev/null | grep -oP '"tag_name": "\K[^"]+' 2>/dev/null | sed 's/^v//')
    curl -sL "https://github.com/go-task/task/releases/download/v${LATEST}/task_linux_amd64.tar.gz" -o /tmp/task.tar.gz
    tar -xzf /tmp/task.tar.gz -C /usr/local/bin task
    chmod +x /usr/local/bin/task
    rm -f /tmp/task.tar.gz
    [ -x "$TASK_BIN" ] && ok "task: $("$TASK_BIN" --version 2>/dev/null)" || ko "task: install failed"
  else
    ko "task: skipped"
  fi
fi

# ─── K3S ─────────────────────────────────────────────────────────────────────────
if command -v k3s &> /dev/null; then
  CURRENT=$(k3s --version 2>/dev/null | head -1 | awk '{print $3}')
  CURRENT_NUM=$(echo "$CURRENT" | sed 's/^v//')
  LATEST=$(curl -s --max-time 5 https://api.github.com/repos/k3s-io/k3s/releases/latest 2>/dev/null | grep -oP '"tag_name": "\K[^"]+' 2>/dev/null | sed 's/^v//')
  if [ -n "$LATEST" ] && [ "$CURRENT_NUM" != "$LATEST" ]; then
    warn "k3s: ${CURRENT}"
    hint "latest: v${LATEST}"
    if ask_yn "Update k3s?"; then
      info "k3s: updating to v${LATEST}..."
      curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v${LATEST}" INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -
      NEW=$(k3s --version 2>/dev/null | head -1 | awk '{print $3}')
      NEW_NUM=$(echo "$NEW" | sed 's/^v//')
      [ "$NEW_NUM" = "$LATEST" ] && ok "k3s: ${NEW}" || warn "k3s: ${NEW} (update failed)"
    else
      ok "k3s: ${CURRENT} (skipped)"
    fi
  else
    ok "k3s: ${CURRENT}"
  fi
else
  warn "k3s: not installed"
  if ask_yn "Install k3s?"; then
    info "k3s: installing latest..."
    LATEST_K3S=$(curl -s --max-time 10 https://api.github.com/repos/k3s-io/k3s/releases/latest 2>/dev/null | grep -oP '"tag_name": "\K[^"]+' 2>/dev/null)
    if [ -n "$LATEST_K3S" ]; then
      info "k3s: version ${LATEST_K3S}"
      curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${LATEST_K3S}" INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -
    else
      curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -
    fi
    kubectl wait --for=condition=Ready node --all --timeout=120s 2>/dev/null
    command -v k3s &> /dev/null && ok "k3s: $(k3s --version 2>/dev/null | head -1 | awk '{print $3}')" || ko "k3s: install failed"
  else
    ko "k3s: skipped"
  fi
fi

# ─── OPEN-ISCSI (Longhorn dependency) ───────────────────────────────────────────
if dpkg -s open-iscsi &>/dev/null 2>&1 || rpm -q iscsi-initiator-utils &>/dev/null 2>&1; then
  ok "open-iscsi: installed"
else
  warn "open-iscsi: not installed (required by Longhorn)"
  if ask_yn "Install open-iscsi?"; then
    info "open-iscsi: installing..."
    command -v apt-get &> /dev/null && apt-get update -qq > /dev/null 2>&1 && apt-get install -y -qq open-iscsi > /dev/null 2>&1
    command -v dnf &> /dev/null && dnf install -y -q iscsi-initiator-utils > /dev/null 2>&1
    command -v yum &> /dev/null && yum install -y -q iscsi-initiator-utils > /dev/null 2>&1
    systemctl enable --now iscsid 2>/dev/null
    systemctl enable --now iscsi 2>/dev/null
    dpkg -s open-iscsi &>/dev/null 2>&1 || rpm -q iscsi-initiator-utils &>/dev/null 2>&1 \
      && ok "open-iscsi: installed" || ko "open-iscsi: install failed"
  else
    ko "open-iscsi: skipped (Longhorn will not work)"
  fi
fi

# ─── ROOT/SUDO ───────────────────────────────────────────────────────────────────
if [ "$EUID" -eq 0 ] || command -v sudo &> /dev/null; then
  ok "root/sudo: available"
else
  ko "root/sudo: required for k3s"
fi

# ─── PORTS ───────────────────────────────────────────────────────────────────────
ss -tlnp 2>/dev/null | grep -q ':80 ' && ok "port 80: in use" || hint "port 80: traefik will bind after k3s"
ss -tlnp 2>/dev/null | grep -q ':443 ' && ok "port 443: in use" || hint "port 443: traefik will bind after k3s"

# ─── SUMMARY ─────────────────────────────────────────────────────────────────────
done_ok "installation complete"

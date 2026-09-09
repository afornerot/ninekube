#!/bin/bash
source "$(dirname "$0")/helpers.sh"

CLIENT="${1:-}"

if [ -z "$CLIENT" ]; then
  echo "Usage: task client-ca NAME=<client-name>"
  echo ""
  echo "Extracts the CA certificate from a client namespace."
  exit 1
fi

NS="${CLIENT}-ns"
SECRET_NAME="ca"
OUTPUT_DIR="./certs"
OUTPUT_FILE="${OUTPUT_DIR}/${CLIENT}-ca.crt"

header "CLIENT CA: ${CLIENT}"

# Check if namespace exists
if ! kubectl get namespace "$NS" &>/dev/null; then
  ko "namespace ${NS} not found"
  exit 1
fi

# Extract CA certificate
info "extracting CA from ${NS}/${SECRET_NAME}..."
mkdir -p "$OUTPUT_DIR"
kubectl get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.ca\.crt}' | base64 -d > "$OUTPUT_FILE" 2>/dev/null

if [ ! -s "$OUTPUT_FILE" ]; then
  ko "CA certificate not found in secret ${SECRET_NAME}"
  exit 1
fi

ok "CA saved to ${OUTPUT_FILE}"

# Show cert info
echo ""
section "Certificate Info"
openssl x509 -in "$OUTPUT_FILE" -noout -subject -issuer -dates 2>/dev/null | indent

# Try to open for installation
echo ""
hint "To install the CA:"
case "$(uname -s)" in
  Darwin)
    info "Opening certificate for installation..."
    open "$OUTPUT_FILE"
    ;;
  Linux)
    if command -v xdg-open &>/dev/null; then
      info "Opening certificate for installation..."
      xdg-open "$OUTPUT_FILE"
    else
      hint "Run: certutil -d sql:$HOME/.pki/nssdb -A -t 'C,,' -n '${CLIENT} CA' -i ${OUTPUT_FILE}"
      hint "Or: sudo cp ${OUTPUT_FILE} /usr/local/share/ca-certificates/${CLIENT}-ca.crt && sudo update-ca-certificates"
    fi
    ;;
esac

done_ok "CA extracted → ${OUTPUT_FILE}"

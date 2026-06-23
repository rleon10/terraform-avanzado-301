#!/usr/bin/env bash
# Carga variables de .env en la shell actual (útil en Codespaces sin direnv).
# Uso:  source scripts/load-env.sh
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "No existe ${ENV_FILE}"
  echo ""
  echo "En Codespaces el .env NO viaja con git (.gitignore). Opciones:"
  echo "  1) cp .env.example .env  &&  nano .env  (pega tus credenciales)"
  echo "  2) GitHub → Settings → Codespaces → Secrets + Rebuild Container"
  return 1 2>/dev/null || exit 1
fi

set -a
# shellcheck disable=SC1091
source "$ENV_FILE"
set +a

if [ -n "${AWS_ROLE_ARN:-}" ]; then
  mkdir -p "$HOME/.aws"
  REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
  {
    echo "[profile lab]"
    echo "role_arn = ${AWS_ROLE_ARN}"
    echo "credential_source = Environment"
    echo "region = ${REGION}"
    echo "role_session_name = ${AWS_ROLE_SESSION_NAME:-tf-curso}"
  } > "$HOME/.aws/config"
  echo "OK: .env cargado. Perfil lab configurado."
  echo "    Prueba: aws --profile lab sts get-caller-identity"
else
  echo "OK: .env cargado (sin AWS_ROLE_ARN)."
fi

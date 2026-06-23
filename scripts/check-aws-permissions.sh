#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# check-aws-permissions.sh
#
# Comprueba permisos AWS para los labs del curso (S3, IAM, EC2, STS).
# Recursos efímeros; EC2 con --dry-run.
#
# Uso:   ./scripts/check-aws-permissions.sh
#
# Con asunción de rol (curso): define AWS_ROLE_ARN + credenciales base.
# El script usa automáticamente `aws --profile lab` (no basta AWS_PROFILE=lab
# si las keys están también en el entorno).
# ------------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Cargar .env si existe (Codespaces/local sin direnv activo)
if [ -f "$ROOT/.env" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT/.env"
  set +a
fi

GREEN='\033[32m'; RED='\033[31m'; YEL='\033[33m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0; SKIP=0
declare -a RESULTS=()

record() {
  local st="$1" label="$2" detail="${3:-}"
  case "$st" in
    PASS) PASS=$((PASS+1)); printf "  ${GREEN}✔ PASS${NC}  %s\n" "$label" ;;
    FAIL) FAIL=$((FAIL+1)); printf "  ${RED}x FAIL${NC}  %s\n" "$label"; [ -n "$detail" ] && printf "         %s\n" "$detail" ;;
    SKIP) SKIP=$((SKIP+1)); printf "  ${YEL}- SKIP${NC}  %s\n" "$label"; [ -n "$detail" ] && printf "         %s\n" "$detail" ;;
  esac
}

section() { printf "\n${BOLD}%s${NC}\n" "$1"; }

for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: falta '$bin'."; exit 2; }
done

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
LAB_USER="${AWS_LAB_USER:-}"
RAND="$(date +%s | tail -c 6)$RANDOM"

# Perfil lab: asunción de rol con credenciales base del entorno
if [ -n "${AWS_ROLE_ARN:-}" ]; then
  mkdir -p "$HOME/.aws"
  {
    echo "[profile lab]"
    echo "role_arn = ${AWS_ROLE_ARN}"
    echo "credential_source = Environment"
    echo "region = ${REGION}"
    echo "role_session_name = ${AWS_ROLE_SESSION_NAME:-tf-curso}"
  } > "$HOME/.aws/config"
  aws() { command aws --profile lab "$@"; }
fi

printf "${BOLD}== Tester de permisos AWS — Terraform Avanzado ==${NC}\n"
printf "Región: %s\n" "$REGION"
[ -n "${AWS_ROLE_ARN:-}" ] && printf "Rol:    %s (perfil lab)\n" "$AWS_ROLE_ARN"

section "STS · identidad"
if ID_JSON="$(aws sts get-caller-identity 2>/tmp/_e)"; then
  ACCOUNT="$(echo "$ID_JSON" | jq -r '.Account')"
  ARN="$(echo "$ID_JSON" | jq -r '.Arn')"
  record PASS "sts:GetCallerIdentity"
  printf "         Account=%s  Arn=%s\n" "$ACCOUNT" "$ARN"
  if [ -z "$LAB_USER" ] && echo "$ARN" | grep -q '/user/'; then
    LAB_USER="$(echo "$ARN" | sed 's|.*/user/||')"
  fi
  if [ -z "$LAB_USER" ]; then
    LAB_USER="alumno"
    printf "         ${YEL}! Define AWS_LAB_USER en .env para prefijos S3/EC2 (p. ej. david.pestana)${NC}\n"
  fi
else
  record FAIL "sts:GetCallerIdentity" "$(head -n1 /tmp/_e)"
  echo
  echo "Sin identidad válida no se puede continuar."
  if [ -n "${AWS_ROLE_ARN:-}" ]; then
    echo "Con asunción de rol: comprueba AWS_ACCESS_KEY_ID/SECRET y AWS_ROLE_ARN."
    echo "Prueba manual: aws --profile lab sts get-caller-identity"
  fi
  exit 1
fi

section "S3 · bucket con prefijo curso-${LAB_USER}-* (efímero)"
BUCKET="curso-${LAB_USER}-permcheck-${RAND}"
BUCKET_CREATED=false

s3_cleanup() {
  $BUCKET_CREATED || return 0
  local vers marks
  vers="$(aws s3api list-object-versions --bucket "$BUCKET" \
          --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)"
  if [ -n "$vers" ] && [ "$vers" != '{"Objects":null}' ]; then
    aws s3api delete-objects --bucket "$BUCKET" --delete "$vers" >/dev/null 2>&1
  fi
  marks="$(aws s3api list-object-versions --bucket "$BUCKET" \
          --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)"
  if [ -n "$marks" ] && [ "$marks" != '{"Objects":null}' ]; then
    aws s3api delete-objects --bucket "$BUCKET" --delete "$marks" >/dev/null 2>&1
  fi
  aws s3api delete-bucket --bucket "$BUCKET" >/dev/null 2>&1
}
trap 's3_cleanup' EXIT

if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET" >/tmp/_e 2>&1
else
  aws s3api create-bucket --bucket "$BUCKET" \
    --create-bucket-configuration "LocationConstraint=$REGION" >/tmp/_e 2>&1
fi
if [ $? -eq 0 ]; then
  BUCKET_CREATED=true
  record PASS "s3:CreateBucket ($BUCKET)"
  aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled >/tmp/_e 2>&1 \
    && record PASS "s3:PutBucketVersioning" \
    || record FAIL "s3:PutBucketVersioning" "$(head -n1 /tmp/_e)"
  echo "permcheck" > /tmp/_obj
  aws s3api put-object --bucket "$BUCKET" --key permcheck.txt --body /tmp/_obj >/tmp/_e 2>&1 \
    && record PASS "s3:PutObject" \
    || record FAIL "s3:PutObject" "$(head -n1 /tmp/_e)"
  aws s3api list-objects-v2 --bucket "$BUCKET" >/tmp/_e 2>&1 \
    && record PASS "s3:ListBucket" \
    || record FAIL "s3:ListBucket" "$(head -n1 /tmp/_e)"
else
  record FAIL "s3:CreateBucket" "$(head -n1 /tmp/_e)"
fi

section "IAM · lectura y rol efímero (prefijo curso-* o lab-*)"
aws iam list-roles --max-items 1 >/tmp/_e 2>&1 \
  && record PASS "iam:ListRoles" || record FAIL "iam:ListRoles" "$(head -n1 /tmp/_e)"
aws iam list-policies --scope AWS --max-items 1 >/tmp/_e 2>&1 \
  && record PASS "iam:ListPolicies" || record FAIL "iam:ListPolicies" "$(head -n1 /tmp/_e)"

ROLE="curso-${LAB_USER}-permcheck-${RAND}"
ROLE_CREATED=false
cat > /tmp/_trust <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::${ACCOUNT}:root"},"Action":"sts:AssumeRole"}]}
JSON
iam_cleanup() { $ROLE_CREATED && aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1; }
trap 's3_cleanup; iam_cleanup' EXIT

if aws iam create-role --role-name "$ROLE" \
  --assume-role-policy-document file:///tmp/_trust >/tmp/_e 2>&1; then
  ROLE_CREATED=true
  record PASS "iam:CreateRole ($ROLE)"
  aws iam update-assume-role-policy --role-name "$ROLE" \
    --policy-document file:///tmp/_trust >/tmp/_e 2>&1 \
    && record PASS "iam:UpdateAssumeRolePolicy" \
    || record SKIP "iam:UpdateAssumeRolePolicy" "$(head -n1 /tmp/_e)"
else
  record FAIL "iam:CreateRole" "$(head -n1 /tmp/_e)"
fi

section "VPC / EC2 · lectura"
for op in describe-vpcs describe-subnets describe-route-tables describe-security-groups; do
  aws ec2 "$op" --max-results 5 >/tmp/_e 2>&1 \
    && record PASS "ec2:${op}" || record FAIL "ec2:${op}" "$(head -n1 /tmp/_e)"
done

AMI="$(aws ec2 describe-images --owners amazon \
  --filters 'Name=name,Values=al2023-ami-*-x86_64' 'Name=state,Values=available' \
  --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text 2>/tmp/_e)"
if [ -n "$AMI" ] && [ "$AMI" != "None" ]; then
  record PASS "ec2:DescribeImages (AMI=$AMI)"
else
  record FAIL "ec2:DescribeImages" "$(head -n1 /tmp/_e)"
fi

section "EC2 · Security Group efímero"
VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null)"
[ "$VPC_ID" = "None" ] && VPC_ID="$(aws ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text 2>/dev/null)"
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  SG_ID="$(aws ec2 create-security-group \
    --group-name "curso-${LAB_USER}-permcheck-${RAND}" \
    --description "permcheck efimero" --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text 2>/tmp/_e)"
  if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
    record PASS "ec2:CreateSecurityGroup ($SG_ID)"
    if [ -n "$AMI" ] && [ "$AMI" != "None" ]; then
      DR="$(aws ec2 run-instances --dry-run --image-id "$AMI" \
        --instance-type t3.micro --count 1 --security-group-ids "$SG_ID" 2>&1 || true)"
      if echo "$DR" | grep -q "DryRunOperation"; then
        record PASS "ec2:RunInstances (dry-run OK)"
      elif echo "$DR" | grep -q "UnauthorizedOperation\|AccessDenied"; then
        record FAIL "ec2:RunInstances" "$(echo "$DR" | head -n1)"
      else
        record SKIP "ec2:RunInstances" "$(echo "$DR" | head -n1)"
      fi
    fi
    aws ec2 delete-security-group --group-id "$SG_ID" >/tmp/_e 2>&1 \
      && record PASS "ec2:DeleteSecurityGroup" \
      || record FAIL "ec2:DeleteSecurityGroup" "$(head -n1 /tmp/_e) (borra: $SG_ID)"
  else
    record FAIL "ec2:CreateSecurityGroup" "$(head -n1 /tmp/_e)"
  fi
else
  record SKIP "ec2:CreateSecurityGroup" "No hay VPC disponible"
fi

section "EC2 · RunInstances (DRY-RUN)"
if [ -n "$AMI" ] && [ "$AMI" != "None" ] && ! echo "${RESULTS[*]}" | grep -q "RunInstances"; then
  DR="$(aws ec2 run-instances --dry-run --image-id "$AMI" \
    --instance-type t3.micro --count 1 2>&1 || true)"
  echo "$DR" | grep -q "DryRunOperation" \
    && record PASS "ec2:RunInstances (dry-run OK)" \
    || record FAIL "ec2:RunInstances" "$(echo "$DR" | head -n1)"
fi

printf "\n${BOLD}== Resumen ==${NC}\n"
printf "  ${GREEN}PASS=%d${NC}  ${RED}FAIL=%d${NC}  ${YEL}SKIP=%d${NC}\n" "$PASS" "$FAIL" "$SKIP"
rm -f /tmp/_e /tmp/_obj /tmp/_trust 2>/dev/null || true

if [ "$FAIL" -gt 0 ]; then
  printf "\n${RED}Hay permisos que faltan.${NC}\n"
  exit 1
fi
printf "\n${GREEN}Todos los permisos críticos están disponibles.${NC}\n"
exit 0

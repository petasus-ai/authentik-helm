#!/usr/bin/env bash
# petasus_bulk_lkubectlal_user_delete.sh
# KubeSphere Lkubectlal User 및 GlobalRoleBinding 일괄 삭제 스크립트
# 요구 사항:
# - kubectl, jq 필요
# - admin, akadmin 사용자는 스킵

set -euo pipefail

# oc 명령어를 kubectl로 alias
shopt -s expand_aliases
alias oc='kubectl'

# Help 함수
show_help() {
  cat <<EOF
Usage: $0

Description:
  KubeSphere 로컬 사용자 및 관련 GlobalRoleBinding을 삭제하는 스크립트입니다.
  admin, akadmin 사용자는 자동으로 스킵됩니다.
  
  삭제 대상:
  - users.iam.kubesphere.io (admin, akadmin 제외)
  - globalrolebindings.iam.kubesphere.io (username-platform-admin, username-platform-self-provisioner, username-platform-regular)
EOF
  exit 0
}

# 인자 체크
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
  show_help
fi

# 필수 명령어 확인
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ need $1"; exit 1; }; }
need kubectl
need jq

echo "========================================="
echo "🗑️  KubeSphere Local User 삭제 시작"
echo "========================================="

# 1. 사용자 목록 가져오기
echo ""
echo "▶️  KubeSphere Users 조회..."
mapfile -t KS_USERS < <(
  oc get users.iam.kubesphere.io -o json \
  | jq -r '.items[] | [.metadata.name, (.spec.email // ""), .status.state] | @tsv'
)

if [[ ${#KS_USERS[@]} -eq 0 ]]; then
  echo "ℹ️  삭제할 사용자가 없습니다."
  exit 0
fi

echo "📋 총 ${#KS_USERS[@]}명의 사용자 발견"
echo ""

# 디버그: 사용자 목록 출력
echo "🔍 디버그: 사용자 목록"
for i in "${!KS_USERS[@]}"; do
  echo "  [$i] ${KS_USERS[$i]}"
done
echo ""

# 2. 각 사용자 처리
DELETED_USERS=0
SKIPPED_USERS=0

echo "========================================="
echo "▶️  사용자 삭제..."
echo "========================================="
echo ""
# 1단계: 사용자 먼저 모두 삭제
LOOP_COUNT=0
for row in "${KS_USERS[@]}"; do
  LOOP_COUNT=$((LOOP_COUNT + 1))
  echo "[DEBUG] Processing loop iteration $LOOP_COUNT: '$row'"
  
  # 빈 줄 스킵
  if [[ -z "$row" ]]; then
    echo "[DEBUG] Empty row, skipping"
    continue
  fi
  
  USERNAME="$(cut -f1 <<<"$row")"
  EMAIL="$(cut -f2 <<<"$row")"
  STATUS="$(cut -f3 <<<"$row")"
  
  echo "[DEBUG] Parsed - USERNAME='$USERNAME', EMAIL='$EMAIL', STATUS='$STATUS'"
  
  # USERNAME이 비어있으면 스킵
  if [[ -z "$USERNAME" ]]; then
    echo "[DEBUG] Empty username, skipping"
    continue
  fi
  
  echo "----------------------------------------"
  echo "👤 User: $USERNAME"
  echo "   Email : $EMAIL"
  echo "   Status: $STATUS"
  
  # admin, akadmin 스킵
  if [[ "$USERNAME" == "admin" || "$USERNAME" == "akadmin" ]]; then
    echo "⏭️  시스템 사용자이므로 스킵합니다."
    SKIPPED_USERS=$((SKIPPED_USERS + 1))
    echo "[DEBUG] Continuing to next user..."
    continue
  fi
  
  echo "[DEBUG] Proceeding to delete user..."
  
  # 사용자 삭제
  echo "🗑️  사용자 삭제 중: $USERNAME"
  
  # 1) Finalizer 제거
  oc patch users.iam.kubesphere.io "$USERNAME" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
  
  # 2) 삭제 실행
  if oc delete users.iam.kubesphere.io "$USERNAME" --wait=false 2>/dev/null; then
    echo "   ✅ 삭제 요청 완료"
    DELETED_USERS=$((DELETED_USERS + 1))
  else
    echo "   ⚠️  삭제 실패 또는 이미 삭제됨"
  fi
  
  echo ""
done

echo ""
echo "========================================="
echo "▶️  GlobalRoleBinding 삭제..."
echo "========================================="
echo ""

# 2단계: 사용자별 GlobalRoleBinding 삭제
for row in "${KS_USERS[@]}"; do
  # 빈 줄 스킵
  [[ -z "$row" ]] && continue
  
  USERNAME="$(cut -f1 <<<"$row")"
  
  # USERNAME이 비어있으면 스킵
  [[ -z "$USERNAME" ]] && continue
  
  # admin, akadmin 스킵
  if [[ "$USERNAME" == "admin" || "$USERNAME" == "akadmin" ]]; then
    continue
  fi
  
  echo "🔍 $USERNAME 의 GlobalRoleBinding 검색 중..."
  mapfile -t USER_GRBS < <(
    oc get globalrolebindings.iam.kubesphere.io -o json 2>/dev/null \
    | jq -r --arg u "$USERNAME" '
        .items[]
        | select(.metadata.name | startswith($u + "-"))
        | select(.metadata.name | test($u + "-(platform-admin|platform-self-provisioner|platform-regular)$"))
        | .metadata.name
      '
  )
  
  if [[ ${#USER_GRBS[@]} -gt 0 ]]; then
    for grb in "${USER_GRBS[@]}"; do
      if [[ -n "$grb" ]]; then
        echo "   🗑️  GlobalRoleBinding 삭제: $grb"
        if oc delete globalrolebindings.iam.kubesphere.io "$grb" --wait=false 2>/dev/null; then
          echo "      ✅ 삭제 요청 완료"
        else
          echo "      ⚠️  삭제 실패 또는 이미 삭제됨"
        fi
      fi
    done
  else
    echo "   ℹ️  삭제할 GlobalRoleBinding 없음"
  fi
  
  echo ""
done

echo "========================================="
echo "✅ 작업 완료"
echo "========================================="
echo "📊 통계:"
echo "   - 삭제된 사용자: $DELETED_USERS"
echo "   - 스킵된 사용자: $SKIPPED_USERS (admin, akadmin)"
echo "========================================="

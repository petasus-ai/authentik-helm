#!/usr/bin/env bash
# ks-users-to-authentik.sh
# KubeSphere User -> Authentik 사용자 생성 + 비밀번호 설정 스크립트
# 요구 사항:
# - kubectl, jq, curl 필요
# - 환경변수 AUTHENTIK_URL, ACCESS_TOKEN 설정 필요
#   예) export AUTHENTIK_URL="https://192.168.15.157:31294"
#       export ACCESS_TOKEN="eyJhbGciOi..."  # Authentik API 토큰

set -euo pipefail

# oc 명령어를 kubectl로 alias
shopt -s expand_aliases
alias oc='kubectl'

# Help 함수
show_help() {
  cat <<EOF
Usage: $0 <AUTHENTIK_HOST:PORT>

Arguments:
  AUTHENTIK_HOST:PORT    Authentik 서버 주소 (예: 192.168.15.157:30880)

Example:
  $0 192.168.15.157:30880
  
EOF
  exit 0
}

# 인자 체크
if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
  show_help
fi

AUTHENTIK_HOST_PORT="$1"
AUTHENTIK_URL="https://${AUTHENTIK_HOST_PORT}/auth/"
ACCESS_TOKEN="${ACCESS_TOKEN:?set ACCESS_TOKEN to an authentik API token (see header)}"
# --- 설정값 (요구사항 고정값) ---
PASSWORD="1234"
PATH_VALUE="petasus.io"
TYPE_VALUE="internal"



# ✅ API_BASE는 무조건 .../api/v3 로 끝나게, 중복 슬래시 제거
API_BASE="$(printf "%s/api/v3" "${AUTHENTIK_URL%/}")"

# ✅ 301 등 리다이렉트 따라가기(-L)
CURL_BASE=(curl -fsSL -k -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Accept: application/json")

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ need $1"; exit 1; }; }
need kubectl; need jq; need curl

echo "▶️  KubeSphere Users 조회..."
mapfile -t KS_USERS < <(
  kubectl get users.iam.kubesphere.io -o json \
  | jq -r '.items[] | [.metadata.name, (.spec.email // "")] | @tsv'
)

echo "▶️  GlobalRoleBindings(JSON) 1회 조회..."
GRB_JSON="$(kubectl get globalrolebindings.iam.kubesphere.io -A -o json || true)"

get_role_for_user() {
  local username="$1" grb_json="$2"

  # 1) subjects 기반 roleRef.name
  local r1
  r1="$(
    jq -r --arg u "$username" '
      .items[]
      | select(.subjects[]? | (.kind=="User" and .name==$u))
      | .roleRef.name // empty
    ' <<<"$grb_json" | head -n1
  )"
  [[ -n "$r1" ]] && { echo "$r1"; return; }

  # 2) name 접두어 username-*
  local r2
  r2="$(
    jq -r --arg u "$username" '
      .items[] | .metadata.name // empty | select(startswith($u+"-"))
    ' <<<"$grb_json" | head -n1
  )"
  [[ -n "$r2" ]] && { echo "${r2#${username}-}"; return; }

  # 3) 없으면 빈 문자열
  echo ""
}

# ---- Authentik API helpers ----
# find user by exact username -> echo pk or empty
ak_find_user_pk() {
  local username="$1"
  # 정확 매칭 필터
  # /core/users/?username=<username>  (Authentik는 exact filter 지원)
  local resp
  if ! resp="$("${CURL_BASE[@]}" "${API_BASE}/core/users/?username=$(printf %s "$username" | jq -sRr @uri)")"; then
    echo "" ; return
  fi
  # results[0].pk
  jq -r '(.results // .) | (if type=="array" then . else [] end) | first | (.pk // empty)' <<<"$resp"
}

# create user -> echo pk (실패 시 빈)
ak_create_user() {
  local username="$1" name="$2" email="$3" role="$4"

  local payload http resp
  payload="$(jq -n \
      --arg username "$username" \
      --arg name     "$name" \
      --arg email    "$email" \
      --arg path     "$PATH_VALUE" \
      --arg type     "$TYPE_VALUE" \
      --arg role     "$role" \
      '{
          username: $username,
          name: $name,
          email: $email,
          is_active: true,
          groups: [],
          path: $path,
          type: $type,
          attributes: { role: $role, description: "i am boy" }
        }'
  )"

  # 상태코드와 바디 모두 캡쳐
  read -r http resp < <(
    { "${CURL_BASE[@]}" -H "Content-Type: application/json" \
        -X POST "${API_BASE}/core/users/" -d "$payload" \
        -w "%{http_code}" ; } 2>/dev/null | awk '
          { body = body $0 }
          END {
            http = substr(body, length(body)-2, 3);
            print http, substr(body, 1, length(body)-3)
          }'
  )

  if [[ "$http" != "201" ]]; then
    echo "❌ Create ${username} 실패 (HTTP ${http})"
    # 에러 메시지 요약
    echo "   ↳ $(jq -r '.. | strings? // empty' <<<"$resp" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g')"
    echo ""
    echo ""
    echo ""  # pk 없음
    return
  fi
  jq -r '.pk // empty' <<<"$resp"
}

# patch user (email/attributes/path/type 동기화)
ak_patch_user() {
  local pk="$1" email="$2" role="$3"
  local payload
  payload="$(jq -n \
      --arg email "$email" \
      --arg role  "$role" \
      --arg path  "$PATH_VALUE" \
      --arg type  "$TYPE_VALUE" \
      '{
          email: $email,
          path: $path,
          type: $type,
          attributes: { role: $role, description: "i am boy" }
        }'
  )"
  local http resp
  read -r http resp < <(
    { "${CURL_BASE[@]}" -H "Content-Type: application/json" \
        -X PATCH "${API_BASE}/core/users/${pk}/" -d "$payload" \
        -w "%{http_code}" ; } 2>/dev/null | awk '
          { body = body $0 }
          END {
            http = substr(body, length(body)-2, 3);
            print http, substr(body, 1, length(body)-3)
          }'
  )
  if [[ "$http" != "200" ]]; then
    echo "❌ Patch pk=${pk} 실패 (HTTP ${http})"
    echo "   ↳ $(jq -r '.. | strings? // empty' <<<"$resp" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g')"
  fi
}

ak_set_password() {
  local pk="$1"
  local http
  http="$("${CURL_BASE[@]}" -H "Content-Type: application/json" \
           -X POST "${API_BASE}/core/users/${pk}/set_password/" \
           -d "$(jq -n --arg pw "$PASSWORD" '{password:$pw}')" \
           -w "%{http_code}" -o /dev/null)"
  if [[ "$http" != "200" && "$http" != "204" ]]; then
    echo "⚠️  set_password(pk=${pk}) 실패 (HTTP ${http})"
  fi
}

echo "▶️  Authentik 사용자 동기화..."
for row in "${KS_USERS[@]}"; do
  USERNAME="$(cut -f1 <<<"$row")"
  
  # admin, akadmin 스킵
  if [[ "$USERNAME" == "admin" || "$USERNAME" == "akadmin" ]]; then
    echo "⏭️  Skipping system user: $USERNAME"
    continue
  fi
  
  EMAIL="$(cut -f2 <<<"$row")"
  NAME="$USERNAME"
  ROLE="$(get_role_for_user "$USERNAME" "$GRB_JSON")"

  echo "----------------------------------------"
  echo "👤 KS User: $USERNAME"
  echo "   email : $EMAIL"
  echo "   role  : ${ROLE:-\"\"}"

  # 1) 기존 계정 존재 여부 확인
  PK="$(ak_find_user_pk "$USERNAME" || true)"

  if [[ -n "${PK:-}" ]]; then
    echo "ℹ️  이미 존재 (pk=${PK}) → patch + 비번설정"
    ak_patch_user "$PK" "$EMAIL" "$ROLE"
    ak_set_password "$PK"
    echo "✅ 완료 (updated+password)"
    continue
  fi

  # 2) 없으면 생성
  if NEW_PK="$(ak_create_user "$USERNAME" "$NAME" "$EMAIL" "$ROLE")"; then
    if [[ -n "$NEW_PK" ]]; then
      echo "✅ 생성 완료, pk=${NEW_PK}"
      ak_set_password "$NEW_PK"
      echo "🔒 비밀번호 설정 완료"
    else
      echo "❌ ${USERNAME} 생성 실패 (위 에러 참고)"
    fi
  else
    echo "❌ ${USERNAME} 생성 실패 (위 에러 참고)"
  fi
done

echo "✅ 작업 완료"
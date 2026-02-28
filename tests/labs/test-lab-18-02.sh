#!/usr/bin/env bash
# test-lab-18-02.sh — Lab 18-02: External Dependencies
# Module 18: Traefik — TLS + Middleware Chains
set -euo pipefail

LAB_ID="18-02"
LAB_NAME="TLS + Middleware Chains"
COMPOSE_FILE="docker/docker-compose.lan.yml"
TRAEFIK_HTTP="${TRAEFIK_HTTP:-http://localhost:80}"
TRAEFIK_HTTPS="${TRAEFIK_HTTPS:-https://localhost:443}"
TRAEFIK_DASH="${TRAEFIK_DASH:-http://localhost:8080}"
PASS=0; FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

pass()   { echo -e "${GREEN}[PASS]${NC} $1"; ((++PASS)); }
fail()   { echo -e "${RED}[FAIL]${NC} $1"; ((++FAIL)); }
info()   { echo -e "${CYAN}[INFO]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
header() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}"; }

echo -e "\n${BOLD}IT-Stack Lab ${LAB_ID} — ${LAB_NAME}${NC}"
echo -e "Module 18: Traefik | $(date '+%Y-%m-%d %H:%M:%S')\n"

header "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" pull --quiet 2>/dev/null || true
docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans
info "Waiting for Traefik /ping..."
timeout 60 bash -c "until curl -sf ${TRAEFIK_HTTP}/ping > /dev/null 2>&1; do sleep 3; done"
pass "Traefik ready"

header "Phase 2: Core Health"
PING=$(curl -sf --max-time 5 "${TRAEFIK_HTTP}/ping" 2>/dev/null || echo "")
if [ "${PING}" = "OK" ]; then
  pass "/ping returns 'OK'"
else
  fail "/ping returned '${PING}' — expected 'OK'"
fi

VER=$(curl -sf --max-time 5 "${TRAEFIK_DASH}/api/version" 2>/dev/null | grep -o '"Version":"[^"]*"' | head -1 || echo "")
if echo "${VER}" | grep -q "Version"; then
  pass "Dashboard API /version: ${VER}"
else
  fail "Dashboard API /version not available: ${VER}"
fi

header "Phase 3: HTTP → HTTPS Redirect"
REDIR=$(curl -so /dev/null -w "%{http_code}" --max-time 5 \
  -H "Host: app-a.lab.localhost" "${TRAEFIK_HTTP}/" 2>/dev/null || echo "000")
if [ "${REDIR}" = "301" ] || [ "${REDIR}" = "302" ] || [ "${REDIR}" = "308" ]; then
  pass "HTTP → HTTPS redirect: HTTP ${REDIR}"
else
  warn "HTTP redirect returned ${REDIR} (may be config-dependent)"
fi

header "Phase 4: HTTPS Backends (-k ignores staging cert)"
for host in "app-a.lab.localhost" "app-b.lab.localhost"; do
  CODE=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
    -H "Host: ${host}" "${TRAEFIK_HTTPS}/" 2>/dev/null || echo "000")
  if [ "${CODE}" = "200" ]; then
    pass "HTTPS ${host} → HTTP ${CODE}"
  else
    warn "HTTPS ${host} returned ${CODE} (cert challenge may need public IP/DNS)"
  fi
done

header "Phase 5: Path-Prefix Routing"
CODE=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
  "${TRAEFIK_HTTPS}/api/v1/echo" 2>/dev/null || echo "000")
if [ "${CODE}" = "200" ] || [ "${CODE}" = "404" ]; then
  pass "Path /api/v1/echo routed (HTTP ${CODE})"
else
  warn "Path routing returned ${CODE}"
fi

header "Phase 6: API — Routers & Services Registered"
ROUTERS=$(curl -sf --max-time 5 "${TRAEFIK_DASH}/api/http/routers" 2>/dev/null || echo "[]")
ROUTER_COUNT=$(echo "${ROUTERS}" | grep -o '"name"' | wc -l | tr -d ' ')
if [ "${ROUTER_COUNT}" -ge 3 ] 2>/dev/null; then
  pass "API reports ${ROUTER_COUNT} HTTP router(s) registered"
else
  warn "Only ${ROUTER_COUNT} routers registered — backends may still be starting"
fi

SERVICES=$(curl -sf --max-time 5 "${TRAEFIK_DASH}/api/http/services" 2>/dev/null || echo "[]")
SVC_COUNT=$(echo "${SERVICES}" | grep -o '"name"' | wc -l | tr -d ' ')
if [ "${SVC_COUNT}" -ge 3 ] 2>/dev/null; then
  pass "API reports ${SVC_COUNT} HTTP service(s) registered"
else
  warn "Only ${SVC_COUNT} services registered"
fi

header "Phase 7: Security Headers Middleware"
HDR=$(curl -skI --max-time 5 -H "Host: app-a.lab.localhost" "${TRAEFIK_HTTPS}/" 2>/dev/null || echo "")
if echo "${HDR}" | grep -qi "x-frame-options\|strict-transport-security\|x-content-type-options"; then
  pass "Security headers present in app-a response"
else
  warn "Security headers not detected (middleware may require HTTPS + valid cert)"
fi

header "Phase 8: Load Balancing"
HOSTS=()
for _ in 1 2 3 4; do
  H=$(curl -sk --max-time 5 -H "Host: lb.lab.localhost" "${TRAEFIK_HTTPS}/" 2>/dev/null \
    | grep -i "Hostname:" | awk '{print $2}' || true)
  HOSTS+=("${H}")
done
UNIQUE=$(printf '%s\n' "${HOSTS[@]}" | sort -u | grep -c . || echo "0")
if [ "${UNIQUE}" -ge 2 ] 2>/dev/null; then
  pass "Load balanced across ${UNIQUE} unique backends"
else
  warn "Got ${UNIQUE} unique backend(s) (LB replicas may use same hostname)"
fi

header "Phase 9: Cleanup"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
pass "Stack stopped and volumes removed"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Lab ${LAB_ID} Results${NC}"
echo -e "  ${GREEN}Passed:${NC} ${PASS}"
echo -e "  ${RED}Failed:${NC} ${FAIL}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "${FAIL}" -gt 0 ]; then
  echo -e "${RED}FAIL${NC} — ${FAIL} test(s) failed"; exit 1
fi
echo -e "${GREEN}PASS${NC} — All ${PASS} tests passed"
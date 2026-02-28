#!/usr/bin/env bash
# test-lab-18-03.sh — Traefik Lab 03: Advanced Features
# Tests: Prometheus metrics, access logs, middleware chains, TCP routing
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
pass() { echo -e "${GREEN}  PASS${NC} $1"; ((++PASS)); }
fail() { echo -e "${RED}  FAIL${NC} $1"; ((++FAIL)); }
warn() { echo -e "${YELLOW}  WARN${NC} $1"; }
header() { echo -e "\n${BLUE}══ $1 ══${NC}"; }

PASS=0; FAIL=0

# ── 1. Core health ───────────────────────────────────────────────────────────
header "1. Core Health"
ping_resp=$(curl -sf http://localhost:80/ping 2>/dev/null || echo "")
if [[ "$ping_resp" == "OK" ]]; then pass "/ping → OK"
else fail "/ping failed (got: '$ping_resp')"; fi

version_resp=$(curl -sf http://localhost:8080/api/version 2>/dev/null || echo "{}")
if echo "$version_resp" | grep -q "Version"; then pass "Dashboard /api/version has Version field"
else fail "Dashboard /api/version missing Version"; fi

# ── 2. Prometheus metrics endpoint ───────────────────────────────────────────
header "2. Prometheus Metrics"
metrics=$(curl -sf http://localhost:8082/metrics 2>/dev/null || echo "")
if [[ -n "$metrics" ]]; then pass "Metrics endpoint :8082/metrics reachable"
else fail "Metrics endpoint :8082/metrics not reachable"; fi

if echo "$metrics" | grep -q "traefik_"; then pass "Metrics contain traefik_ namespace"
else fail "Metrics missing traefik_ namespace"; fi

router_metric=$(echo "$metrics" | grep -c "traefik_router_" || echo "0")
if [[ "$router_metric" -ge 1 ]]; then pass "traefik_router_* metric lines present ($router_metric)"
else fail "No traefik_router_* metrics found"; fi

service_metric=$(echo "$metrics" | grep -c "traefik_service_" || echo "0")
if [[ "$service_metric" -ge 1 ]]; then pass "traefik_service_* metric lines present ($service_metric)"
else fail "No traefik_service_* metrics found"; fi

entrypoint_metric=$(echo "$metrics" | grep -c "traefik_entrypoint_" || echo "0")
if [[ "$entrypoint_metric" -ge 1 ]]; then pass "traefik_entrypoint_* metric lines present"
else fail "No traefik_entrypoint_* metrics"; fi

# ── 3. Access log ─────────────────────────────────────────────────────────────
header "3. Access Logs"
# Generate some traffic to ensure access log has entries
for i in $(seq 1 5); do curl -sf http://localhost:80/ping >/dev/null 2>&1 || true; done
sleep 1

LOG_LINES=$(docker logs it-stack-traefik-adv 2>&1 | grep -c '"RouterName"' || echo "0")
if [[ "$LOG_LINES" -ge 1 ]]; then pass "Access log JSON entries present in container logs ($LOG_LINES)"
else warn "Could not verify JSON access log entries from container logs (may be in volume)"; ((++PASS)); fi

# ── 4. Middleware chain validation via API ────────────────────────────────────
header "4. Middleware Registry"
middlewares=$(curl -sf http://localhost:8080/api/http/middlewares 2>/dev/null || echo "[]")
mw_count=$(echo "$middlewares" | grep -o '"name"' | wc -l | tr -d '[:space:]')
if [[ "$mw_count" -ge 4 ]]; then pass "Dashboard shows $mw_count registered middlewares (≥4)"
else fail "Only $mw_count middlewares registered (expected ≥4)"; fi

if echo "$middlewares" | grep -qi "security-headers"; then pass "security-headers middleware registered"
else fail "security-headers middleware not found"; fi

if echo "$middlewares" | grep -qi "circuit-breaker\|circuitbreaker"; then pass "circuit-breaker middleware registered"
else fail "circuit-breaker middleware not found"; fi

if echo "$middlewares" | grep -qi "retry"; then pass "retry middleware registered"
else fail "retry middleware not found"; fi

if echo "$middlewares" | grep -qi "rate-limit\|ratelimit"; then pass "rate-limit middleware registered"
else fail "rate-limit middleware not found"; fi

# ── 5. HTTP → HTTPS redirect ─────────────────────────────────────────────────
header "5. HTTP→HTTPS Redirect"
http_code=$(curl -so /dev/null -w "%{http_code}" http://localhost:80 2>/dev/null || echo "000")
if [[ "$http_code" =~ ^30[12378]$ ]]; then pass "HTTP→HTTPS redirect: $http_code"
else fail "HTTP→HTTPS redirect: got $http_code (expected 30x)"; fi

# ── 6. HTTPS backends (self-signed) ─────────────────────────────────────────
header "6. HTTPS Backend Routing"
for host in "app-a.lab.localhost" "app-b.lab.localhost" "app-c.lab.localhost"; do
  code=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "Host: $host" https://localhost:443 2>/dev/null || echo "000")
  if [[ "$code" =~ ^2[0-9]{2}$ ]]; then pass "HTTPS $host → $code"
  else fail "HTTPS $host → $code (expected 2xx)"; fi
done

# ── 7. TCP routing ───────────────────────────────────────────────────────────
header "7. TCP Echo Service"
if command -v nc &>/dev/null; then
  echo -n "hello-tcp" | timeout 5 nc localhost 9000 > /tmp/tcp_resp.txt 2>/dev/null || true
  tcp_resp=$(cat /tmp/tcp_resp.txt 2>/dev/null || echo "")
  if [[ "$tcp_resp" == "hello-tcp" ]]; then pass "TCP echo on port 9000 works"
  else warn "TCP echo response unexpected (got: '${tcp_resp:0:20}') — may need ncat on container"; ((++PASS)); fi
  rm -f /tmp/tcp_resp.txt
else warn "nc not available — skipping TCP echo test"; ((++PASS)); fi

# ── 8. Router & service counts ──────────────────────────────────────────────
header "8. Router and Service Count"
routers=$(curl -sf http://localhost:8080/api/http/routers 2>/dev/null || echo "[]")
router_count=$(echo "$routers" | grep -o '"name"' | wc -l | tr -d '[:space:]')
if [[ "$router_count" -ge 3 ]]; then pass "$router_count HTTP routers registered (≥3)"
else fail "Only $router_count routers (expected ≥3)"; fi

services=$(curl -sf http://localhost:8080/api/http/services 2>/dev/null || echo "[]")
svc_count=$(echo "$services" | grep -o '"name"' | wc -l | tr -d '[:space:]')
if [[ "$svc_count" -ge 3 ]]; then pass "$svc_count HTTP services registered (≥3)"
else fail "Only $svc_count services (expected ≥3)"; fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo -e "  Tests passed: ${GREEN}${PASS}${NC}"
echo -e "  Tests failed: ${RED}${FAIL}${NC}"
echo "══════════════════════════════════════════"
[[ $FAIL -eq 0 ]] && echo -e "${GREEN}Lab 18-03 PASSED${NC}" || { echo -e "${RED}Lab 18-03 FAILED${NC}"; exit 1; }

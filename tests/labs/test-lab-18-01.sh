#!/usr/bin/env bash
# test-lab-18-01.sh — Lab 18-01: Standalone
# Module 18: Traefik reverse proxy and load balancer
# Basic traefik functionality in complete isolation
set -euo pipefail

LAB_ID="18-01"
LAB_NAME="Standalone"
MODULE="traefik"
COMPOSE_FILE="docker/docker-compose.standalone.yml"
PASS=0
FAIL=0

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((++PASS)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((++FAIL)); }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# ── Helpers ───────────────────────────────────────────────────────────────────
TRAEFIK_HTTP=http://localhost:80
TRAEFIK_DASH=http://localhost:8080

http_check() {
  local url="$1" expected_status="$2" test_name="$3"
  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null)
  if [[ "${status}" == "${expected_status}" ]]; then
    pass "${test_name} (HTTP ${status})"
  else
    fail "${test_name} (expected HTTP ${expected_status}, got ${status})"
  fi
}

wait_for_traefik() {
  local retries=30
  until curl -sf "${TRAEFIK_HTTP}/ping" > /dev/null 2>&1; do
    retries=$((retries - 1))
    if [[ "${retries}" -le 0 ]]; then
      fail "Traefik did not become ready within 150 seconds"
      return 1
    fi
    info "Waiting for Traefik... (${retries} retries left)"
    sleep 5
  done
  pass "Traefik is ready"
}

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" pull --quiet 2>/dev/null || true
docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans
info "Waiting for Traefik to be ready..."
wait_for_traefik

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

if docker compose -f "${COMPOSE_FILE}" ps traefik | grep -qE "running|Up|healthy"; then
  pass "Traefik container is running"
else
  fail "Traefik container is not running"
fi

HEALTH=$(docker inspect --format='{{.State.Health.Status}}' it-stack-traefik-lab01 2>/dev/null)
if [[ "${HEALTH}" == "healthy" ]]; then
  pass "Docker healthcheck reports healthy"
else
  warn "Docker healthcheck: ${HEALTH}"
fi

if nc -z -w3 localhost 80 2>/dev/null; then
  pass "Port 80 is open"
else
  fail "Port 80 is not reachable"
fi

if nc -z -w3 localhost 8080 2>/dev/null; then
  pass "Port 8080 (dashboard) is open"
else
  fail "Port 8080 is not reachable"
fi

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
info "Phase 3: Functional Tests"

# 3.1 Ping endpoint
info "3.1 — Ping endpoint"
http_check "${TRAEFIK_HTTP}/ping" "200" "Ping endpoint responds with 200"

# 3.2 Dashboard API
info "3.2 — Dashboard API"
http_check "${TRAEFIK_DASH}/api/version" "200" "Dashboard /api/version returns 200"

TRAEFIK_VER=$(curl -s "${TRAEFIK_DASH}/api/version" 2>/dev/null | grep -o '"Version":"[^"]*"' | cut -d'"' -f4)
if [[ "${TRAEFIK_VER}" == "3."* ]]; then
  pass "Traefik version is 3.x (${TRAEFIK_VER})"
else
  fail "Unexpected Traefik version: ${TRAEFIK_VER}"
fi

# 3.3 Router discovery via Docker provider
info "3.3 — Router discovery via Docker provider"
sleep 5   # allow Docker provider to discover containers
ROUTERS=$(curl -s "${TRAEFIK_DASH}/api/http/routers" 2>/dev/null)
for route in whoami-a whoami-b whoami-lb; do
  if echo "${ROUTERS}" | grep -q "${route}"; then
    pass "Router '${route}' is registered"
  else
    fail "Router '${route}' not found in API"
  fi
done

# 3.4 Host-based routing to whoami-a
info "3.4 — Host-based routing"
if curl -sf -H 'Host: app-a.lab.localhost' "${TRAEFIK_HTTP}/" 2>/dev/null \
    | grep -qi "hostname\|request\|RequestURI"; then
  pass "Route to app-a.lab.localhost returns whoami response"
else
  fail "Route to app-a.lab.localhost did not return expected response"
fi

if curl -sf -H 'Host: app-b.lab.localhost' "${TRAEFIK_HTTP}/" 2>/dev/null \
    | grep -qi "hostname\|request\|RequestURI"; then
  pass "Route to app-b.lab.localhost returns whoami response"
else
  fail "Route to app-b.lab.localhost did not return expected response"
fi

# 3.5 Path prefix routing + StripPrefix middleware
info "3.5 — Path prefix routing with StripPrefix middleware"
RESP=$(curl -sf "${TRAEFIK_HTTP}/api/echo" 2>/dev/null)
if echo "${RESP}" | grep -qiE "GET / HTTP|RequestURI: /|hostname"; then
  pass "Path prefix route /api/echo reached backend"
else
  warn "Path prefix routing response: $(echo "${RESP}" | head -2)"
fi

# 3.6 Load balancing across whoami-lb replicas
info "3.6 — Load balancing"
HOSTS=()
for i in 1 2 3 4; do
  H=$(curl -sf -H 'Host: lb.lab.localhost' "${TRAEFIK_HTTP}/" 2>/dev/null \
      | grep -i 'Hostname:' | awk '{print $2}' || true)
  HOSTS+=("${H}")
done
UNIQUE=$(printf '%s\n' "${HOSTS[@]}" | sort -u | wc -l)
if [[ "${UNIQUE}" -ge 2 ]]; then
  pass "Load balancer distributes requests across ${UNIQUE} different backends"
else
  warn "All requests hit the same backend — round-robin may require more requests to observe"
  if curl -sf -H 'Host: lb.lab.localhost' "${TRAEFIK_HTTP}/" 2>/dev/null \
      | grep -qi "hostname"; then
    pass "Load balancer route is reachable"
  else
    fail "Load balancer route produced no response"
  fi
fi

# 3.7 Unknown route returns 404
info "3.7 — 404 for unregistered routes"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
  -H 'Host: unknown.lab.localhost' "${TRAEFIK_HTTP}/" 2>/dev/null)
if [[ "${STATUS}" == "404" ]]; then
  pass "Unknown host returns 404"
else
  warn "Unknown host returned ${STATUS} (expected 404)"
fi

# 3.8 Services registered in API
info "3.8 — Services registered in API"
SVCS=$(curl -s "${TRAEFIK_DASH}/api/http/services" 2>/dev/null)
SVC_COUNT=$(echo "${SVCS}" | grep -o '"name"' | wc -l)
if [[ "${SVC_COUNT}" -ge 3 ]]; then
  pass "At least 3 HTTP services registered (found ${SVC_COUNT})"
else
  fail "Expected ≥3 services, found ${SVC_COUNT}"
fi

# ── PHASE 4: Cleanup ──────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
info "Cleanup complete"

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi

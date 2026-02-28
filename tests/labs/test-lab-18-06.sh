#!/usr/bin/env bash
# test-lab-18-06.sh -- Traefik Lab 06: Production Deployment
# Tests: Traefik prod HA -- TLS, rate limiting, access logs, LB, Prometheus, circuit breaker
# Usage: bash test-lab-18-06.sh
set -euo pipefail

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; ((PASS++)); }
fail(){ echo "[FAIL] $1"; ((FAIL++)); }
info(){ echo "[INFO] $1"; }

# -- Section 1: Traefik API ---------------------------------------------------
info "Section 1: Traefik dashboard API"
version=$(curl -sf http://localhost:8080/api/version 2>/dev/null | grep -o '"Version":"[^"]*"' | cut -d'"' -f4 || true)
info "Traefik version: $version"
if [[ -n "$version" ]]; then ok "Traefik API version: $version"; else fail "Traefik API version endpoint"; fi

# -- Section 2: HTTP backend routes -------------------------------------------
info "Section 2: HTTP :80 backend route"
status=$(curl -so /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null || echo "000")
info "GET / -> $status"
if [[ "$status" == "200" ]]; then ok "GET / -> 200 via HTTP"; else fail "GET / -> 200 (got $status)"; fi

# -- Section 3: TLS HTTPS endpoint --------------------------------------------
info "Section 3: HTTPS :443 (self-signed TLS)"
https_status=$(curl -sk -o /dev/null -w "%{http_code}" https://localhost/ 2>/dev/null || echo "000")
info "GET https://localhost/ -> $https_status"
if [[ "$https_status" == "200" || "$https_status" == "404" ]]; then
  ok "HTTPS :443 responding ($https_status)"
else
  fail "HTTPS :443 (got $https_status)"
fi

# -- Section 4: Load balancing across backends --------------------------------
info "Section 4: Load balancing across 2 backends"
declare -A backends
for i in 1 2 3 4 5 6; do
  host=$(curl -sf http://localhost/ 2>/dev/null | grep "^Hostname:" | awk '{print $2}' || echo "unknown")
  backends["$host"]=1
done
unique=${#backends[@]}
info "Unique backends seen in 6 requests: $unique"
if [[ "$unique" -ge 2 ]]; then ok "Load balancing: $unique unique backends across 6 requests"; else fail "Load balancing (only $unique unique backend)"; fi

# -- Section 5: Rate limiting -------------------------------------------------
info "Section 5: Rate limiting middleware"
limit_hit=0
for i in $(seq 1 50); do
  sc=$(curl -so /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null || echo "000")
  if [[ "$sc" == "429" ]]; then ((limit_hit++)); fi
done
info "Rate limit responses (429): $limit_hit / 50"
if [[ "$limit_hit" -ge 1 ]]; then ok "Rate limiting active ($limit_hit/50 requests throttled)"; else fail "Rate limiting (no 429 in 50 requests)"; fi

# -- Section 6: Traefik routers and services ----------------------------------
info "Section 6: Traefik router and service count"
routers=$(curl -sf http://localhost:8080/api/http/routers 2>/dev/null | grep -o '"name"' | wc -l | tr -d ' ' || echo 0)
services=$(curl -sf http://localhost:8080/api/http/services 2>/dev/null | grep -o '"name"' | wc -l | tr -d ' ' || echo 0)
info "Routers: $routers, Services: $services"
[[ "$routers" -ge 1 ]] && ok "Traefik routers: $routers" || fail "Traefik routers (expected >=1)"
[[ "$services" -ge 1 ]] && ok "Traefik services: $services" || fail "Traefik services (expected >=1)"

# -- Section 7: Middlewares configured ----------------------------------------
info "Section 7: Middleware configuration"
middlewares=$(curl -sf http://localhost:8080/api/http/middlewares 2>/dev/null | grep -o '"name"' | wc -l | tr -d ' ' || echo 0)
info "Middlewares configured: $middlewares"
[[ "$middlewares" -ge 2 ]] && ok "Middlewares configured: $middlewares (rate-limit + secure-headers)" || fail "Middlewares (expected >=2, got $middlewares)"

# -- Section 8: Prometheus metrics endpoint -----------------------------------
info "Section 8: Traefik metrics :8082"
metrics=$(curl -sf http://localhost:8082/metrics 2>/dev/null || true)
router_m=$(echo "$metrics" | grep -c "^traefik_router_" || echo 0)
service_m=$(echo "$metrics" | grep -c "^traefik_service_" || echo 0)
ep_m=$(echo "$metrics" | grep -c "^traefik_entrypoint_" || echo 0)
info "Router metrics: $router_m, Service metrics: $service_m, Entrypoint metrics: $ep_m"
[[ "$router_m" -ge 1 ]] && ok "traefik_router_* metrics present ($router_m)" || fail "traefik_router_* metrics"
[[ "$service_m" -ge 1 ]] && ok "traefik_service_* metrics present ($service_m)" || fail "traefik_service_* metrics"
[[ "$ep_m" -ge 1 ]] && ok "traefik_entrypoint_* metrics present ($ep_m)" || fail "traefik_entrypoint_* metrics"

# -- Section 9: Prometheus scraping Traefik -----------------------------------
info "Section 9: Prometheus :9090 scraping Traefik"
targets=$(curl -sf "http://localhost:9090/api/v1/targets" 2>/dev/null | grep -o '"health":"up"' | wc -l | tr -d ' ' || echo 0)
info "Prometheus healthy targets: $targets"
[[ "$targets" -ge 1 ]] && ok "Prometheus scraping Traefik (targets up: $targets)" || fail "Prometheus scraping Traefik"
prom_query=$(curl -sf "http://localhost:9090/api/v1/query?query=traefik_config_reloads_total" 2>/dev/null || true)
echo "$prom_query" | grep -q '"resultType"' && ok "Prometheus query traefik_config_reloads_total OK" || fail "Prometheus query traefik_config_reloads_total"

# -- Section 10: Access log ---------------------------------------------------
info "Section 10: Access log file"
log_exists=$(docker exec it-stack-traefik-prod ls /logs/access.log 2>/dev/null && echo "yes" || echo "no")
info "Access log: $log_exists"
if [[ "$log_exists" == "yes" ]]; then
  lines=$(docker exec it-stack-traefik-prod wc -l /logs/access.log 2>/dev/null | awk '{print $1}' || echo 0)
  info "Access log lines: $lines"
  ok "Access log exists and has $lines entries"
else
  fail "Access log /logs/access.log not found"
fi

# -- Section 11: Security headers on response ---------------------------------
info "Section 11: Security headers in response"
headers=$(curl -sI http://localhost/ 2>/dev/null || true)
if echo "$headers" | grep -qi "X-Content-Type-Options"; then ok "X-Content-Type-Options header present"; else fail "X-Content-Type-Options header"; fi
if echo "$headers" | grep -qi "X-Frame-Options"; then ok "X-Frame-Options header present"; else fail "X-Frame-Options header"; fi

# -- Section 12: Integration score -------------------------------------------
info "Section 12: Production integration score"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed"
if [[ $FAIL -eq 0 ]]; then
  echo "[SCORE] 6/6 -- All production checks passed"
  exit 0
else
  echo "[SCORE] FAIL ($FAIL failures)"
  exit 1
fi

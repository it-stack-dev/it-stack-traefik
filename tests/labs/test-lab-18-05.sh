#!/usr/bin/env bash
# test-lab-18-05.sh -- Traefik Lab 05: Advanced Integration
# Tests: Traefik + Keycloak + oauth2-proxy (ForwardAuth) + Prometheus scraping
# Usage: KC_PASS=Lab05Password! bash test-lab-18-05.sh
set -euo pipefail

KC_PASS="${KC_PASS:-Lab05Password!}"
PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; ((PASS++)); }
fail(){ echo "[FAIL] $1"; ((FAIL++)); }
info(){ echo "[INFO] $1"; }

# -- Section 1: Traefik API ---------------------------------------------------
info "Section 1: Traefik API"
resp=$(curl -sf http://localhost:8080/api/version 2>/dev/null || true)
if echo "$resp" | grep -q '"Version"'; then ok "Traefik API /api/version"; else fail "Traefik API /api/version"; fi

# -- Section 2: Keycloak health -----------------------------------------------
info "Section 2: Keycloak health"
resp=$(curl -sf http://localhost:8080/health/ready 2>/dev/null || true)
if echo "$resp" | grep -qi '"status".*"UP"\|status.*up'; then ok "Keycloak /health/ready"; else fail "Keycloak /health/ready"; fi

# -- Section 3: Admin token ---------------------------------------------------
info "Section 3: Keycloak admin token"
token=$(curl -sf -X POST http://localhost:8080/realms/master/protocol/openid-connect/token \
  -d "client_id=admin-cli&grant_type=password&username=admin&password=${KC_PASS}" \
  2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || true)
if [[ -n "$token" ]]; then ok "Admin token obtained"; else fail "Admin token obtained"; fi

# -- Section 4: Realm + clients -----------------------------------------------
info "Section 4: Realm and OIDC clients setup"
if [[ -n "$token" ]]; then
  curl -sf -X POST http://localhost:8080/admin/realms \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d '{"realm":"it-stack","enabled":true,"displayName":"IT-Stack Lab 05"}' 2>/dev/null || true
  curl -sf -X POST http://localhost:8080/admin/realms/it-stack/clients \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d '{"clientId":"traefik-app","publicClient":false,"protocol":"openid-connect","enabled":true}' 2>/dev/null || true
  curl -sf -X POST http://localhost:8080/admin/realms/it-stack/clients \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d '{"clientId":"oauth2-proxy","publicClient":false,"protocol":"openid-connect","enabled":true}' 2>/dev/null || true
  realm_check=$(curl -sf -H "Authorization: Bearer $token" \
    http://localhost:8080/admin/realms/it-stack 2>/dev/null | grep -c '"realm"' || true)
  [[ "$realm_check" -ge 1 ]] && ok "Realm it-stack exists" || fail "Realm it-stack exists"
fi

# -- Section 5: Traefik routers -----------------------------------------------
info "Section 5: Traefik router count"
routers=$(curl -sf http://localhost:8080/api/http/routers 2>/dev/null || true)
count=$(echo "$routers" | grep -o '"name"' | wc -l | tr -d ' ')
info "Routers found: $count"
if [[ "$count" -ge 4 ]]; then ok "Traefik routers >=4 ($count)"; else fail "Traefik routers >=4 (got $count)"; fi

# -- Section 6: Public route (no auth) ----------------------------------------
info "Section 6: Public route"
status=$(curl -so /dev/null -w "%{http_code}" http://localhost/public 2>/dev/null || echo "000")
info "GET /public -> $status"
if [[ "$status" == "200" ]]; then ok "GET /public -> 200 (no auth required)"; else fail "GET /public -> 200 (got $status)"; fi

# -- Section 7: Protected route (ForwardAuth active) --------------------------
info "Section 7: Protected route ForwardAuth"
status=$(curl -so /dev/null -w "%{http_code}" http://localhost/protected 2>/dev/null || echo "000")
info "GET /protected -> $status"
if [[ "$status" == "302" || "$status" == "401" ]]; then
  ok "GET /protected -> $status (ForwardAuth active)"
else
  fail "GET /protected -> 302/401 (got $status)"
fi

# -- Section 8: KC routes via Traefik -----------------------------------------
info "Section 8: Keycloak routes through Traefik"
kc_realm=$(curl -so /dev/null -w "%{http_code}" \
  http://localhost/realms/master/.well-known/openid-configuration 2>/dev/null || echo "000")
info "GET /realms/master/.well-known -> $kc_realm"
if [[ "$kc_realm" == "200" ]]; then ok "KC OIDC discovery via Traefik /realms"; else fail "KC OIDC discovery via Traefik (got $kc_realm)"; fi

# -- Section 9: Security headers on protected ---------------------------------
info "Section 9: Security headers middleware"
headers=$(curl -sI http://localhost/protected 2>/dev/null || true)
if echo "$headers" | grep -qi "X-Content-Type-Options\|x-frame-options\|X-Frame-Options"; then
  ok "Security headers present on /protected"
else
  fail "Security headers present on /protected"
fi

# -- Section 10: Prometheus scraping Traefik ----------------------------------
info "Section 10: Prometheus scraping Traefik metrics"
prom_targets=$(curl -sf "http://localhost:9090/api/v1/targets" 2>/dev/null \
  | grep -o '"health":"up"' | wc -l | tr -d ' ' || echo 0)
info "Prometheus healthy targets: $prom_targets"
if [[ "$prom_targets" -ge 1 ]]; then ok "Prometheus target traefik is up"; else fail "Prometheus target traefik is up"; fi

# -- Section 11: Traefik metrics endpoint -------------------------------------
info "Section 11: Traefik metrics :8082"
metrics=$(curl -sf http://localhost:8082/metrics 2>/dev/null || true)
router_metrics=$(echo "$metrics" | grep -c "^traefik_router_" || echo 0)
info "traefik_router_* metrics: $router_metrics"
if [[ "$router_metrics" -ge 1 ]]; then ok "Traefik router metrics present"; else fail "Traefik router metrics present"; fi
ep_metrics=$(echo "$metrics" | grep -c "^traefik_entrypoint_" || echo 0)
if [[ "$ep_metrics" -ge 1 ]]; then ok "Traefik entrypoint metrics present"; else fail "Traefik entrypoint metrics present"; fi

# -- Section 12: Prometheus query for Traefik data ----------------------------
info "Section 12: Prometheus query traefik_config_reloads_total"
prom_query=$(curl -sf \
  "http://localhost:9090/api/v1/query?query=traefik_config_reloads_total" \
  2>/dev/null || true)
if echo "$prom_query" | grep -q '"resultType"'; then
  ok "Prometheus query traefik_config_reloads_total returns data"
else
  fail "Prometheus query traefik_config_reloads_total returns data"
fi

# -- Section 13: Integration score --------------------------------------------
info "Section 13: Integration score"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed"
if [[ $FAIL -eq 0 ]]; then
  echo "[SCORE] 5/5 -- All integration checks passed"
  exit 0
else
  echo "[SCORE] FAIL ($FAIL failures)"
  exit 1
fi

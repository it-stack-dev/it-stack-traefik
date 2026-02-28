#!/usr/bin/env bash
# test-lab-18-04.sh — Traefik Lab 04: ForwardAuth SSO via Keycloak OIDC
# Tests: Keycloak setup, OIDC, oauth2-proxy ForwardAuth, public vs protected routes
set -euo pipefail

PASS=0; FAIL=0
KC_PASS="${KC_PASS:-Lab04Password!}"
KC_URL="http://localhost:8080"
REALM="it-stack"
TRAEFIK_URL="http://localhost:80"

pass()  { ((++PASS)); echo "  [PASS] $1"; }
fail()  { ((++FAIL)); echo "  [FAIL] $1"; }
warn()  { echo "  [WARN] $1"; }
header(){ echo; echo "=== $1 ==="; }

kc_token() {
  curl -sf -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli&grant_type=password&username=admin&password=${KC_PASS}" \
    | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

header "1. Keycloak Health"
if curl -sf "$KC_URL/health/ready" | grep -q '"status":"UP"'; then
  pass "Keycloak /health/ready UP"
else
  fail "Keycloak not ready"; exit 1
fi

header "2. Admin Auth + Realm/Client/User Setup"
TOKEN=$(kc_token)
[[ -n "$TOKEN" ]] && pass "Admin token from master realm" || { fail "Admin auth failed"; exit 1; }
curl -sf -X POST "$KC_URL/admin/realms" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"realm\":\"$REALM\",\"enabled\":true}" -o /dev/null && pass "Realm '$REALM' created" || warn "Realm may exist"
TOKEN=$(kc_token)
curl -sf -X POST "$KC_URL/admin/realms/$REALM/clients" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"clientId\":\"oauth2-proxy\",\"secret\":\"$KC_PASS\",\"publicClient\":false,
       \"serviceAccountsEnabled\":true,\"redirectUris\":[\"http://localhost:4180/*\"],
       \"enabled\":true}" -o /dev/null && pass "oauth2-proxy client created" || warn "Client may exist"
TOKEN=$(kc_token)
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KC_URL/admin/realms/$REALM/users" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"username\":\"labuser\",\"enabled\":true,\"email\":\"labuser@lab.local\",
       \"emailVerified\":true,
       \"credentials\":[{\"type\":\"password\",\"value\":\"$KC_PASS\",\"temporary\":false}]}")
[[ "$STATUS" =~ ^(201|409)$ ]] && pass "User 'labuser' ready" || fail "User creation failed (HTTP $STATUS)"

header "3. OIDC Discovery"
DISCOVERY=$(curl -sf "$KC_URL/realms/$REALM/.well-known/openid-configuration")
for field in token_endpoint authorization_endpoint jwks_uri; do
  echo "$DISCOVERY" | grep -q "\"$field\"" && pass "Discovery: $field present" || fail "Discovery missing $field"
done

header "4. Client Credentials Token"
SA_TOKEN=$(curl -sf -X POST "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
  -d "client_id=oauth2-proxy&client_secret=${KC_PASS}&grant_type=client_credentials" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
[[ -n "$SA_TOKEN" ]] && pass "Client credentials token obtained" || fail "Client credentials failed"
IFS='.' read -ra P <<< "$SA_TOKEN"
[[ "${#P[@]}" -eq 3 ]] && pass "JWT structure valid" || fail "Invalid JWT"

header "5. Traefik Dashboard"
if curl -sf http://localhost:8080/api/version | grep -q "Version"; then
  pass "Traefik dashboard API accessible"
else
  fail "Traefik dashboard not accessible"
fi

header "6. Public Route (no auth required)"
PUB=$(curl -s -o /dev/null -w "%{http_code}" "$TRAEFIK_URL/public")
[[ "$PUB" -eq 200 ]] && pass "Public route /public → 200 OK" || fail "Public route failed (HTTP $PUB)"

header "7. Protected Route (ForwardAuth — expect SSO redirect)"
PROT=$(curl -s -o /dev/null -w "%{http_code}" --max-redirect 0 "$TRAEFIK_URL/protected" 2>/dev/null || true)
if [[ "$PROT" =~ ^(302|307|401)$ ]]; then
  pass "Protected route /protected → HTTP $PROT (ForwardAuth intercepted)"
else
  fail "Protected route unexpected response: HTTP $PROT"
fi

header "8. oauth2-proxy /oauth2/callback Reachable via Traefik"
OAUTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-redirect 0 "$TRAEFIK_URL/oauth2/callback" 2>/dev/null || true)
[[ "$OAUTH_STATUS" =~ ^(200|302|400)$ ]] && pass "/oauth2/callback route accessible (HTTP $OAUTH_STATUS)" \
  || fail "/oauth2/callback not accessible (HTTP $OAUTH_STATUS)"

header "9. ForwardAuth Middleware in Traefik Config"
ROUTERS=$(curl -sf http://localhost:8080/api/http/routers 2>/dev/null || echo "[]")
echo "$ROUTERS" | grep -q "forward-auth\|forwardauth\|oauth2" \
  && pass "ForwardAuth middleware referenced in router config" || warn "ForwardAuth middleware not visible in API (may use labels only)"

header "10. Traefik Router Count"
ROUTER_COUNT=$(echo "$ROUTERS" | grep -o '"routerName"' | wc -l || echo "0")
# Count routers differently
ROUTER_COUNT=$(curl -sf http://localhost:8080/api/http/routers 2>/dev/null | grep -o '"provider"' | wc -l || echo "0")
[[ "$ROUTER_COUNT" -ge 2 ]] && pass "Traefik has $ROUTER_COUNT routers (public + protected expected)" || warn "Router count: $ROUTER_COUNT"

echo
echo "═══════════════════════════════════════"
echo " Lab 18-04 Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
# Architecture — IT-Stack TRAEFIK

## Overview

Traefik is the central reverse proxy, routing all HTTPS traffic to services via subdomain, handling TLS termination and certificate management.

## Role in IT-Stack

- **Category:** infrastructure
- **Phase:** 1
- **Server:** lab-proxy1 (10.0.50.15)
- **Ports:** 80 (HTTP), 443 (HTTPS), 8080 (Dashboard)

## Dependencies

| Dependency | Type | Required For |
|-----------|------|--------------|
| FreeIPA | Identity | User directory |
| Keycloak | SSO | Authentication |
| PostgreSQL | Database | Data persistence |
| Redis | Cache | Sessions/queues |
| Traefik | Proxy | HTTPS routing |

## Data Flow

```
User → Traefik (HTTPS) → traefik → PostgreSQL (data)
                       ↗ Keycloak (auth)
                       ↗ Redis (sessions)
```

## Security

- All traffic over TLS via Traefik
- Authentication delegated to Keycloak OIDC
- Database credentials via Ansible Vault
- Logs shipped to Graylog

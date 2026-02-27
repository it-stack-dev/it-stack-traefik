#!/bin/bash
# entrypoint.sh — IT-Stack traefik container entrypoint
set -euo pipefail

echo "Starting IT-Stack TRAEFIK (Module 18)..."

# Source any environment overrides
if [ -f /opt/it-stack/traefik/config.env ]; then
    # shellcheck source=/dev/null
    source /opt/it-stack/traefik/config.env
fi

# Execute the upstream entrypoint or command
exec "$$@"

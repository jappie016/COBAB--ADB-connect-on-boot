sudo tee /usr/local/bin/connect-android.sh > /dev/null << 'EOF'
#!/bin/bash
# Silent auto-detect + ADB connect to Android device on boot
# Uses mDNS to find the current randomized wireless debugging port
# Target IP preference: 192.168.1.128

PREFERRED_IP="192.168.1.128"
MAX_RETRIES=40
RETRY_DELAY=4
LOG="/var/log/connect-android.log"

# Everything goes to the log (silent)
exec >> "$LOG" 2>&1

echo "========================================"
echo "$(date): Starting Android ADB auto-connect script"

# Wait for network
echo "$(date): Waiting for network..."
for i in $(seq 1 60); do
    if ping -c 1 -W 1 192.168.1.1 >/dev/null 2>&1 || \
       ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
        echo "$(date): Network is up"
        break
    fi
    sleep 2
done

# Ensure adb is available
if ! command -v adb >/dev/null 2>&1; then
    echo "$(date): ERROR - adb not found in PATH"
    exit 1
fi

adb start-server >/dev/null 2>&1
sleep 1

# --------------------------------------------------
# Function: discover current ADB wireless port via mDNS
# --------------------------------------------------
discover_and_connect() {
    local mdns_output
    mdns_output=$(adb mdns services 2>/dev/null)

    if [ -z "$mdns_output" ]; then
        echo "$(date): No mDNS services found yet"
        return 1
    fi

    echo "$(date): mDNS services discovered:"
    echo "$mdns_output"

    # Modern wireless debugging (_adb-tls-connect._tcp)
    local line
    while IFS= read -r line; do
        if echo "$line" | grep -q "_adb-tls-connect\._tcp"; then
            local endpoint
            endpoint=$(echo "$line" | awk '{print $NF}')

            if [[ "\( endpoint" =\~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+ \) ]]; then
                local ip="${endpoint%%:*}"

                if [ -n "$PREFERRED_IP" ] && [ "$ip" != "$PREFERRED_IP" ]; then
                    echo "$(date): Skipping $endpoint (not preferred IP $PREFERRED_IP)"
                    continue
                fi

                echo "$(date): Found device at $endpoint – attempting connect..."
                adb disconnect "$endpoint" >/dev/null 2>&1

                if adb connect "$endpoint" 2>&1 | grep -qiE "connected to|already connected"; then
                    echo "$(date): SUCCESS – connected to $endpoint"
                    adb devices
                    return 0
                else
                    echo "$(date): Connect attempt to $endpoint failed"
                fi
            fi
        fi
    done <<< "$mdns_output"

    # Legacy _adb._tcp fallback
    while IFS= read -r line; do
        if echo "$line" | grep -q "_adb\._tcp"; then
            local endpoint
            endpoint=$(echo "$line" | awk '{print $NF}')
            if [[ "\( endpoint" =\~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+ \) ]]; then
                local ip="${endpoint%%:*}"
                if [ -n "$PREFERRED_IP" ] && [ "$ip" != "$PREFERRED_IP" ]; then
                    continue
                fi
                echo "$(date): Found legacy service at $endpoint – attempting connect..."
                adb disconnect "$endpoint" >/dev/null 2>&1
                if adb connect "$endpoint" 2>&1 | grep -qiE "connected to|already connected"; then
                    echo "$(date): SUCCESS – connected to $endpoint (legacy)"
                    adb devices
                    return 0
                fi
            fi
        fi
    done <<< "$mdns_output"

    return 1
}

# --------------------------------------------------
# Main retry loop
# --------------------------------------------------
for attempt in $(seq 1 $MAX_RETRIES); do
    echo "$(date): Attempt $attempt/$MAX_RETRIES"

    if discover_and_connect; then
        echo "$(date): Auto-connect finished successfully"
        exit 0
    fi

    # Classic port 5555 fallback
    if [ -n "$PREFERRED_IP" ]; then
        echo "$(date): Trying classic port 5555 as fallback..."
        if adb connect "${PREFERRED_IP}:5555" 2>&1 | grep -qiE "connected to|already connected"; then
            echo "$(date): SUCCESS – connected via classic port 5555"
            adb devices
            exit 0
        fi
    fi

    sleep $RETRY_DELAY
done

echo "$(date): Failed to discover/connect after $MAX_RETRIES attempts"
echo "$(date): Make sure Wireless Debugging is enabled on the phone"
echo "$(date): and that the device was previously paired with this computer."
exit 1
EOF

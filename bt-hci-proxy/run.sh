#!/usr/bin/with-contenv bashio

DEVICE=$(bashio::config 'device')
PROTOCOL=$(bashio::config 'protocol')
PASSIVE_SCAN=$(bashio::config 'passive_scan')

# hci_uart is typically already loaded on HAOS. Try modprobe as a fallback,
# but don't fail if it errors (e.g. /lib/modules not available in container).
if ! grep -q hci_uart /proc/modules 2>/dev/null; then
    bashio::log.info "hci_uart not loaded, attempting modprobe..."
    modprobe hci_uart 2>/dev/null || bashio::log.warning "modprobe failed — hci_uart may be built into the kernel"
fi

enable_passive_scan() {
    if bashio::var.true "${PASSIVE_SCAN}"; then
        # Wait for hci0 to appear
        for i in $(seq 1 10); do
            if [ -d /sys/class/bluetooth/hci0 ]; then
                bashio::log.info "Enabling passive scanning on hci0..."
                if btmgmt --index 0 passive-scan on 2>/dev/null; then
                    bashio::log.info "Passive scanning enabled"
                else
                    bashio::log.warning "Failed to enable passive scanning via btmgmt"
                fi
                return
            fi
            sleep 1
        done
        bashio::log.warning "hci0 did not appear in time — skipping passive scan config"
    fi
}

bashio::log.info "Attaching Bluetooth UART on ${DEVICE} with protocol ${PROTOCOL}..."
btattach -B "${DEVICE}" -P "${PROTOCOL}" &
BTATTACH_PID=$!

# Give btattach a moment to attach or fail
sleep 2

if kill -0 "${BTATTACH_PID}" 2>/dev/null; then
    # btattach is running — wait for it (it stays in foreground)
    bashio::log.info "btattach running (PID ${BTATTACH_PID})"
    enable_passive_scan
    wait "${BTATTACH_PID}"
elif [ -d /sys/class/bluetooth/hci0 ]; then
    # btattach exited but hci0 exists — line discipline was already attached
    bashio::log.info "hci0 already exists — Bluetooth is active"
    enable_passive_scan
    # Stay alive and monitor that hci0 remains available
    while [ -d /sys/class/bluetooth/hci0 ]; do
        sleep 30
    done
    bashio::log.warning "hci0 disappeared — exiting so Supervisor can restart us"
    exit 1
else
    bashio::log.error "btattach failed and no hci0 device found"
    exit 1
fi

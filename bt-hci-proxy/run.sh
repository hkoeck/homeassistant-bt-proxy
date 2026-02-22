#!/usr/bin/with-contenv bashio

DEVICE=$(bashio::config 'device')
PROTOCOL=$(bashio::config 'protocol')
PASSIVE_SCAN=$(bashio::config 'passive_scan')
ADAPTER_NAME_PREFIX=$(bashio::config 'adapter_name_prefix')

DBUS_ADAPTER="org.bluez /org/bluez/hci0"

# hci_uart is typically already loaded on HAOS. Try modprobe as a fallback,
# but don't fail if it errors (e.g. /lib/modules not available in container).
if ! grep -q hci_uart /proc/modules 2>/dev/null; then
    bashio::log.info "hci_uart not loaded, attempting modprobe..."
    modprobe hci_uart 2>/dev/null || bashio::log.warning "modprobe failed — hci_uart may be built into the kernel"
fi

wait_for_hci0() {
    for i in $(seq 1 10); do
        if [ -d /sys/class/bluetooth/hci0 ]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

get_dbus_property() {
    local property="$1"
    dbus-send --system --print-reply --dest=org.bluez \
        /org/bluez/hci0 \
        org.freedesktop.DBus.Properties.Get \
        string:"org.bluez.Adapter1" string:"${property}" 2>/dev/null
}

set_adapter_name() {
    if [ -n "${ADAPTER_NAME_PREFIX}" ]; then
        # Read the manufacturer ID from BlueZ D-Bus properties
        local manufacturer_id
        manufacturer_id=$(get_dbus_property "Manufacturer" | grep "uint16" | awk '{print $NF}')

        local manufacturer_name=""
        case "${manufacturer_id}" in
            2)   manufacturer_name="Intel Corp." ;;
            10)  manufacturer_name="Qualcomm" ;;
            13)  manufacturer_name="Texas Instruments" ;;
            15)  manufacturer_name="Broadcom" ;;
            29)  manufacturer_name="CSR" ;;
            57)  manufacturer_name="MediaTek" ;;
            93)  manufacturer_name="Realtek" ;;
            *)   manufacturer_name="ID ${manufacturer_id}" ;;
        esac

        local new_name="${ADAPTER_NAME_PREFIX} ${manufacturer_name}"
        bashio::log.info "Setting adapter alias to: ${new_name}"
        dbus-send --system --print-reply --dest=org.bluez \
            /org/bluez/hci0 \
            org.freedesktop.DBus.Properties.Set \
            string:"org.bluez.Adapter1" string:"Alias" \
            variant:string:"${new_name}" 2>/dev/null || \
            bashio::log.warning "Failed to set adapter alias via D-Bus"
    fi
}

enable_passive_scan() {
    if bashio::var.true "${PASSIVE_SCAN}"; then
        bashio::log.info "Enabling passive scanning on hci0..."
        if btmgmt --index 0 passive-scan on 2>/dev/null; then
            bashio::log.info "Passive scanning enabled"
        else
            bashio::log.warning "Failed to enable passive scanning via btmgmt"
        fi
    fi
}

configure_adapter() {
    if wait_for_hci0; then
        set_adapter_name
        enable_passive_scan
    else
        bashio::log.warning "hci0 did not appear in time — skipping adapter config"
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
    configure_adapter
    wait "${BTATTACH_PID}"
elif [ -d /sys/class/bluetooth/hci0 ]; then
    # btattach exited but hci0 exists — line discipline was already attached
    bashio::log.info "hci0 already exists — Bluetooth is active"
    configure_adapter
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

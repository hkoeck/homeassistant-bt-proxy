#!/usr/bin/with-contenv bashio

DEVICE=$(bashio::config 'device')
PROTOCOL=$(bashio::config 'protocol')
ADAPTER_NAME_PREFIX=$(bashio::config 'adapter_name_prefix')

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

# Wait for BlueZ to register hci0 on D-Bus (adapter must be powered and visible)
wait_for_bluez_adapter() {
    for i in $(seq 1 20); do
        if dbus-send --system --print-reply --dest=org.bluez \
            /org/bluez/hci0 \
            org.freedesktop.DBus.Properties.Get \
            string:"org.bluez.Adapter1" string:"Address" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

set_adapter_name() {
    if [ -n "${ADAPTER_NAME_PREFIX}" ]; then
        # Read the manufacturer ID from BlueZ D-Bus properties
        local manufacturer_id
        manufacturer_id=$(dbus-send --system --print-reply --dest=org.bluez \
            /org/bluez/hci0 \
            org.freedesktop.DBus.Properties.Get \
            string:"org.bluez.Adapter1" string:"Manufacturer" 2>/dev/null \
            | grep "uint16" | awk '{print $NF}' || echo "")

        local new_name
        if [ -n "${manufacturer_id}" ]; then
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
            new_name="${ADAPTER_NAME_PREFIX} ${manufacturer_name}"
        else
            bashio::log.warning "Could not read manufacturer ID from D-Bus"
            new_name="${ADAPTER_NAME_PREFIX}"
        fi

        bashio::log.info "Setting adapter alias to: ${new_name}"
        if dbus-send --system --print-reply --dest=org.bluez \
            /org/bluez/hci0 \
            org.freedesktop.DBus.Properties.Set \
            string:"org.bluez.Adapter1" string:"Alias" \
            variant:string:"${new_name}" >/dev/null 2>&1; then
            bashio::log.info "Adapter alias set successfully"
        else
            bashio::log.warning "Failed to set adapter alias via D-Bus"
        fi
    fi
}

configure_adapter() {
    if wait_for_hci0; then
        bashio::log.info "hci0 is up, waiting for BlueZ to register adapter..."
        if wait_for_bluez_adapter; then
            bashio::log.info "BlueZ adapter registered, configuring..."
            # Passive scanning is left to HA's bluetooth integration (it sets PASSIVE
            # itself); the old btmgmt call here was redundant and logged a false
            # "Failed to enable passive scanning" warning on every start.
            set_adapter_name
        else
            # BlueZ failed to register the freshly-attached hci0 (transient race
            # observed on restart). Proceeding leaves a half-configured adapter that
            # HA's bluetooth integration cannot set up -> the config entry flips to
            # setup_retry and BLE stays dead until manual intervention. Exit non-zero
            # so the Supervisor watchdog restarts us: recreating hci0 reliably
            # re-triggers registration (confirmed: a 2nd restart clears it).
            bashio::log.error "BlueZ did not register hci0 — exiting for watchdog restart"
            kill "${BTATTACH_PID}" 2>/dev/null
            exit 1
        fi
    else
        bashio::log.error "hci0 did not appear in time — exiting for watchdog restart"
        exit 1
    fi
}

# --- Adapter health watchdog -------------------------------------------------
# The RTL8761B-over-UART adapter can wedge into a half-dead state — hci0 stays
# present in sysfs and btattach keeps running, but BlueZ reports Powered:no
# (PowerState:on), so BLE silently dies. HA's own auto-recovery can't reset it
# (the HA Core container lacks NET_ADMIN/NET_RAW → "Could not cycle the adapter …
# timed out"), and the old monitor only watched for hci0 vanishing, so nothing
# caught this. We try a gentle bluetoothd re-power first; if the controller is
# truly hung (re-power returns org.bluez.Error.Failed, confirmed 2026-07-18) we
# exit non-zero so the Supervisor recreates hci0 via a fresh btattach — the only
# reliable recovery. Rate-limited (WEDGE_LIMIT consecutive confirmations) to
# avoid a restart-flap that can wedge the controller worse (needing a host USB
# re-enumerate).
POLL_INTERVAL=30   # seconds between health checks
WEDGE_LIMIT=2      # consecutive failed checks before forcing an hci0 recreate

adapter_powered() {
    dbus-send --system --print-reply --dest=org.bluez /org/bluez/hci0 \
        org.freedesktop.DBus.Properties.Get \
        string:"org.bluez.Adapter1" string:"Powered" 2>/dev/null \
        | grep -q "boolean true"
}

try_repower() {
    dbus-send --system --print-reply --dest=org.bluez /org/bluez/hci0 \
        org.freedesktop.DBus.Properties.Set \
        string:"org.bluez.Adapter1" string:"Powered" \
        variant:boolean:true >/dev/null 2>&1
}

monitor_adapter() {
    local wedge_count=0
    while true; do
        sleep "${POLL_INTERVAL}"

        # btattach gone -> recreate the whole stack (skip check if pre-attached)
        if [ -n "${BTATTACH_PID}" ] && ! kill -0 "${BTATTACH_PID}" 2>/dev/null; then
            bashio::log.error "btattach (PID ${BTATTACH_PID}) exited — restarting for fresh hci0"
            exit 1
        fi

        # hci0 vanished from sysfs -> recreate
        if [ ! -d /sys/class/bluetooth/hci0 ]; then
            bashio::log.error "hci0 disappeared from sysfs — exiting for watchdog restart"
            [ -n "${BTATTACH_PID}" ] && kill "${BTATTACH_PID}" 2>/dev/null
            exit 1
        fi

        # a healthy adapter stays Powered:yes; Powered:no is the wedge signature
        if adapter_powered; then
            wedge_count=0
            continue
        fi

        bashio::log.warning "Adapter Powered:no — attempting gentle re-power via bluetoothd…"
        try_repower
        sleep 5
        if adapter_powered; then
            bashio::log.info "Gentle re-power succeeded — adapter back online"
            wedge_count=0
            continue
        fi

        wedge_count=$((wedge_count + 1))
        bashio::log.warning "Adapter still wedged after re-power (${wedge_count}/${WEDGE_LIMIT})"
        if [ "${wedge_count}" -ge "${WEDGE_LIMIT}" ]; then
            bashio::log.error "Adapter wedged (Powered:no, re-power failed) — exiting for watchdog restart to recreate hci0"
            [ -n "${BTATTACH_PID}" ] && kill "${BTATTACH_PID}" 2>/dev/null
            exit 1
        fi
    done
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
    monitor_adapter
elif [ -d /sys/class/bluetooth/hci0 ]; then
    # btattach exited but hci0 exists — line discipline was already attached
    bashio::log.info "hci0 already exists — Bluetooth is active"
    configure_adapter
    # No live btattach here (line discipline pre-attached); still watch adapter health
    BTATTACH_PID=""
    monitor_adapter
else
    bashio::log.error "btattach failed and no hci0 device found"
    exit 1
fi

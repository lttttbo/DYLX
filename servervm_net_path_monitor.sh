#!/bin/sh
#
# ServerVM path monitor
#
# Run this immediately before the Android A/B script.
# Stop it with Ctrl-C after the Android script finishes.
#
# Usage:
#   sh servervm_net_path_monitor.sh [tap_if] [phy_if] [bridge_if] [out_base]
#
# Example:
#   sh servervm_net_path_monitor.sh tap1 eth0 br0 /tmp
#

TAP_IF="${1:-tap1}"
PHY_IF="${2:-eth0}"
BR_IF="${3:-br0}"
OUT_BASE="${4:-/tmp}"

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_BASE}/servervm_net_monitor_${TS}"
SAMPLES="${OUT_DIR}/samples.csv"

mkdir -p "$OUT_DIR" || exit 1

read_stat()
{
    DEV="$1"
    ITEM="$2"
    PATH_NAME="/sys/class/net/${DEV}/statistics/${ITEM}"

    if [ -r "$PATH_NAME" ]; then
        cat "$PATH_NAME"
    else
        echo 0
    fi
}

snapshot()
{
    TAG="$1"

    cat /proc/interrupts > "${OUT_DIR}/interrupts_${TAG}.txt" 2>/dev/null
    cat /proc/net/softnet_stat > "${OUT_DIR}/softnet_${TAG}.txt" 2>/dev/null
    ip -s -s link show "$TAP_IF" > "${OUT_DIR}/${TAP_IF}_${TAG}.txt" 2>&1
    ip -s -s link show "$PHY_IF" > "${OUT_DIR}/${PHY_IF}_${TAG}.txt" 2>&1
    ip -s -s link show "$BR_IF" > "${OUT_DIR}/${BR_IF}_${TAG}.txt" 2>&1

    if command -v tc >/dev/null 2>&1; then
        tc -s qdisc show dev "$TAP_IF" > "${OUT_DIR}/qdisc_${TAP_IF}_${TAG}.txt" 2>&1
        tc -s qdisc show dev "$PHY_IF" > "${OUT_DIR}/qdisc_${PHY_IF}_${TAG}.txt" 2>&1
    fi

    if command -v ethtool >/dev/null 2>&1; then
        ethtool -S "$PHY_IF" > "${OUT_DIR}/ethtool_${PHY_IF}_${TAG}.txt" 2>&1
        ethtool -l "$PHY_IF" > "${OUT_DIR}/channels_${PHY_IF}_${TAG}.txt" 2>&1
    fi

    if command -v nft >/dev/null 2>&1; then
        nft list ruleset > "${OUT_DIR}/nft_${TAG}.txt" 2>&1
    fi
}

cleanup()
{
    snapshot after

    if [ -n "${PS_MON_PID:-}" ]; then
        kill "$PS_MON_PID" 2>/dev/null
    fi

    echo
    echo "Monitor stopped."
    echo "Result directory: $OUT_DIR"
    exit 0
}

trap cleanup INT TERM

{
    echo "timestamp=$TS"
    echo "tap_if=$TAP_IF"
    echo "phy_if=$PHY_IF"
    echo "bridge_if=$BR_IF"
    echo
    uname -a
    echo
    bridge link 2>&1
    echo
    sysctl net.bridge.bridge-nf-call-iptables 2>&1
    sysctl net.bridge.bridge-nf-call-ip6tables 2>&1
    sysctl net.bridge.bridge-nf-call-arptables 2>&1
} > "${OUT_DIR}/environment.txt" 2>&1

snapshot before

echo "epoch,tap_rx_bytes,tap_rx_packets,tap_rx_dropped,tap_rx_errors,eth_tx_bytes,eth_tx_packets,eth_tx_dropped,eth_tx_errors,br_rx_bytes,br_tx_bytes,load1" > "$SAMPLES"

(
    while sleep 5; do
        {
            echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="
            ps -eLo pid,tid,psr,pcpu,comm,args 2>&1 |
                grep -E 'vhost|dsm|ksoftirqd' |
                grep -v grep
        } >> "${OUT_DIR}/workers.log"
    done
) &
PS_MON_PID=$!

echo "Monitoring started."
echo "Output: $OUT_DIR"
echo "Press Ctrl-C after the Android test script finishes."

while sleep 1; do
    EPOCH="$(date +%s)"

    TAP_RX_B="$(read_stat "$TAP_IF" rx_bytes)"
    TAP_RX_P="$(read_stat "$TAP_IF" rx_packets)"
    TAP_RX_D="$(read_stat "$TAP_IF" rx_dropped)"
    TAP_RX_E="$(read_stat "$TAP_IF" rx_errors)"

    ETH_TX_B="$(read_stat "$PHY_IF" tx_bytes)"
    ETH_TX_P="$(read_stat "$PHY_IF" tx_packets)"
    ETH_TX_D="$(read_stat "$PHY_IF" tx_dropped)"
    ETH_TX_E="$(read_stat "$PHY_IF" tx_errors)"

    BR_RX_B="$(read_stat "$BR_IF" rx_bytes)"
    BR_TX_B="$(read_stat "$BR_IF" tx_bytes)"

    LOAD1="$(awk '{print $1}' /proc/loadavg 2>/dev/null)"

    echo "${EPOCH},${TAP_RX_B},${TAP_RX_P},${TAP_RX_D},${TAP_RX_E},${ETH_TX_B},${ETH_TX_P},${ETH_TX_D},${ETH_TX_E},${BR_RX_B},${BR_TX_B},${LOAD1}" >> "$SAMPLES"
done

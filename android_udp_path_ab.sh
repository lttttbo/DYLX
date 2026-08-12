#!/system/bin/sh
#
# Android UDP path A/B test
#
# Purpose:
#   Compare the exact same Android virtio-net UDP TX workload against:
#     1) ServerVM local address
#     2) External PC address
#
# Usage:
#   sh android_udp_path_ab.sh <servervm_ip> <pc_ip> [port] [duration] [repeats]
#
# Example:
#   sh android_udp_path_ab.sh 192.168.1.22 192.168.1.1 5201 60 3
#
# Environment overrides:
#   CPU_LIST="0 1 2 3 4 5"
#   BITRATE=0
#   UDP_LEN=1400
#   REPORT_INTERVAL=10
#   COOLDOWN=10
#   IPERF3_BIN=/data/iperf3
#   OUT_BASE=/data/local/tmp
#

SERVERVM_IP="$1"
PC_IP="$2"
PORT="${3:-5201}"
DURATION="${4:-60}"
REPEATS="${5:-3}"

if [ -z "$SERVERVM_IP" ] || [ -z "$PC_IP" ]; then
    echo "Usage: $0 <servervm_ip> <pc_ip> [port] [duration] [repeats]"
    exit 1
fi

CPU_LIST="${CPU_LIST:-0 1 2 3 4 5}"
BITRATE="${BITRATE:-0}"
UDP_LEN="${UDP_LEN:-1400}"
REPORT_INTERVAL="${REPORT_INTERVAL:-10}"
COOLDOWN="${COOLDOWN:-10}"
OUT_BASE="${OUT_BASE:-/data/local/tmp}"

if [ -n "${IPERF3_BIN:-}" ] && [ -x "$IPERF3_BIN" ]; then
    IPERF3="$IPERF3_BIN"
else
    IPERF3="$(command -v iperf3 2>/dev/null)"
fi

if [ -z "$IPERF3" ] && [ -x "./iperf3" ]; then
    IPERF3="./iperf3"
fi

if [ -z "$IPERF3" ] || [ ! -x "$IPERF3" ]; then
    echo "ERROR: iperf3 not found. Set IPERF3_BIN."
    exit 1
fi

AWK_BIN="$(command -v awk 2>/dev/null)"
if [ -z "$AWK_BIN" ]; then
    echo "ERROR: awk not found."
    exit 1
fi

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_BASE}/udp_path_ab_${TS}"
SUMMARY="${OUT_DIR}/summary.csv"
mkdir -p "$OUT_DIR" || exit 1

CPORT_SUPPORTED=0
if "$IPERF3" --help 2>&1 | grep -q -- '--cport'; then
    CPORT_SUPPORTED=1
fi

echo "round,cpu,target,target_ip,cport,start_epoch,end_epoch,iperf_rc,sender_mbps,receiver_mbps,loss_pct,eth0_tx_bytes_delta,eth0_tx_packets_delta,eth0_tx_dropped_delta,actual_cpu,cpus_allowed_list,log_dir" > "$SUMMARY"

{
    echo "timestamp=$TS"
    echo "servervm_ip=$SERVERVM_IP"
    echo "pc_ip=$PC_IP"
    echo "port=$PORT"
    echo "duration=$DURATION"
    echo "repeats=$REPEATS"
    echo "cpu_list=$CPU_LIST"
    echo "bitrate=$BITRATE"
    echo "udp_len=$UDP_LEN"
    echo "report_interval=$REPORT_INTERVAL"
    echo "cooldown=$COOLDOWN"
    echo "iperf3=$IPERF3"
    echo "cport_supported=$CPORT_SUPPORTED"
    echo
    uname -a
    echo
    "$IPERF3" -v 2>&1
    echo
    echo "CPU online:"
    cat /sys/devices/system/cpu/online 2>/dev/null
    echo
    echo "Shell allowed CPUs:"
    grep -E '^Cpus_allowed:|^Cpus_allowed_list:' /proc/self/status 2>/dev/null
    echo
    echo "Routes:"
    ip route get "$SERVERVM_IP" 2>&1
    ip route get "$PC_IP" 2>&1
} > "${OUT_DIR}/environment.txt" 2>&1

read_stat()
{
    PATH_NAME="$1"
    if [ -r "$PATH_NAME" ]; then
        cat "$PATH_NAME"
    else
        echo 0
    fi
}

parse_rate_mbps()
{
    KIND="$1"
    FILE="$2"

    "$AWK_BIN" -v kind="$KIND" '
        $NF == kind {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /bits\/sec$/) {
                    value = $(i - 1)
                    unit = $i
                }
            }
        }
        END {
            if (value == "") {
                print "NA"
                exit
            }
            if (unit == "Gbits/sec")
                value *= 1000
            else if (unit == "Kbits/sec")
                value /= 1000
            else if (unit == "bits/sec")
                value /= 1000000
            printf "%.3f", value
        }
    ' "$FILE"
}

parse_loss_pct()
{
    FILE="$1"

    "$AWK_BIN" '
        $NF == "receiver" {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^\([0-9.]+%\)$/) {
                    value = $i
                    gsub(/[()%]/, "", value)
                }
            }
        }
        END {
            if (value == "")
                print "NA"
            else
                print value
        }
    ' "$FILE"
}

run_case()
{
    ROUND="$1"
    CPU="$2"
    LABEL="$3"
    TARGET_IP="$4"

    # Same CPU uses the same source port for both destinations and all rounds.
    CPORT=$((41000 + CPU))

    CASE_DIR="${OUT_DIR}/round_${ROUND}_cpu_${CPU}_${LABEL}"
    mkdir -p "$CASE_DIR"

    IPERF_LOG="${CASE_DIR}/iperf3.log"

    TX_B0="$(read_stat /sys/class/net/eth0/statistics/tx_bytes)"
    TX_P0="$(read_stat /sys/class/net/eth0/statistics/tx_packets)"
    TX_D0="$(read_stat /sys/class/net/eth0/statistics/tx_dropped)"

    cat /proc/interrupts > "${CASE_DIR}/interrupts_before.txt" 2>/dev/null
    cat /proc/net/softnet_stat > "${CASE_DIR}/softnet_before.txt" 2>/dev/null
    ip -s -s link show eth0 > "${CASE_DIR}/eth0_before.txt" 2>&1

    START_EPOCH="$(date +%s)"

    echo
    echo "============================================================"
    echo "round=$ROUND cpu=$CPU target=$LABEL($TARGET_IP) cport=$CPORT"
    echo "============================================================"

    if [ "$CPORT_SUPPORTED" -eq 1 ]; then
        "$IPERF3" \
            -A "$CPU" \
            --cport "$CPORT" \
            -p "$PORT" \
            -c "$TARGET_IP" \
            -u -4 \
            -b "$BITRATE" \
            -l "$UDP_LEN" \
            -t "$DURATION" \
            -i "$REPORT_INTERVAL" \
            --udp-counters-64bit \
            > "$IPERF_LOG" 2>&1 &
    else
        "$IPERF3" \
            -A "$CPU" \
            -p "$PORT" \
            -c "$TARGET_IP" \
            -u -4 \
            -b "$BITRATE" \
            -l "$UDP_LEN" \
            -t "$DURATION" \
            -i "$REPORT_INTERVAL" \
            --udp-counters-64bit \
            > "$IPERF_LOG" 2>&1 &
    fi

    IPERF_PID=$!
    sleep 1

    ACTUAL_CPU="NA"
    ALLOWED_LIST="NA"

    if [ -r "/proc/${IPERF_PID}/stat" ]; then
        ACTUAL_CPU="$("$AWK_BIN" '{print $39}' "/proc/${IPERF_PID}/stat" 2>/dev/null)"
        [ -n "$ACTUAL_CPU" ] || ACTUAL_CPU="NA"
    fi

    if [ -r "/proc/${IPERF_PID}/status" ]; then
        ALLOWED_LIST="$("$AWK_BIN" '/^Cpus_allowed_list:/ {print $2}' "/proc/${IPERF_PID}/status")"
        [ -n "$ALLOWED_LIST" ] || ALLOWED_LIST="NA"
        cp "/proc/${IPERF_PID}/status" "${CASE_DIR}/iperf_status.txt" 2>/dev/null
        cp "/proc/${IPERF_PID}/schedstat" "${CASE_DIR}/iperf_schedstat_start.txt" 2>/dev/null
    fi

    wait "$IPERF_PID"
    RC=$?
    END_EPOCH="$(date +%s)"

    TX_B1="$(read_stat /sys/class/net/eth0/statistics/tx_bytes)"
    TX_P1="$(read_stat /sys/class/net/eth0/statistics/tx_packets)"
    TX_D1="$(read_stat /sys/class/net/eth0/statistics/tx_dropped)"

    cat /proc/interrupts > "${CASE_DIR}/interrupts_after.txt" 2>/dev/null
    cat /proc/net/softnet_stat > "${CASE_DIR}/softnet_after.txt" 2>/dev/null
    ip -s -s link show eth0 > "${CASE_DIR}/eth0_after.txt" 2>&1

    SENDER="$(parse_rate_mbps sender "$IPERF_LOG")"
    RECEIVER="$(parse_rate_mbps receiver "$IPERF_LOG")"
    LOSS="$(parse_loss_pct "$IPERF_LOG")"

    TX_B_DELTA=$((TX_B1 - TX_B0))
    TX_P_DELTA=$((TX_P1 - TX_P0))
    TX_D_DELTA=$((TX_D1 - TX_D0))

    echo "${ROUND},${CPU},${LABEL},${TARGET_IP},${CPORT},${START_EPOCH},${END_EPOCH},${RC},${SENDER},${RECEIVER},${LOSS},${TX_B_DELTA},${TX_P_DELTA},${TX_D_DELTA},${ACTUAL_CPU},${ALLOWED_LIST},${CASE_DIR}" >> "$SUMMARY"

    cat "$IPERF_LOG"
    echo "summary: sender=${SENDER}Mbps receiver=${RECEIVER}Mbps loss=${LOSS}%"

    sleep "$COOLDOWN"
}

ROUND=1
while [ "$ROUND" -le "$REPEATS" ]; do
    for CPU in $CPU_LIST; do
        if [ $((ROUND % 2)) -eq 1 ]; then
            run_case "$ROUND" "$CPU" "servervm" "$SERVERVM_IP"
            run_case "$ROUND" "$CPU" "pc" "$PC_IP"
        else
            run_case "$ROUND" "$CPU" "pc" "$PC_IP"
            run_case "$ROUND" "$CPU" "servervm" "$SERVERVM_IP"
        fi
    done
    ROUND=$((ROUND + 1))
done

echo
echo "All tests completed."
echo "Result directory: $OUT_DIR"
echo "Summary: $SUMMARY"
echo

cat "$SUMMARY"

echo
echo "Average receiver bitrate by CPU and target:"
"$AWK_BIN" -F',' '
    NR > 1 && $10 != "NA" {
        key = $2 "," $3
        sum[key] += $10
        count[key]++
        if (!(key in min) || $10 < min[key]) min[key] = $10
        if (!(key in max) || $10 > max[key]) max[key] = $10
    }
    END {
        printf "CPU,target,samples,avg_mbps,min_mbps,max_mbps\n"
        for (cpu = 0; cpu < 6; cpu++) {
            split("servervm pc", labels, " ")
            for (i = 1; i <= 2; i++) {
                key = cpu "," labels[i]
                if (count[key] > 0)
                    printf "%d,%s,%d,%.2f,%.2f,%.2f\n",
                           cpu, labels[i], count[key],
                           sum[key] / count[key], min[key], max[key]
            }
        }
    }
' "$SUMMARY"

#!/system/bin/sh
#
# Android client for the no-vhost affinity A/B test.
#
# Usage:
#   sh android_no_vhost_udp_test.sh <target_ip> [android_cpu] [rounds]
#
# Example:
#   sh android_no_vhost_udp_test.sh 192.168.1.1 1 3
#
# Environment overrides:
#   IPERF3_BIN=/data/iperf3
#   PORT=5201
#   CPORT=41001
#   DURATION=60
#   INTERVAL=10
#   COOLDOWN=10
#   BITRATE=0
#   UDP_LEN=1400
#   OUT_BASE=/data/local/tmp
#

TARGET_IP="$1"
ANDROID_CPU="${2:-1}"
ROUNDS="${3:-3}"

if [ -z "${TARGET_IP}" ]; then
    echo "Usage: $0 <target_ip> [android_cpu] [rounds]"
    exit 1
fi

PORT="${PORT:-5201}"
CPORT="${CPORT:-41001}"
DURATION="${DURATION:-60}"
INTERVAL="${INTERVAL:-10}"
COOLDOWN="${COOLDOWN:-10}"
BITRATE="${BITRATE:-0}"
UDP_LEN="${UDP_LEN:-1400}"
OUT_BASE="${OUT_BASE:-/data/local/tmp}"

if [ -n "${IPERF3_BIN:-}" ] && [ -x "${IPERF3_BIN}" ]; then
    IPERF3="${IPERF3_BIN}"
else
    IPERF3="$(command -v iperf3 2>/dev/null)"
fi

if [ -z "${IPERF3}" ] && [ -x "./iperf3" ]; then
    IPERF3="./iperf3"
fi

if [ -z "${IPERF3}" ] || [ ! -x "${IPERF3}" ]; then
    echo "ERROR: iperf3 not found. Set IPERF3_BIN."
    exit 1
fi

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_BASE}/no_vhost_udp_${TS}"
SUMMARY="${OUT_DIR}/summary.csv"

mkdir -p "${OUT_DIR}" || exit 1

echo "round,android_cpu,target_ip,cport,iperf_rc,sender_mbps,receiver_mbps,loss_pct,log" > "${SUMMARY}"

parse_rate()
{
    kind="$1"
    file="$2"

    awk -v kind="${kind}" '
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
    ' "${file}"
}

parse_loss()
{
    file="$1"

    awk '
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
    ' "${file}"
}

echo "Running preflight handshake test..."

PRE_LOG="${OUT_DIR}/preflight.log"

"${IPERF3}" \
    -A "${ANDROID_CPU}" \
    -p "${PORT}" \
    -c "${TARGET_IP}" \
    -u -4 \
    -b 10M \
    -l "${UDP_LEN}" \
    -t 3 \
    -i 1 \
    --udp-counters-64bit \
    > "${PRE_LOG}" 2>&1

PRE_RC=$?
cat "${PRE_LOG}"

if [ "${PRE_RC}" -ne 0 ]; then
    echo "ERROR: preflight failed. Restart/check the PC iperf3 server."
    exit "${PRE_RC}"
fi

round=1

while [ "${round}" -le "${ROUNDS}" ]; do
    LOG="${OUT_DIR}/round_${round}.log"

    echo
    echo "no-vhost round=${round}, android_cpu=${ANDROID_CPU}, target=${TARGET_IP}"

    "${IPERF3}" \
        -A "${ANDROID_CPU}" \
        --cport "${CPORT}" \
        -p "${PORT}" \
        -c "${TARGET_IP}" \
        -u -4 \
        -b "${BITRATE}" \
        -l "${UDP_LEN}" \
        -t "${DURATION}" \
        -i "${INTERVAL}" \
        --udp-counters-64bit \
        > "${LOG}" 2>&1

    RC=$?
    cat "${LOG}"

    SENDER="$(parse_rate sender "${LOG}")"
    RECEIVER="$(parse_rate receiver "${LOG}")"
    LOSS="$(parse_loss "${LOG}")"

    echo "${round},${ANDROID_CPU},${TARGET_IP},${CPORT},${RC},${SENDER},${RECEIVER},${LOSS},${LOG}" >> "${SUMMARY}"

    if [ "${RC}" -ne 0 ]; then
        echo "ERROR: iperf3 failed in round ${round}; stopping."
        break
    fi

    sleep "${COOLDOWN}"
    round=$((round + 1))
done

echo
echo "Summary:"
cat "${SUMMARY}"
echo
echo "Result directory: ${OUT_DIR}"

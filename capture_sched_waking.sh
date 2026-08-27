#!/bin/sh
#
# capture_sched_waking.sh
#
# 目的：
#   在网络压测稳定阶段，采集 sched:sched_waking，识别：
#     1. 哪些任务被唤醒到 CPU1 / CPU3；
#     2. 唤醒动作由哪个 CPU、哪个任务发起；
#     3. 其中多少属于远程唤醒（source_cpu != target_cpu）；
#     4. 同一采集窗口内，各 CPU 的 Function-call IPI 增量。
#
# 典型用法：
#   UDP压测：
#     TARGET_CPUS=1,3 BACKEND_TID=1155 \
#       sh capture_sched_waking.sh capture udp_cross 1
#
#   TCP压测：
#     TARGET_CPUS=1,3 BACKEND_TID=1155 \
#       sh capture_sched_waking.sh capture tcp_cross 1
#
# 脚本会等待 eth0 TX 流量达到阈值，等待 WARMUP 秒后自动抓取。
#
# 环境变量：
#   PHY_IF=eth0
#   TAP_IF=tap1
#   TARGET_CPUS=1,3
#   BACKEND_TID=<vhost或DSM TX线程TID，可选>
#   OUT_BASE=/tmp/sched_waking_capture
#   START_PPS=10000
#   WAIT_TIMEOUT=120
#   WARMUP=8
#   BUFFER_KB=16384
#
# 注意：
#   - 只统计 ServerVM Linux 中的任务唤醒。
#   - sched_waking 数量不必与 IPI1 一一相等：
#       一个 IPI 可以批量处理多个 wakeup；
#       某些 wakeup 不一定需要发送 IPI。
#   - 若 sched_waking 远程唤醒数量远小于 IPI1，
#     则多数 Function-call IPI 来自其他 SMP callback。
#

set -u

PHY_IF="${PHY_IF:-eth0}"
TAP_IF="${TAP_IF:-tap1}"
TARGET_CPUS="${TARGET_CPUS:-1,3}"
OUT_BASE="${OUT_BASE:-/tmp/sched_waking_capture}"
START_PPS="${START_PPS:-10000}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-120}"
WARMUP="${WARMUP:-8}"
BUFFER_KB="${BUFFER_KB:-16384}"

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

need_root()
{
    [ "$(id -u 2>/dev/null)" = "0" ] ||
        die "please run as root"
}

find_tracefs()
{
    if [ -d /sys/kernel/tracing/events ]; then
        echo /sys/kernel/tracing
        return
    fi

    if [ -d /sys/kernel/debug/tracing/events ]; then
        echo /sys/kernel/debug/tracing
        return
    fi

    die "tracefs/debugfs tracing directory was not found"
}

cpu_count()
{
    if command -v getconf >/dev/null 2>&1; then
        getconf _NPROCESSORS_ONLN 2>/dev/null && return
    fi

    awk '
        NR == 1 {
            n = 0
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^CPU[0-9]+$/)
                    n++
            }
            print n
            exit
        }
    ' /proc/interrupts
}

read_net_stat()
{
    dev="$1"
    item="$2"
    path="/sys/class/net/${dev}/statistics/${item}"

    if [ -r "${path}" ]; then
        cat "${path}"
    else
        echo 0
    fi
}

read_backend_last_cpu()
{
    tid="$1"

    [ -r "/proc/${tid}/stat" ] || {
        echo NA
        return
    }

    line="$(cat "/proc/${tid}/stat" 2>/dev/null)" || {
        echo NA
        return
    }

    rest="${line#*) }"
    echo "${rest}" | awk '{print $37}'
}

build_filter()
{
    old_ifs="${IFS}"
    IFS=','
    set -- ${TARGET_CPUS}
    IFS="${old_ifs}"

    filter=""

    for cpu in "$@"; do
        case "${cpu}" in
            ''|*[!0-9]*)
                die "invalid CPU in TARGET_CPUS=${TARGET_CPUS}"
                ;;
        esac

        if [ -z "${filter}" ]; then
            filter="target_cpu==${cpu}"
        else
            filter="${filter} || target_cpu==${cpu}"
        fi
    done

    [ -n "${filter}" ] || die "empty TARGET_CPUS"
    echo "${filter}"
}

wait_for_traffic()
{
    echo "Waiting for ${PHY_IF} TX >= ${START_PPS} packets/s ..."
    echo "Start the Android iperf3 test now."

    prev="$(read_net_stat "${PHY_IF}" tx_packets)"
    waited=0

    while [ "${waited}" -lt "${WAIT_TIMEOUT}" ]; do
        sleep 1
        now="$(read_net_stat "${PHY_IF}" tx_packets)"
        delta=$((now - prev))

        if [ "${delta}" -ge "${START_PPS}" ]; then
            echo "Traffic detected: ${delta} packets/s"
            echo "Warm-up ${WARMUP}s ..."
            sleep "${WARMUP}"
            return
        fi

        prev="${now}"
        waited=$((waited + 1))
    done

    die "no qualifying traffic detected within ${WAIT_TIMEOUT}s"
}

parse_function_call_ipi()
{
    src_file="$1"
    out_file="$2"

    awk -v ncpu="${NCPU}" '
        $1 ~ /^IPI[0-9]+:$/ &&
        $0 ~ /Function call interrupts/ {
            for (i = 0; i < ncpu; i++)
                print i "," $(i + 2)
            found = 1
            exit
        }

        END {
            if (!found) {
                for (i = 0; i < ncpu; i++)
                    print i ",0"
            }
        }
    ' "${src_file}" > "${out_file}"
}

snapshot()
{
    prefix="$1"
    out_dir="$2"

    date +%s > "${out_dir}/${prefix}_epoch.txt"
    cat /proc/interrupts > "${out_dir}/${prefix}_interrupts.txt"

    parse_function_call_ipi \
        "${out_dir}/${prefix}_interrupts.txt" \
        "${out_dir}/${prefix}_function_call_ipi.csv"

    read_net_stat "${PHY_IF}" tx_packets \
        > "${out_dir}/${prefix}_eth_tx_packets.txt"
    read_net_stat "${PHY_IF}" tx_bytes \
        > "${out_dir}/${prefix}_eth_tx_bytes.txt"
    read_net_stat "${TAP_IF}" rx_packets \
        > "${out_dir}/${prefix}_tap_rx_packets.txt"
    read_net_stat "${TAP_IF}" rx_bytes \
        > "${out_dir}/${prefix}_tap_rx_bytes.txt"

    if [ -n "${BACKEND_TID:-}" ] &&
       [ -r "/proc/${BACKEND_TID}/status" ]; then
        {
            echo "tid=${BACKEND_TID}"
            echo "comm=$(cat "/proc/${BACKEND_TID}/comm")"
            echo "affinity=$(
                awk '/^Cpus_allowed_list:/ {print $2}' \
                    "/proc/${BACKEND_TID}/status"
            )"
            echo "last_cpu=$(read_backend_last_cpu "${BACKEND_TID}")"
        } > "${out_dir}/${prefix}_backend.txt"
    fi
}

save_trace_stats()
{
    out_file="$1"

    : > "${out_file}"

    for f in "${TR}"/per_cpu/cpu*/stats; do
        [ -r "${f}" ] || continue
        echo "===== ${f} =====" >> "${out_file}"
        cat "${f}" >> "${out_file}"
    done
}

parse_trace()
{
    trace_file="$1"
    out_dir="$2"

    events="${out_dir}/waking_events.csv"

    echo "source_cpu,target_cpu,target_comm,target_pid,source_comm,source_pid,remote" \
        > "${events}"

    # 常见ftrace行：
    # source-123 [000] .... timestamp: sched_waking:
    #     comm=vhost-735 pid=1155 prio=120 target_cpu=001
    #
    # source_comm中包含"-"时，sed的贪婪匹配会取最后一个"-<pid>"。
    sed -n '
        s/^[[:space:]]*\(.*\)-\([0-9][0-9]*\)[[:space:]]*\[\([0-9][0-9]*\)\].*sched_waking: comm=\([^ ]*\) pid=\([0-9][0-9]*\) prio=[^ ]* target_cpu=\([0-9][0-9]*\).*$/\3,\6,\4,\5,\1,\2/p
    ' "${trace_file}" |
    awk '
        BEGIN {
            FS = OFS = ","
        }

        {
            src = $1 + 0
            dst = $2 + 0
            remote = (src != dst) ? 1 : 0

            print src, dst, $3, $4, $5, $6, remote
        }
    ' >> "${events}"

    parsed_count=$(( $(wc -l < "${events}") - 1 ))

    if [ "${parsed_count}" -le 0 ]; then
        echo "WARNING: no sched_waking line was parsed." >&2
        echo "Inspect ${trace_file} manually." >&2
    fi

    {
        echo "count,remote_count,target_cpu,target_comm,target_pid"

        awk '
            BEGIN {
                FS = OFS = ","
            }

            NR == 1 {
                next
            }

            {
                key = $2 SUBSEP $3 SUBSEP $4
                total[key]++
                remote[key] += $7
            }

            END {
                for (key in total) {
                    split(key, a, SUBSEP)
                    print total[key],
                          remote[key],
                          a[1],
                          a[2],
                          a[3]
                }
            }
        ' "${events}" |
        sort -t, -k1,1nr
    } > "${out_dir}/woken_task_summary.csv"

    {
        echo "count,source_cpu,target_cpu,source_comm,source_pid,target_comm,target_pid"

        awk '
            BEGIN {
                FS = OFS = ","
            }

            NR == 1 {
                next
            }

            $7 == 1 {
                key = $1 SUBSEP $2 SUBSEP $5 SUBSEP $6 SUBSEP $3 SUBSEP $4
                count[key]++
            }

            END {
                for (key in count) {
                    split(key, a, SUBSEP)
                    print count[key],
                          a[1],
                          a[2],
                          a[3],
                          a[4],
                          a[5],
                          a[6]
                }
            }
        ' "${events}" |
        sort -t, -k1,1nr
    } > "${out_dir}/remote_source_target_task_summary.csv"

    {
        echo "count,source_cpu,target_cpu"

        awk '
            BEGIN {
                FS = OFS = ","
            }

            NR == 1 {
                next
            }

            $7 == 1 {
                key = $1 SUBSEP $2
                count[key]++
            }

            END {
                for (key in count) {
                    split(key, a, SUBSEP)
                    print count[key], a[1], a[2]
                }
            }
        ' "${events}" |
        sort -t, -k1,1nr
    } > "${out_dir}/remote_source_target_cpu_summary.csv"

    {
        echo "target_cpu,total_waking,remote_waking,local_waking"

        awk '
            BEGIN {
                FS = OFS = ","
            }

            NR == 1 {
                next
            }

            {
                total[$2]++
                if ($7 == 1)
                    remote[$2]++
                else
                    local[$2]++
            }

            END {
                for (cpu in total)
                    print cpu,
                          total[cpu],
                          remote[cpu] + 0,
                          local[cpu] + 0
            }
        ' "${events}" |
        sort -t, -k1,1n
    } > "${out_dir}/target_cpu_waking_summary.csv"
}

generate_ipi_delta()
{
    out_dir="$1"

    before="${out_dir}/before_function_call_ipi.csv"
    after="${out_dir}/after_function_call_ipi.csv"

    echo "cpu,function_call_ipi_delta" \
        > "${out_dir}/function_call_ipi_delta.csv"

    awk '
        BEGIN {
            FS = OFS = ","
        }

        NR == FNR {
            before[$1] = $2
            next
        }

        {
            print $1, $2 - before[$1]
        }
    ' "${before}" "${after}" \
        >> "${out_dir}/function_call_ipi_delta.csv"
}

generate_result()
{
    out_dir="$1"

    before_epoch="$(cat "${out_dir}/before_epoch.txt")"
    after_epoch="$(cat "${out_dir}/after_epoch.txt")"
    duration=$((after_epoch - before_epoch))

    [ "${duration}" -gt 0 ] || duration=1

    eth_before="$(cat "${out_dir}/before_eth_tx_packets.txt")"
    eth_after="$(cat "${out_dir}/after_eth_tx_packets.txt")"
    eth_delta=$((eth_after - eth_before))

    tap_before="$(cat "${out_dir}/before_tap_rx_packets.txt")"
    tap_after="$(cat "${out_dir}/after_tap_rx_packets.txt")"
    tap_delta=$((tap_after - tap_before))

    waking_total=$(( $(wc -l < "${out_dir}/waking_events.csv") - 1 ))
    remote_total="$(
        awk -F, '
            NR > 1 {
                total += $7
            }

            END {
                print total + 0
            }
        ' "${out_dir}/waking_events.csv"
    )"

    ipi_total="$(
        awk -F, '
            NR > 1 {
                total += $2
            }

            END {
                print total + 0
            }
        ' "${out_dir}/function_call_ipi_delta.csv"
    )"

    if [ "${eth_delta}" -gt 0 ]; then
        remote_per_10k="$(
            awk -v r="${remote_total}" -v p="${eth_delta}" \
                'BEGIN {printf "%.6f", r * 10000 / p}'
        )"
        ipi_per_10k="$(
            awk -v r="${ipi_total}" -v p="${eth_delta}" \
                'BEGIN {printf "%.6f", r * 10000 / p}'
        )"
    else
        remote_per_10k=0
        ipi_per_10k=0
    fi

    {
        echo "capture_seconds=${duration}"
        echo "target_cpus=${TARGET_CPUS}"
        echo "eth_tx_packets_delta=${eth_delta}"
        echo "tap_rx_packets_delta=${tap_delta}"
        echo "sched_waking_total=${waking_total}"
        echo "sched_waking_remote_total=${remote_total}"
        echo "function_call_ipi_total=${ipi_total}"
        echo "remote_waking_per_10k_eth_tx=${remote_per_10k}"
        echo "function_call_ipi_per_10k_eth_tx=${ipi_per_10k}"
        echo

        echo "===== Function-call IPI delta by CPU ====="
        cat "${out_dir}/function_call_ipi_delta.csv"
        echo

        echo "===== Waking summary by target CPU ====="
        cat "${out_dir}/target_cpu_waking_summary.csv"
        echo

        echo "===== Top woken tasks ====="
        head -31 "${out_dir}/woken_task_summary.csv"
        echo

        echo "===== Top remote source -> target task pairs ====="
        head -31 "${out_dir}/remote_source_target_task_summary.csv"
        echo

        echo "===== Top remote source CPU -> target CPU pairs ====="
        head -31 "${out_dir}/remote_source_target_cpu_summary.csv"
        echo

        echo "Interpretation:"
        echo "  1. If remote waking to CPU1/CPU3 is close to their IPI1 delta,"
        echo "     remote task wakeup is a strong IPI1 source candidate."
        echo "  2. If IPI1 is much larger than remote waking,"
        echo "     most IPI1 comes from other SMP call-function callbacks."
        echo "  3. One IPI may batch multiple wakeups; counts need not be equal."
    } > "${out_dir}/result.txt"

    cat "${out_dir}/result.txt"
}

capture_case()
{
    label="$1"
    seconds="$2"

    case "${seconds}" in
        ''|*[!0-9]*)
            die "capture seconds must be a positive integer"
            ;;
    esac

    [ "${seconds}" -gt 0 ] ||
        die "capture seconds must be > 0"

    event_dir="${TR}/events/sched/sched_waking"

    [ -e "${event_dir}/enable" ] ||
        die "sched:sched_waking is unavailable"

    filter="$(build_filter)"

    mkdir -p "${OUT_BASE}" ||
        die "failed to create ${OUT_BASE}"

    timestamp="$(date +%Y%m%d_%H%M%S)"
    out_dir="${OUT_BASE}/${label}_${timestamp}"

    mkdir -p "${out_dir}" ||
        die "failed to create ${out_dir}"

    {
        echo "timestamp=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "phy_if=${PHY_IF}"
        echo "tap_if=${TAP_IF}"
        echo "target_cpus=${TARGET_CPUS}"
        echo "event_filter=${filter}"
        echo "capture_seconds=${seconds}"
        echo "warmup_seconds=${WARMUP}"
        echo "buffer_kb=${BUFFER_KB}"
        echo

        if [ -n "${BACKEND_TID:-}" ]; then
            echo "backend_tid=${BACKEND_TID}"
            if [ -r "/proc/${BACKEND_TID}/comm" ]; then
                echo "backend_comm=$(cat "/proc/${BACKEND_TID}/comm")"
                echo "backend_affinity=$(
                    awk '/^Cpus_allowed_list:/ {print $2}' \
                        "/proc/${BACKEND_TID}/status"
                )"
                echo "backend_last_cpu=$(read_backend_last_cpu "${BACKEND_TID}")"
            fi
        fi
    } > "${out_dir}/case_config.txt"

    wait_for_traffic

    echo 0 > "${TR}/tracing_on"
    echo 0 > "${event_dir}/enable"
    echo nop > "${TR}/current_tracer"
    echo > "${TR}/trace"

    if [ -w "${TR}/buffer_size_kb" ]; then
        echo "${BUFFER_KB}" > "${TR}/buffer_size_kb" 2>/dev/null || true
    fi

    if [ -w "${TR}/trace_clock" ]; then
        if grep -qw global "${TR}/trace_clock"; then
            echo global > "${TR}/trace_clock"
        elif grep -qw mono "${TR}/trace_clock"; then
            echo mono > "${TR}/trace_clock"
        fi
    fi

    echo "${filter}" > "${event_dir}/filter" ||
        die "failed to install sched_waking filter: ${filter}"

    save_trace_stats "${out_dir}/trace_stats_before.txt"
    snapshot before "${out_dir}"

    echo 1 > "${event_dir}/enable"
    echo 1 > "${TR}/tracing_on"

    sleep "${seconds}"

    echo 0 > "${TR}/tracing_on"
    echo 0 > "${event_dir}/enable"

    snapshot after "${out_dir}"
    save_trace_stats "${out_dir}/trace_stats_after.txt"

    cat "${TR}/trace" > "${out_dir}/trace.txt"

    echo 0 > "${event_dir}/filter" 2>/dev/null || true

    parse_trace "${out_dir}/trace.txt" "${out_dir}"
    generate_ipi_delta "${out_dir}"
    generate_result "${out_dir}"

    echo
    echo "OUTPUT_DIR=${out_dir}"
}

show_help()
{
    cat <<EOF
Usage:
  $0 capture <label> [seconds]
  $0 help

Example:
  TARGET_CPUS=1,3 BACKEND_TID=1155 \
    $0 capture udp_cross 1

Recommended:
  - Run UDP and TCP with exactly the same affinity and CPU placement.
  - Capture 1 second, repeat at least 3 times for each protocol.
  - Inspect:
      result.txt
      woken_task_summary.csv
      remote_source_target_task_summary.csv
      function_call_ipi_delta.csv
      trace_stats_after.txt
EOF
}

need_root
TR="$(find_tracefs)"
NCPU="$(cpu_count)"

action="${1:-help}"

case "${action}" in
    capture)
        [ "$#" -ge 2 ] && [ "$#" -le 3 ] ||
            die "usage: $0 capture <label> [seconds]"
        capture_case "$2" "${3:-1}"
        ;;

    help|-h|--help)
        show_help
        ;;

    *)
        die "unknown action: ${action}"
        ;;
esac

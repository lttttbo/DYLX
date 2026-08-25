#!/bin/sh
#
# ipi_count_compare.sh
#
# 目的：
#   只比较两种网络后端亲和性配置下，ServerVM Linux 可见的 IPI
#   是否触发更多。不测 IPI 延迟，不修改亲和性。
#
# 推荐两组：
#   same_cpu : 后端线程 CPU0，真正 eth0 IRQ/完成上下文 CPU0
#   cross_cpu: 后端线程 CPU0，真正 eth0 IRQ/完成上下文 CPU1
#
# 用法：
#   1) 采集一组：
#      BACKEND_TID=<tid> ETH_IRQ=<irq> \
#      sh ipi_count_compare.sh capture <label> [capture_seconds]
#
#      脚本会等待 eth0 TX 流量超过 START_PPS，然后自动采集。
#
#   2) 比较两组：
#      sh ipi_count_compare.sh compare <case_dir_A> <case_dir_B>
#
#   3) 查看帮助：
#      sh ipi_count_compare.sh help
#
# 环境变量：
#   PHY_IF=eth0
#   TAP_IF=tap1
#   OUT_BASE=/tmp/ipi_count_compare
#   START_PPS=10000
#   WAIT_TIMEOUT=120
#   BACKEND_TID=<vhost或DSM TX TID，可选但强烈建议>
#   ETH_IRQ=<当前真正eth0 IRQ，可选但强烈建议>
#
# 说明：
#   - 本脚本只统计 ServerVM Linux /proc/interrupts 中的 IPI。
#   - Xvisor 自身发送、但未暴露给 ServerVM Linux 的 IPI 不在统计范围内。
#   - 为避免“高吞吐组包更多，所以IPI绝对数自然更多”的误判，
#     脚本同时输出 IPI/s、IPI/1万eth0 TX包、IPI/1万tap1 RX包。
#

set -u

PHY_IF="${PHY_IF:-eth0}"
TAP_IF="${TAP_IF:-tap1}"
OUT_BASE="${OUT_BASE:-/tmp/ipi_count_compare}"
START_PPS="${START_PPS:-10000}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-120}"

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

need_root()
{
    uid="$(id -u 2>/dev/null || echo 1)"
    [ "${uid}" = "0" ] || die "please run as root"
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

    if [ ! -r "/proc/${tid}/stat" ]; then
        echo "NA"
        return
    fi

    stat_line="$(cat "/proc/${tid}/stat" 2>/dev/null)" || {
        echo "NA"
        return
    }

    rest="${stat_line#*) }"
    # 原始 /proc/<pid>/stat 第39字段 processor；
    # 去除 pid 和 (comm) 后为第37字段。
    echo "${rest}" | awk '{print $37}'
}

save_case_configuration()
{
    out_dir="$1"
    {
        echo "timestamp=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "phy_if=${PHY_IF}"
        echo "tap_if=${TAP_IF}"
        echo "cpu_count=${NCPU}"
        echo "start_pps=${START_PPS}"
        echo "wait_timeout=${WAIT_TIMEOUT}"
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
            else
                echo "backend_status=NOT_FOUND"
            fi
        else
            echo "backend_tid=NOT_SET"
        fi

        echo

        if [ -n "${ETH_IRQ:-}" ]; then
            echo "eth_irq=${ETH_IRQ}"
            if [ -d "/proc/irq/${ETH_IRQ}" ]; then
                echo "eth_irq_requested=$(
                    cat "/proc/irq/${ETH_IRQ}/smp_affinity_list" 2>/dev/null
                )"
                echo "eth_irq_effective=$(
                    cat "/proc/irq/${ETH_IRQ}/effective_affinity_list" 2>/dev/null
                )"
                echo "eth_irq_line:"
                grep -E "^[[:space:]]*${ETH_IRQ}:" /proc/interrupts || true
            else
                echo "eth_irq_status=NOT_FOUND"
            fi
        else
            echo "eth_irq=NOT_SET"
        fi

        echo
        echo "IPI rows:"
        grep -E '^[[:space:]]*IPI[0-9]+:' /proc/interrupts || true

        echo
        echo "Network-related IRQ candidates:"
        grep -Ei "${PHY_IF}|ethernet|gmac|dwmac|eqos|stmmac" \
            /proc/interrupts || true
    } > "${out_dir}/case_config.txt" 2>&1
}

parse_ipi_snapshot()
{
    interrupt_file="$1"
    output_file="$2"

    awk -v ncpu="${NCPU}" '
        BEGIN {
            OFS = "\t"
        }

        $1 ~ /^IPI[0-9]+:$/ {
            key = $1
            sub(/:$/, "", key)

            total = 0
            line = key

            for (i = 0; i < ncpu; i++) {
                value = $(i + 2) + 0
                total += value
                line = line OFS value
            }

            desc = ""
            for (i = ncpu + 2; i <= NF; i++) {
                if (desc != "")
                    desc = desc " "
                desc = desc $i
            }

            print line, total, desc
        }
    ' "${interrupt_file}" > "${output_file}"
}

write_snapshot()
{
    prefix="$1"
    out_dir="$2"

    date +%s > "${out_dir}/${prefix}_epoch.txt"
    cat /proc/interrupts > "${out_dir}/${prefix}_interrupts.txt"
    cat /proc/softirqs > "${out_dir}/${prefix}_softirqs.txt" 2>/dev/null || true

    read_net_stat "${PHY_IF}" tx_packets \
        > "${out_dir}/${prefix}_eth_tx_packets.txt"
    read_net_stat "${PHY_IF}" tx_bytes \
        > "${out_dir}/${prefix}_eth_tx_bytes.txt"
    read_net_stat "${TAP_IF}" rx_packets \
        > "${out_dir}/${prefix}_tap_rx_packets.txt"
    read_net_stat "${TAP_IF}" rx_bytes \
        > "${out_dir}/${prefix}_tap_rx_bytes.txt"

    parse_ipi_snapshot \
        "${out_dir}/${prefix}_interrupts.txt" \
        "${out_dir}/${prefix}_ipi.tsv"

    if [ -n "${BACKEND_TID:-}" ] &&
       [ -r "/proc/${BACKEND_TID}/status" ]; then
        {
            echo "affinity=$(
                awk '/^Cpus_allowed_list:/ {print $2}' \
                    "/proc/${BACKEND_TID}/status"
            )"
            echo "last_cpu=$(read_backend_last_cpu "${BACKEND_TID}")"
        } > "${out_dir}/${prefix}_backend_state.txt"
    fi

    if [ -n "${ETH_IRQ:-}" ] &&
       [ -d "/proc/irq/${ETH_IRQ}" ]; then
        {
            echo "requested=$(
                cat "/proc/irq/${ETH_IRQ}/smp_affinity_list" 2>/dev/null
            )"
            echo "effective=$(
                cat "/proc/irq/${ETH_IRQ}/effective_affinity_list" 2>/dev/null
            )"
            grep -E "^[[:space:]]*${ETH_IRQ}:" /proc/interrupts || true
        } > "${out_dir}/${prefix}_eth_irq_state.txt"
    fi
}

wait_for_test_traffic()
{
    echo "Waiting for ${PHY_IF} TX traffic >= ${START_PPS} packets/s ..."
    echo "Start the Android iperf3 test now."

    prev="$(read_net_stat "${PHY_IF}" tx_packets)"
    waited=0

    while [ "${waited}" -lt "${WAIT_TIMEOUT}" ]; do
        sleep 1
        now="$(read_net_stat "${PHY_IF}" tx_packets)"
        delta=$((now - prev))

        if [ "${delta}" -ge "${START_PPS}" ]; then
            echo "Traffic detected: ${delta} packets/s"
            return 0
        fi

        prev="${now}"
        waited=$((waited + 1))
    done

    die "no qualifying ${PHY_IF} TX traffic detected within ${WAIT_TIMEOUT}s"
}

generate_delta()
{
    out_dir="$1"

    before_epoch="$(cat "${out_dir}/before_epoch.txt")"
    after_epoch="$(cat "${out_dir}/after_epoch.txt")"
    duration=$((after_epoch - before_epoch))

    [ "${duration}" -gt 0 ] || die "invalid capture duration"

    eth_tx_before="$(cat "${out_dir}/before_eth_tx_packets.txt")"
    eth_tx_after="$(cat "${out_dir}/after_eth_tx_packets.txt")"
    tap_rx_before="$(cat "${out_dir}/before_tap_rx_packets.txt")"
    tap_rx_after="$(cat "${out_dir}/after_tap_rx_packets.txt")"

    eth_tx_delta=$((eth_tx_after - eth_tx_before))
    tap_rx_delta=$((tap_rx_after - tap_rx_before))

    {
        echo "duration_seconds=${duration}"
        echo "eth_tx_packets_delta=${eth_tx_delta}"
        echo "tap_rx_packets_delta=${tap_rx_delta}"
        echo "eth_tx_pps=$(
            awk -v p="${eth_tx_delta}" -v s="${duration}" \
                'BEGIN {printf "%.3f", p / s}'
        )"
        echo "tap_rx_pps=$(
            awk -v p="${tap_rx_delta}" -v s="${duration}" \
                'BEGIN {printf "%.3f", p / s}'
        )"
    } > "${out_dir}/workload_summary.txt"

    header="ipi,description"
    i=0
    while [ "${i}" -lt "${NCPU}" ]; do
        header="${header},cpu${i}_delta"
        i=$((i + 1))
    done
    header="${header},total_delta,per_second,per_10k_eth_tx_packets,per_10k_tap_rx_packets"

    echo "${header}" > "${out_dir}/ipi_delta.csv"

    awk \
        -v ncpu="${NCPU}" \
        -v duration="${duration}" \
        -v eth_packets="${eth_tx_delta}" \
        -v tap_packets="${tap_rx_delta}" '
        BEGIN {
            FS = "\t"
            OFS = ","
        }

        NR == FNR {
            key = $1
            for (i = 0; i < ncpu; i++)
                before[key, i] = $(i + 2) + 0
            next
        }

        {
            key = $1
            total_delta = 0
            desc = $(ncpu + 3)

            line = key "," desc

            for (i = 0; i < ncpu; i++) {
                delta = ($(i + 2) + 0) - before[key, i]
                total_delta += delta
                line = line "," delta
            }

            per_sec = total_delta / duration

            if (eth_packets > 0)
                per_10k_eth = total_delta * 10000 / eth_packets
            else
                per_10k_eth = 0

            if (tap_packets > 0)
                per_10k_tap = total_delta * 10000 / tap_packets
            else
                per_10k_tap = 0

            printf "%s,%d,%.6f,%.6f,%.6f\n",
                   line,
                   total_delta,
                   per_sec,
                   per_10k_eth,
                   per_10k_tap

            all_total += total_delta
            all_per_sec += per_sec
            all_per_10k_eth += per_10k_eth
            all_per_10k_tap += per_10k_tap
        }

        END {
            line = "ALL_IPI,All Linux-visible IPI types"

            for (i = 0; i < ncpu; i++)
                line = line ","

            printf "%s,%d,%.6f,%.6f,%.6f\n",
                   line,
                   all_total,
                   all_per_sec,
                   all_per_10k_eth,
                   all_per_10k_tap
        }
    ' \
        "${out_dir}/before_ipi.tsv" \
        "${out_dir}/after_ipi.tsv" \
        >> "${out_dir}/ipi_delta.csv"

    {
        echo "Case directory: ${out_dir}"
        echo
        cat "${out_dir}/workload_summary.txt"
        echo
        echo "IPI summary:"
        cat "${out_dir}/ipi_delta.csv"
    } > "${out_dir}/result.txt"

    cat "${out_dir}/result.txt"
}

capture_case()
{
    label="$1"
    capture_seconds="$2"

    mkdir -p "${OUT_BASE}"

    timestamp="$(date +%Y%m%d_%H%M%S)"
    out_dir="${OUT_BASE}/${label}_${timestamp}"
    mkdir -p "${out_dir}" || die "failed to create ${out_dir}"

    save_case_configuration "${out_dir}"

    wait_for_test_traffic

    echo "Capturing Linux-visible IPI for ${capture_seconds}s ..."
    write_snapshot before "${out_dir}"
    sleep "${capture_seconds}"
    write_snapshot after "${out_dir}"

    generate_delta "${out_dir}"

    echo
    echo "OUTPUT_DIR=${out_dir}"
}

compare_cases()
{
    case_a="$1"
    case_b="$2"

    [ -r "${case_a}/ipi_delta.csv" ] ||
        die "${case_a}/ipi_delta.csv not found"
    [ -r "${case_b}/ipi_delta.csv" ] ||
        die "${case_b}/ipi_delta.csv not found"

    timestamp="$(date +%Y%m%d_%H%M%S)"
    out_dir="${OUT_BASE}/compare_${timestamp}"
    mkdir -p "${out_dir}" || die "failed to create ${out_dir}"

    # 从右侧固定提取：
    # NF-3 total_delta
    # NF-2 per_second
    # NF-1 per_10k_eth
    # NF   per_10k_tap
    awk '
        BEGIN {
            FS = ","
            OFS = ","
        }

        NR == FNR {
            key = $1
            if (FNR == 1)
                next

            desc[key] = $2
            a_total[key] = $(NF - 3)
            a_sec[key] = $(NF - 2)
            a_eth[key] = $(NF - 1)
            a_tap[key] = $NF
            order[++n] = key
            next
        }

        FNR == 1 {
            next
        }

        {
            key = $1
            b_total[key] = $(NF - 3)
            b_sec[key] = $(NF - 2)
            b_eth[key] = $(NF - 1)
            b_tap[key] = $NF
            if (!(key in desc))
                desc[key] = $2
        }

        END {
            print "ipi",
                  "description",
                  "caseA_total",
                  "caseA_per_second",
                  "caseA_per_10k_eth",
                  "caseB_total",
                  "caseB_per_second",
                  "caseB_per_10k_eth",
                  "B_to_A_ratio_per_10k_eth"

            for (i = 1; i <= n; i++) {
                key = order[i]

                if (a_eth[key] > 0)
                    ratio = b_eth[key] / a_eth[key]
                else
                    ratio = 0

                printf "%s,%s,%s,%s,%s,%s,%s,%s,%.6f\n",
                       key,
                       desc[key],
                       a_total[key],
                       a_sec[key],
                       a_eth[key],
                       b_total[key],
                       b_sec[key],
                       b_eth[key],
                       ratio
            }
        }
    ' \
        "${case_a}/ipi_delta.csv" \
        "${case_b}/ipi_delta.csv" \
        > "${out_dir}/compare.csv"

    {
        echo "caseA=${case_a}"
        echo "caseB=${case_b}"
        echo
        echo "Interpretation:"
        echo "  B_to_A_ratio_per_10k_eth > 1:"
        echo "      caseB triggers more Linux-visible IPI per 10,000 eth0 TX packets."
        echo "  Values near 1:"
        echo "      no meaningful increase after normalizing by packet count."
        echo
        cat "${out_dir}/compare.csv"
    } > "${out_dir}/result.txt"

    cat "${out_dir}/result.txt"
    echo
    echo "OUTPUT_DIR=${out_dir}"
}

show_help()
{
    cat <<EOF
Usage:
  $0 capture <label> [capture_seconds]
  $0 compare <case_dir_A> <case_dir_B>
  $0 help

Recommended workflow:

  # 1. Configure same-core:
  #    backend CPU0, real eth0 IRQ/completion CPU0
  BACKEND_TID=<tid> ETH_IRQ=<irq> \
  $0 capture same_1 50

  # Start a 60-second Android iperf3 test after the script says:
  # "Start the Android iperf3 test now."

  # 2. Configure cross-core:
  #    backend CPU0, real eth0 IRQ/completion CPU1
  BACKEND_TID=<tid> ETH_IRQ=<irq> \
  $0 capture cross_1 50

  # 3. Compare normalized IPI counts:
  $0 compare \
      /tmp/ipi_count_compare/same_1_<timestamp> \
      /tmp/ipi_count_compare/cross_1_<timestamp>

Environment defaults:
  PHY_IF=${PHY_IF}
  TAP_IF=${TAP_IF}
  OUT_BASE=${OUT_BASE}
  START_PPS=${START_PPS}
  WAIT_TIMEOUT=${WAIT_TIMEOUT}
EOF
}

need_root
NCPU="$(cpu_count)"
[ "${NCPU}" -gt 0 ] 2>/dev/null || die "failed to determine CPU count"

action="${1:-help}"

case "${action}" in
    capture)
        [ "$#" -ge 2 ] && [ "$#" -le 3 ] ||
            die "usage: $0 capture <label> [capture_seconds]"
        label="$2"
        capture_seconds="${3:-50}"
        capture_case "${label}" "${capture_seconds}"
        ;;

    compare)
        [ "$#" -eq 3 ] ||
            die "usage: $0 compare <case_dir_A> <case_dir_B>"
        compare_cases "$2" "$3"
        ;;

    help|-h|--help)
        show_help
        ;;

    *)
        die "unknown action: ${action}"
        ;;
esac

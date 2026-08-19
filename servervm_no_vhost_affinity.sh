#!/bin/sh
#
# ServerVM no-vhost affinity test helper
#
# Purpose:
#   When virtio-net runs WITHOUT ",vhost", locate DSM's userspace vtnet TX
#   thread, bind it to a selected ServerVM CPU, bind eth0 IRQ to a selected
#   ServerVM CPU, and monitor the actual execution/traffic counters.
#
# Usage:
#   sh servervm_no_vhost_affinity.sh status
#   sh servervm_no_vhost_affinity.sh set <tx_cpu> <irq_cpu>
#   sh servervm_no_vhost_affinity.sh monitor <output.csv> [seconds]
#   sh servervm_no_vhost_affinity.sh restore
#
# Environment overrides:
#   IRQ=134
#   TAP_IF=tap1
#   PHY_IF=eth0
#   DSM_MATCH=user-android
#
# Examples:
#   sh servervm_no_vhost_affinity.sh set 0 0
#   sh servervm_no_vhost_affinity.sh monitor /tmp/tx0_irq0.csv 230
#
#   sh servervm_no_vhost_affinity.sh set 0 5
#   sh servervm_no_vhost_affinity.sh monitor /tmp/tx0_irq5.csv 230
#

set -u

IRQ="${IRQ:-134}"
TAP_IF="${TAP_IF:-tap1}"
PHY_IF="${PHY_IF:-eth0}"
DSM_MATCH="${DSM_MATCH:-user-android}"
BACKUP_FILE="/tmp/no_vhost_affinity_backup.txt"

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

find_dsm_pid()
{
    ps -eo pid,args 2>/dev/null |
        awk -v pat="${DSM_MATCH}" '
            $0 ~ /[d]sm/ && $0 ~ pat {
                print $1
                exit
            }
        '
}

find_tx_tid()
{
    pid="$1"

    for task_dir in "/proc/${pid}/task/"*; do
        [ -d "${task_dir}" ] || continue

        tid="${task_dir##*/}"
        comm="$(cat "${task_dir}/comm" 2>/dev/null)"

        case "${comm}" in
            vtnet-*tx*)
                echo "${tid}"
                return 0
                ;;
        esac
    done

    return 1
}

get_thread_cpu()
{
    tid="$1"
    stat_line="$(cat "/proc/${tid}/stat" 2>/dev/null)" || {
        echo "NA"
        return
    }

    # Remove "pid (comm) " safely. The remaining first field is original field 3.
    rest="${stat_line#*) }"
    echo "${rest}" | awk '{ print $37 }'
}

get_thread_ticks()
{
    tid="$1"
    stat_line="$(cat "/proc/${tid}/stat" 2>/dev/null)" || {
        echo "NA,NA"
        return
    }

    rest="${stat_line#*) }"
    # Original fields 14 and 15 become fields 12 and 13 after stripping pid/comm.
    echo "${rest}" | awk '{ print $12 "," $13 }'
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

get_irq_counts()
{
    awk -v irq="${IRQ}:" '
        $1 == irq {
            for (i = 2; i <= NF; i++) {
                if ($i !~ /^[0-9]+$/)
                    break

                if (i > 2)
                    printf ";"

                printf "%s", $i
            }
            exit
        }
    ' /proc/interrupts
}

check_no_vhost()
{
    pid="$1"
    cmdline="$(tr '\000' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)"

    echo "DSM command:"
    echo "${cmdline}"

    if echo "${cmdline}" |
       grep -Eq 'virtio-net[^ ]*vhost'; then
        die "DSM virtio-net still contains the vhost option"
    fi

    echo "Confirmed: virtio-net is running without vhost."
}

show_status()
{
    pid="$(find_dsm_pid)"
    [ -n "${pid}" ] || die "DSM process matching '${DSM_MATCH}' was not found"

    tx_tid="$(find_tx_tid "${pid}")" ||
        die "vtnet TX thread was not found under DSM PID ${pid}"

    check_no_vhost "${pid}"

    echo
    echo "DSM PID=${pid}"
    echo "TX TID=${tx_tid}"
    echo "TX comm=$(cat "/proc/${tx_tid}/comm")"

    printf "TX requested affinity: "
    awk '/^Cpus_allowed_list:/ { print $2 }' "/proc/${tx_tid}/status"

    printf "TX current CPU: "
    get_thread_cpu "${tx_tid}"

    printf "IRQ ${IRQ} requested affinity: "
    cat "/proc/irq/${IRQ}/smp_affinity_list" 2>/dev/null || echo "N/A"

    printf "IRQ ${IRQ} effective affinity: "
    cat "/proc/irq/${IRQ}/effective_affinity_list" 2>/dev/null || echo "N/A"

    echo
    grep -E "^[[:space:]]*${IRQ}:" /proc/interrupts || true

    echo
    ps -eo pid,tid,psr,pcpu,comm,args 2>/dev/null |
        awk -v tid="${tx_tid}" '
            NR == 1 || $2 == tid
        '
}

save_backup_once()
{
    pid="$1"
    tid="$2"

    if [ -e "${BACKUP_FILE}" ]; then
        return
    fi

    tx_affinity="$(
        awk '/^Cpus_allowed_list:/ { print $2 }' "/proc/${tid}/status"
    )"
    irq_affinity="$(
        cat "/proc/irq/${IRQ}/smp_affinity_list" 2>/dev/null
    )"

    irqbalance_state="inactive"
    if command -v systemctl >/dev/null 2>&1 &&
       systemctl is-active --quiet irqbalance 2>/dev/null; then
        irqbalance_state="active"
    fi

    {
        echo "DSM_PID=${pid}"
        echo "TX_TID=${tid}"
        echo "TX_AFFINITY=${tx_affinity}"
        echo "IRQ=${IRQ}"
        echo "IRQ_AFFINITY=${irq_affinity}"
        echo "IRQBALANCE_STATE=${irqbalance_state}"
    } > "${BACKUP_FILE}"

    echo "Original affinity saved to ${BACKUP_FILE}"
}

set_affinity()
{
    tx_cpu="$1"
    irq_cpu="$2"

    pid="$(find_dsm_pid)"
    [ -n "${pid}" ] || die "DSM process matching '${DSM_MATCH}' was not found"

    tx_tid="$(find_tx_tid "${pid}")" ||
        die "vtnet TX thread was not found under DSM PID ${pid}"

    check_no_vhost "${pid}"
    save_backup_once "${pid}" "${tx_tid}"

    if command -v systemctl >/dev/null 2>&1 &&
       systemctl is-active --quiet irqbalance 2>/dev/null; then
        echo "Stopping irqbalance for the A/B test..."
        systemctl stop irqbalance || die "failed to stop irqbalance"
    fi

    echo "Binding DSM TX TID ${tx_tid} to ServerVM CPU${tx_cpu}..."
    taskset -pc "${tx_cpu}" "${tx_tid}" ||
        die "failed to bind TX thread"

    echo "Binding eth0 IRQ ${IRQ} to ServerVM CPU${irq_cpu}..."
    echo "${irq_cpu}" > "/proc/irq/${IRQ}/smp_affinity_list" ||
        die "failed to bind IRQ ${IRQ}"

    sleep 1
    show_status
}

monitor_case()
{
    out_file="$1"
    duration="${2:-0}"

    pid="$(find_dsm_pid)"
    [ -n "${pid}" ] || die "DSM process matching '${DSM_MATCH}' was not found"

    tx_tid="$(find_tx_tid "${pid}")" ||
        die "vtnet TX thread was not found under DSM PID ${pid}"

    check_no_vhost "${pid}"

    start_epoch="$(date +%s)"
    end_epoch=0

    if [ "${duration}" -gt 0 ] 2>/dev/null; then
        end_epoch=$((start_epoch + duration))
    fi

    meta_file="${out_file}.meta"

    {
        echo "start_epoch=${start_epoch}"
        echo "duration=${duration}"
        echo "dsm_pid=${pid}"
        echo "tx_tid=${tx_tid}"
        echo "tx_comm=$(cat "/proc/${tx_tid}/comm")"
        echo "tx_affinity=$(
            awk '/^Cpus_allowed_list:/ { print $2 }' "/proc/${tx_tid}/status"
        )"
        echo "irq=${IRQ}"
        echo "irq_requested=$(cat "/proc/irq/${IRQ}/smp_affinity_list")"
        echo "irq_effective=$(
            cat "/proc/irq/${IRQ}/effective_affinity_list" 2>/dev/null
        )"
        echo "tap_if=${TAP_IF}"
        echo "phy_if=${PHY_IF}"
    } > "${meta_file}"

    echo "epoch,tx_actual_cpu,tx_utime_ticks,tx_stime_ticks,irq_counts_by_cpu,tap_rx_bytes,tap_rx_packets,tap_rx_dropped,tap_rx_errors,eth_tx_bytes,eth_tx_packets,eth_tx_dropped,eth_tx_errors,load1" > "${out_file}"

    echo "Monitoring to ${out_file}"
    echo "Metadata: ${meta_file}"

    while :; do
        now="$(date +%s)"

        if [ "${end_epoch}" -gt 0 ] && [ "${now}" -ge "${end_epoch}" ]; then
            break
        fi

        tx_cpu="$(get_thread_cpu "${tx_tid}")"
        ticks="$(get_thread_ticks "${tx_tid}")"
        tx_utime="${ticks%,*}"
        tx_stime="${ticks#*,}"

        irq_counts="$(get_irq_counts)"
        load1="$(awk '{ print $1 }' /proc/loadavg 2>/dev/null)"

        echo "${now},${tx_cpu},${tx_utime},${tx_stime},${irq_counts},$(read_net_stat "${TAP_IF}" rx_bytes),$(read_net_stat "${TAP_IF}" rx_packets),$(read_net_stat "${TAP_IF}" rx_dropped),$(read_net_stat "${TAP_IF}" rx_errors),$(read_net_stat "${PHY_IF}" tx_bytes),$(read_net_stat "${PHY_IF}" tx_packets),$(read_net_stat "${PHY_IF}" tx_dropped),$(read_net_stat "${PHY_IF}" tx_errors),${load1}" >> "${out_file}"

        sleep 1
    done

    echo "Monitor finished: ${out_file}"
}

restore_affinity()
{
    [ -r "${BACKUP_FILE}" ] ||
        die "backup file ${BACKUP_FILE} does not exist"

    # shellcheck disable=SC1090
    . "${BACKUP_FILE}"

    current_pid="$(find_dsm_pid)"
    [ -n "${current_pid}" ] || die "DSM process was not found"

    current_tid="$(find_tx_tid "${current_pid}")" ||
        die "current vtnet TX thread was not found"

    echo "Restoring TX TID ${current_tid} affinity to ${TX_AFFINITY}..."
    taskset -pc "${TX_AFFINITY}" "${current_tid}" ||
        die "failed to restore TX affinity"

    echo "Restoring IRQ ${IRQ} affinity to ${IRQ_AFFINITY}..."
    echo "${IRQ_AFFINITY}" > "/proc/irq/${IRQ}/smp_affinity_list" ||
        die "failed to restore IRQ affinity"

    if [ "${IRQBALANCE_STATE}" = "active" ] &&
       command -v systemctl >/dev/null 2>&1; then
        echo "Restarting irqbalance..."
        systemctl start irqbalance || true
    fi

    rm -f "${BACKUP_FILE}"
    show_status
}

ACTION="${1:-}"

case "${ACTION}" in
    status)
        show_status
        ;;
    set)
        [ "$#" -eq 3 ] || die "usage: $0 set <tx_cpu> <irq_cpu>"
        set_affinity "$2" "$3"
        ;;
    monitor)
        [ "$#" -ge 2 ] || die "usage: $0 monitor <output.csv> [seconds]"
        monitor_case "$2" "${3:-0}"
        ;;
    restore)
        restore_affinity
        ;;
    *)
        cat <<EOF
Usage:
  $0 status
  $0 set <tx_cpu> <irq_cpu>
  $0 monitor <output.csv> [seconds]
  $0 restore
EOF
        exit 1
        ;;
esac

#!/bin/sh
#
# bind_net_backend_irq.sh
#
# 自动识别 Android DSM 的 virtio-net 后端模式：
#   1. 有 vhost：绑定对应的 vhost-* 内核线程和 eth0 IRQ
#   2. 无 vhost：绑定 DSM 的 vtnet-*:*\ tx 用户态线程和 eth0 IRQ
#
# 默认将后端线程和 IRQ 绑定到同一个 CPU；也支持跨核 A/B 测试。
#
# 用法：
#   sh bind_net_backend_irq.sh status
#   sh bind_net_backend_irq.sh set <backend_cpu> [irq_cpu]
#   sh bind_net_backend_irq.sh restore
#
# 示例：
#   # 后端线程与 IRQ 134 都绑定到 ServerVM CPU0
#   sh bind_net_backend_irq.sh set 0
#
#   # 后端线程绑定 CPU0，IRQ 绑定 CPU5，用于跨核对照
#   sh bind_net_backend_irq.sh set 0 5
#
# 可通过环境变量覆盖：
#   IRQ=134
#   PHY_IF=eth0
#   TAP_IF=tap1
#   VM_MATCH=user-android
#   BACKEND_TID_OVERRIDE=<tid>
#

set -u

IRQ="${IRQ:-134}"
PHY_IF="${PHY_IF:-eth0}"
TAP_IF="${TAP_IF:-tap1}"
VM_MATCH="${VM_MATCH:-user-android}"
BACKUP_FILE="${BACKUP_FILE:-/tmp/net_backend_irq_affinity.backup}"

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

need_root()
{
    uid="$(id -u 2>/dev/null)"
    [ "${uid}" = "0" ] || die "please run as root"
}

read_cmdline()
{
    pid="$1"
    tr '\000' ' ' < "/proc/${pid}/cmdline" 2>/dev/null
}

find_dsm_pid()
{
    for proc_dir in /proc/[0-9]*; do
        [ -r "${proc_dir}/cmdline" ] || continue

        pid="${proc_dir##*/}"
        cmdline="$(read_cmdline "${pid}")"
        [ -n "${cmdline}" ] || continue

        case "${cmdline}" in
            *dsm*) ;;
            *) continue ;;
        esac

        case "${cmdline}" in
            *"${VM_MATCH}"*) ;;
            *) continue ;;
        esac

        case "${cmdline}" in
            *virtio-net*) ;;
            *) continue ;;
        esac

        case "${cmdline}" in
            *"tap=${TAP_IF}"*) ;;
            *) continue ;;
        esac

        echo "${pid}"
        return 0
    done

    return 1
}

get_net_arg()
{
    pid="$1"
    cmdline="$(read_cmdline "${pid}")"

    for arg in ${cmdline}; do
        case "${arg}" in
            *,virtio-net,*)
                echo "${arg}"
                return 0
                ;;
        esac
    done

    return 1
}

detect_mode()
{
    pid="$1"
    net_arg="$(get_net_arg "${pid}")" ||
        die "virtio-net argument was not found for DSM PID ${pid}"

    mode="userspace"

    old_ifs="${IFS}"
    IFS=','
    set -- ${net_arg}
    IFS="${old_ifs}"

    for field in "$@"; do
        if [ "${field}" = "vhost" ]; then
            mode="vhost"
            break
        fi
    done

    echo "${mode}"
}

get_thread_cpu()
{
    tid="$1"
    stat_line="$(cat "/proc/${tid}/stat" 2>/dev/null)" || {
        echo "NA"
        return
    }

    # 去掉 pid 和括号中的 comm。原 stat 第39字段 processor
    # 在去掉前两个字段后变成第37字段。
    rest="${stat_line#*) }"
    echo "${rest}" | awk '{ print $37 }'
}

find_userspace_tx_tid()
{
    dsm_pid="$1"
    matches=""

    for task_dir in "/proc/${dsm_pid}/task/"*; do
        [ -d "${task_dir}" ] || continue

        tid="${task_dir##*/}"
        comm="$(cat "${task_dir}/comm" 2>/dev/null)"

        case "${comm}" in
            vtnet-*tx*|vtnet*tx*)
                matches="${matches} ${tid}"
                ;;
        esac
    done

    set -- ${matches}

    if [ "$#" -eq 1 ]; then
        echo "$1"
        return 0
    fi

    if [ "$#" -eq 0 ]; then
        echo "No vtnet TX thread found under DSM PID ${dsm_pid}." >&2
    else
        echo "Multiple vtnet TX threads found:${matches}" >&2
        echo "Set BACKEND_TID_OVERRIDE to the virtio-net TX TID." >&2
    fi

    return 1
}

find_vhost_tid()
{
    dsm_pid="$1"

    dsm_tids=""
    for task_dir in "/proc/${dsm_pid}/task/"*; do
        [ -d "${task_dir}" ] || continue
        dsm_tids="${dsm_tids} ${task_dir##*/}"
    done

    matches=""

    for comm_file in /proc/[0-9]*/comm; do
        [ -r "${comm_file}" ] || continue

        comm="$(cat "${comm_file}" 2>/dev/null)"

        case "${comm}" in
            vhost-*)
                owner_tid="${comm#vhost-}"

                case " ${dsm_tids} " in
                    *" ${owner_tid} "*)
                        tid_path="${comm_file#/proc/}"
                        tid="${tid_path%%/*}"
                        matches="${matches} ${tid}"
                        ;;
                esac
                ;;
        esac
    done

    set -- ${matches}

    if [ "$#" -eq 1 ]; then
        echo "$1"
        return 0
    fi

    # 某些内核的 vhost comm 后缀不便与 DSM task TID对应。
    # 若系统中只有一个 vhost线程，可安全回退到它。
    if [ "$#" -eq 0 ]; then
        all_vhost=""

        for comm_file in /proc/[0-9]*/comm; do
            [ -r "${comm_file}" ] || continue
            comm="$(cat "${comm_file}" 2>/dev/null)"

            case "${comm}" in
                vhost-*)
                    tid_path="${comm_file#/proc/}"
                    all_vhost="${all_vhost} ${tid_path%%/*}"
                    ;;
            esac
        done

        set -- ${all_vhost}

        if [ "$#" -eq 1 ]; then
            echo "$1"
            return 0
        fi

        if [ "$#" -eq 0 ]; then
            echo "No vhost thread found." >&2
        else
            echo "Unable to identify the net vhost thread automatically." >&2
            echo "vhost candidates:${all_vhost}" >&2
            echo "Set BACKEND_TID_OVERRIDE=<tid> and retry." >&2
        fi

        return 1
    fi

    echo "Multiple vhost threads are associated with DSM PID ${dsm_pid}:${matches}" >&2
    echo "Set BACKEND_TID_OVERRIDE to the virtio-net vhost TID." >&2
    return 1
}

find_backend()
{
    dsm_pid="$1"
    mode="$2"

    if [ -n "${BACKEND_TID_OVERRIDE:-}" ]; then
        [ -d "/proc/${BACKEND_TID_OVERRIDE}" ] ||
            die "BACKEND_TID_OVERRIDE ${BACKEND_TID_OVERRIDE} does not exist"

        echo "${BACKEND_TID_OVERRIDE}"
        return 0
    fi

    if [ "${mode}" = "vhost" ]; then
        find_vhost_tid "${dsm_pid}"
    else
        find_userspace_tx_tid "${dsm_pid}"
    fi
}

irqbalance_is_active()
{
    if command -v systemctl >/dev/null 2>&1 &&
       systemctl is-active --quiet irqbalance 2>/dev/null; then
        return 0
    fi

    return 1
}

save_backup_once()
{
    dsm_pid="$1"
    mode="$2"
    backend_tid="$3"

    [ -e "${BACKUP_FILE}" ] && return 0

    backend_affinity="$(
        awk '/^Cpus_allowed_list:/ { print $2 }' \
            "/proc/${backend_tid}/status" 2>/dev/null
    )"

    irq_affinity="$(
        cat "/proc/irq/${IRQ}/smp_affinity_list" 2>/dev/null
    )"

    [ -n "${backend_affinity}" ] ||
        die "failed to read backend affinity"
    [ -n "${irq_affinity}" ] ||
        die "failed to read IRQ ${IRQ} affinity"

    irqbalance_state="inactive"
    if irqbalance_is_active; then
        irqbalance_state="active"
    fi

    {
        echo "SAVED_DSM_PID='${dsm_pid}'"
        echo "SAVED_MODE='${mode}'"
        echo "SAVED_BACKEND_TID='${backend_tid}'"
        echo "SAVED_BACKEND_AFFINITY='${backend_affinity}'"
        echo "SAVED_IRQ='${IRQ}'"
        echo "SAVED_IRQ_AFFINITY='${irq_affinity}'"
        echo "SAVED_IRQBALANCE_STATE='${irqbalance_state}'"
    } > "${BACKUP_FILE}" ||
        die "failed to write ${BACKUP_FILE}"

    echo "Original affinity saved to ${BACKUP_FILE}"
}

show_status()
{
    dsm_pid="$(find_dsm_pid)" ||
        die "DSM process for ${VM_MATCH}, tap=${TAP_IF} was not found"

    mode="$(detect_mode "${dsm_pid}")"
    backend_tid="$(find_backend "${dsm_pid}" "${mode}")" ||
        die "backend thread could not be identified"

    cmdline="$(read_cmdline "${dsm_pid}")"
    net_arg="$(get_net_arg "${dsm_pid}")"
    backend_comm="$(cat "/proc/${backend_tid}/comm" 2>/dev/null)"

    echo "DSM PID:            ${dsm_pid}"
    echo "VM match:           ${VM_MATCH}"
    echo "virtio-net arg:     ${net_arg}"
    echo "backend mode:       ${mode}"
    echo "backend TID:        ${backend_tid}"
    echo "backend comm:       ${backend_comm}"

    printf "backend affinity:   "
    awk '/^Cpus_allowed_list:/ { print $2 }' \
        "/proc/${backend_tid}/status"

    printf "backend last CPU:   "
    get_thread_cpu "${backend_tid}"

    printf "IRQ %s requested:   " "${IRQ}"
    cat "/proc/irq/${IRQ}/smp_affinity_list" 2>/dev/null || echo "N/A"

    printf "IRQ %s effective:   " "${IRQ}"
    cat "/proc/irq/${IRQ}/effective_affinity_list" 2>/dev/null || echo "N/A"

    echo
    grep -E "^[[:space:]]*${IRQ}:" /proc/interrupts || true

    echo
    ps -eLo pid,tid,psr,pcpu,comm,args 2>/dev/null |
        awk -v tid="${backend_tid}" '
            NR == 1 || $2 == tid
        '

    echo
    echo "DSM command:"
    echo "${cmdline}"
}

set_affinity()
{
    backend_cpu="$1"
    irq_cpu="$2"

    dsm_pid="$(find_dsm_pid)" ||
        die "DSM process for ${VM_MATCH}, tap=${TAP_IF} was not found"

    mode="$(detect_mode "${dsm_pid}")"
    backend_tid="$(find_backend "${dsm_pid}" "${mode}")" ||
        die "backend thread could not be identified"

    save_backup_once "${dsm_pid}" "${mode}" "${backend_tid}"

    if irqbalance_is_active; then
        echo "Stopping irqbalance to protect manual IRQ affinity..."
        systemctl stop irqbalance ||
            die "failed to stop irqbalance"
    fi

    echo "Detected mode: ${mode}"

    if [ "${mode}" = "vhost" ]; then
        echo "Binding vhost TID ${backend_tid} to ServerVM CPU${backend_cpu}..."
    else
        echo "Binding DSM TX TID ${backend_tid} to ServerVM CPU${backend_cpu}..."
    fi

    taskset -pc "${backend_cpu}" "${backend_tid}" ||
        die "failed to bind backend TID ${backend_tid}"

    echo "Binding ${PHY_IF} IRQ ${IRQ} to ServerVM CPU${irq_cpu}..."
    echo "${irq_cpu}" > "/proc/irq/${IRQ}/smp_affinity_list" ||
        die "failed to bind IRQ ${IRQ}"

    sleep 1
    echo
    show_status
}

restore_affinity()
{
    [ -r "${BACKUP_FILE}" ] ||
        die "backup file ${BACKUP_FILE} does not exist"

    # shellcheck disable=SC1090
    . "${BACKUP_FILE}"

    if [ -d "/proc/${SAVED_BACKEND_TID}" ]; then
        echo "Restoring backend TID ${SAVED_BACKEND_TID} to ${SAVED_BACKEND_AFFINITY}..."
        taskset -pc "${SAVED_BACKEND_AFFINITY}" "${SAVED_BACKEND_TID}" ||
            die "failed to restore backend affinity"
    else
        echo "WARNING: saved backend TID ${SAVED_BACKEND_TID} no longer exists."
        echo "Backend affinity was not restored."
    fi

    if [ -d "/proc/irq/${SAVED_IRQ}" ]; then
        echo "Restoring IRQ ${SAVED_IRQ} to ${SAVED_IRQ_AFFINITY}..."
        echo "${SAVED_IRQ_AFFINITY}" \
            > "/proc/irq/${SAVED_IRQ}/smp_affinity_list" ||
            die "failed to restore IRQ affinity"
    fi

    if [ "${SAVED_IRQBALANCE_STATE}" = "active" ] &&
       command -v systemctl >/dev/null 2>&1; then
        echo "Restarting irqbalance..."
        systemctl start irqbalance || true
    fi

    rm -f "${BACKUP_FILE}"

    echo
    echo "Restore completed."
    show_status
}

need_root

action="${1:-}"

case "${action}" in
    status)
        show_status
        ;;

    set)
        [ "$#" -ge 2 ] && [ "$#" -le 3 ] ||
            die "usage: $0 set <backend_cpu> [irq_cpu]"

        backend_cpu="$2"
        irq_cpu="${3:-$2}"

        set_affinity "${backend_cpu}" "${irq_cpu}"
        ;;

    restore)
        restore_affinity
        ;;

    *)
        cat <<EOF
Usage:
  $0 status
  $0 set <backend_cpu> [irq_cpu]
  $0 restore

Examples:
  # 自动识别 vhost / no-vhost，并将后端线程和 IRQ 都放到 CPU0
  $0 set 0

  # 跨核 A/B：后端线程 CPU0，IRQ CPU5
  $0 set 0 5

Environment:
  IRQ=${IRQ}
  PHY_IF=${PHY_IF}
  TAP_IF=${TAP_IF}
  VM_MATCH=${VM_MATCH}
  BACKEND_TID_OVERRIDE=<tid>
EOF
        exit 1
        ;;
esac

#!/bin/sh
# eth0_irq_monitor.sh -- ServerVM eth0 device-IRQ counter capture.
#
# Directions are relative to Android, assuming Android is the iperf3 client:
#   up:   Android -> PC; main counters = ServerVM eth0 TX, tap1 RX
#   down: PC -> Android (-R); main counters = ServerVM eth0 RX, tap1 TX
#
# This script is READ-ONLY with respect to networking, IRQ affinity, services,
# tracing and thread affinity. It writes only its output files.
# It does NOT start remote iperf3, classify individual IRQs as RX/TX causes,
# measure IPI latency, or read Hypervisor-side physical IRQ statistics.
#
# Usage:
#   sh eth0_irq_monitor.sh detect
#   sh eth0_irq_monitor.sh irqs
#   sh eth0_irq_monitor.sh capture udp_up_before up 40
#   sh eth0_irq_monitor.sh capture udp_down_before down 40
#   sh eth0_irq_monitor.sh compare <case_A_dir> <case_B_dir>
#
# Optional environment:
#   PHY_IF=eth0 TAP_IF=tap1 OUT_BASE=/tmp/eth0_irq_monitor
#   START_MBPS=100 WAIT_TIMEOUT=120 WARMUP=8
#   BACKEND_TID=1094 IOEVENTFD_TID=227   (record their state; never bind them)
#   IRQ_LIST="131 132"                 (validated subset of detected IRQs)
#   IRQ_TOKEN=<exact /proc/interrupts action token>
#       Only use IRQ_TOKEN after verifying the device/driver identity. This is
#       useful if the action is named for the platform device instead of eth0.
#
# Capture uses /proc/uptime rather than wall-clock dates for rate denominators.
# Statistics are cumulative-counter deltas, never printf("%d") for byte counts.
# Counters >= 2^53 are rejected rather than rounded by typical awk arithmetic.
# No CPU hotplug, STR, driver reload or interface recreation during a capture.

set -eu
export LC_ALL=C
PHY_IF=${PHY_IF:-eth0}
TAP_IF=${TAP_IF:-tap1}
OUT_BASE=${OUT_BASE:-/tmp/eth0_irq_monitor}
START_MBPS=${START_MBPS:-100}
WAIT_TIMEOUT=${WAIT_TIMEOUT:-120}
WARMUP=${WARMUP:-8}
IRQ_TOKEN=${IRQ_TOKEN:-}
IRQ_LIST=${IRQ_LIST:-}

fail() { echo "ERROR: $*" >&2; exit 1; }
uint() { case "$1" in ''|*[!0-9]*) fail "$2 must be an unsigned integer";; esac; }
valid_name() { case "$1" in ''|*[!A-Za-z0-9_.:-]*) fail "invalid $2: $1";; esac; }
uptime_now() { read -r u rest < /proc/uptime; printf '%s\n' "$u"; }
read_value() { if [ -r "$1" ]; then IFS= read -r value < "$1" || return 1; printf '%s\n' "$value"; else printf 'NA\n'; fi; }
stat_value() { read_value "/sys/class/net/$1/statistics/$2"; }

# Interface-name matching is token-based: eth0 must not match eth01.
# Also accepts common queue suffixes eth0-*, eth0_*, eth0:*.
# No broad 'net|isp|gmac' fallback and no default numeric IRQ.
discover() {
    valid_name "$PHY_IF" PHY_IF
    [ -d "/sys/class/net/$PHY_IF" ] || fail "interface $PHY_IF not found"
    msi_ids=''
    for f in /sys/class/net/"$PHY_IF"/device/msi_irqs/*; do
        [ -e "$f" ] || continue
        id=${f##*/}
        case "$id" in ''|*[!0-9]*) continue;; esac
        msi_ids="$msi_ids $id"
    done
    DETECTED=$(awk -v dev="$PHY_IF" -v token="$IRQ_TOKEN" -v msi="$msi_ids" '
        NR==1 { for(i=1;i<=NF;i++) if($i ~ /^CPU[0-9]+$/) n++; split(msi,a," "); for(i in a) m[a[i]]=1; next }
        $1 ~ /^[0-9]+:$/ {
            id=$1; sub(/:$/,"",id); hit=(id in m)
            for(i=n+2;i<=NF;i++) {
                k=split($i,b,",")
                for(j=1;j<=k;j++) {
                    x=b[j]
                    if(x==dev || index(x,dev "-")==1 || index(x,dev "_")==1 || index(x,dev ":")==1) hit=1
                    if(token!="" && x==token) hit=1
                }
            }
            if(hit) print id
        }' /proc/interrupts | sort -n -u)
    [ -n "$DETECTED" ] || fail "cannot identify $PHY_IF IRQ. Check ethtool -i and /proc/interrupts; do not guess an IRQ number."
    if [ -n "$IRQ_LIST" ]; then
        chosen=$(printf '%s\n' "$IRQ_LIST" | tr ',' ' ')
        for id in $chosen; do
            uint "$id" IRQ_LIST
            printf '%s\n' "$DETECTED" | grep -qx "$id" || fail "IRQ $id is not associated with $PHY_IF by name/MSI/IRQ_TOKEN; refusing it"
        done
        IRQS=$(printf '%s\n' $chosen | sort -n -u)
    else
        IRQS=$DETECTED
    fi
    IRQ_WORDS=$(printf '%s\n' "$IRQS" | tr '\n' ' ' | sed 's/ *$//')
}
show_irqs() {
    echo "ServerVM interface: $PHY_IF; IRQs: $IRQ_WORDS"
    for id in $IRQS; do
        awk -v key="$id:" '$1==key {print}' /proc/interrupts
        echo "  requested=$(read_value "/proc/irq/$id/smp_affinity_list") effective=$(read_value "/proc/irq/$id/effective_affinity_list")"
    done
    echo 'Counters are per IRQ line, potentially shared between RX/TX/link events.'
}

save_context() {
    name=$1
    {
        echo "date=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "direction=$DIRECTION"
        echo "phy_if=$PHY_IF tap_if=$TAP_IF irq_list=$IRQ_WORDS"
        echo "kernel=$(uname -r)"
        echo "device=$(readlink -f "/sys/class/net/$PHY_IF/device" 2>/dev/null || true)"
        echo "driver=$(readlink -f "/sys/class/net/$PHY_IF/device/driver" 2>/dev/null || true)"
        echo "threaded_napi=$(read_value "/sys/class/net/$PHY_IF/threaded")"
        echo "speed_mbps=$(read_value "/sys/class/net/$PHY_IF/speed" || true)"
        show_irqs
        if command -v ps >/dev/null 2>&1; then
            echo '--- related tasks, snapshot only ---'
            ps -eLo pid,tid,psr,comm 2>/dev/null | grep -E 'PID|vhost-|ioeventfd|vtnet-|napi/|irq/' || true
        fi
        if command -v systemctl >/dev/null 2>&1; then
            echo '--- irqbalance state (not modified) ---'
            systemctl is-active irqbalance 2>/dev/null || true
        fi
        for dev in "$PHY_IF" "$TAP_IF"; do
            for f in /sys/class/net/"$dev"/queues/rx-*/rps_cpus /sys/class/net/"$dev"/queues/rx-*/rps_flow_cnt; do
                [ -r "$f" ] || continue
                echo "$f=$(read_value "$f")"
            done
        done
        if command -v ethtool >/dev/null 2>&1; then
            echo '--- ethtool -i ---'; ethtool -i "$PHY_IF" 2>&1 || true
            echo '--- ethtool -c ---'; ethtool -c "$PHY_IF" 2>&1 || true
        fi
    } > "$OUT/${name}_context.txt" 2>&1
}

# Direction-aware traffic gate. Byte rates, not just packet rates, distinguish
# TCP data from reverse ACK traffic. Both eth0 and tap1 must carry the data.
wait_for_traffic() {
    if [ "$DIRECTION" = up ]; then es=tx_bytes; ts=rx_bytes; else es=rx_bytes; ts=tx_bytes; fi
    echo "Waiting: Android $DIRECTION; $PHY_IF/$es AND $TAP_IF/$ts >= $START_MBPS Mbit/s."
    echo 'Start the corresponding 60-second Android iperf3 test now.'
    p=$(stat_value "$PHY_IF" "$es"); q=$(stat_value "$TAP_IF" "$ts"); t=$(uptime_now); begin=$t; hits=0
    while :; do
        sleep 1
        a=$(stat_value "$PHY_IF" "$es"); b=$(stat_value "$TAP_IF" "$ts"); now=$(uptime_now)
        verdict=$(awk -v p="$p" -v q="$q" -v a="$a" -v b="$b" -v t="$t" -v now="$now" -v limit="$START_MBPS" '
            BEGIN {dt=now-t; if(a<p || b<q || dt<=0) print "reset"; else if((a-p)*8/dt/1e6>=limit && (b-q)*8/dt/1e6>=limit) print "yes"; else print "no"}')
        [ "$verdict" != reset ] || fail 'interface counters or monotonic clock changed while waiting'
        if [ "$verdict" = yes ]; then hits=$((hits+1)); else hits=0; fi
        if [ "$hits" -ge 2 ]; then echo "Traffic detected; warm-up ${WARMUP}s."; sleep "$WARMUP"; return; fi
        expired=$(awk -v n="$now" -v s="$begin" -v limit="$WAIT_TIMEOUT" 'BEGIN {print (n-s>=limit)?1:0}')
        [ "$expired" -eq 0 ] || fail 'traffic wait timed out; check up/down, iperf and tap1/eth0 path'
        p=$a; q=$b; t=$now
    done
}

snapshot() {
    seq=$1
    start=$(uptime_now)
    cat /proc/interrupts > "$OUT/.interrupts.current"
    # Abort rather than treating disappeared IRQs/changed CPU columns as zero.
    awk -v ids="$IRQ_WORDS" -v basecpus="$CPU_HEADER" '
        BEGIN {split(ids,a," "); for(i in a) wanted[a[i]]=1}
        NR==1 {h=""; for(i=1;i<=NF;i++) if($i ~ /^CPU[0-9]+$/) {n++; h=h (h==""?"":" ") $i}
               if(h!=basecpus) exit 2; next}
        $1 ~ /^[0-9]+:$/ {id=$1; sub(/:$/,"",id); if(id in wanted) {found[id]=1; for(i=2;i<=n+1;i++) if($i !~ /^[0-9]+$/) exit 3}}
        END {for(i in wanted) if(!(i in found)) exit 4}
    ' "$OUT/.interrupts.current" || fail 'IRQ disappeared or CPU topology changed; discard this capture'
    [ "$seq" -ne 0 ] || cp "$OUT/.interrupts.current" "$OUT/before_interrupts.txt"
    cp "$OUT/.interrupts.current" "$OUT/after_interrupts.txt"
    {
        printf 'BEGIN\t%s\t%s\n' "$seq" "$start"
        awk -v ids="$IRQ_WORDS" '
            BEGIN {OFS="\t"; split(ids,a," "); for(i in a) wanted[a[i]]=1}
            NR==1 {for(i=1;i<=NF;i++) if($i ~ /^CPU[0-9]+$/) cpu[++n]=$i; next}
            $1 ~ /^[0-9]+:$/ {id=$1; sub(/:$/,"",id); if(id in wanted) {
                desc=""; for(i=n+2;i<=NF;i++) desc=desc (desc==""?"":" ") $i
                print "DESC",id,desc
                for(i=1;i<=n;i++) print "IRQ",id,cpu[i],$(i+1)
            }}' "$OUT/.interrupts.current"
        for dev in "$PHY_IF" "$TAP_IF"; do
            printf 'INDEX\t%s\t%s\n' "$dev" "$(read_value "/sys/class/net/$dev/ifindex")"
            for key in tx_packets rx_packets tx_bytes rx_bytes tx_dropped rx_dropped tx_errors rx_errors; do
                value=$(stat_value "$dev" "$key")
                case "$value" in ''|*[!0-9]*) fail "cannot read $dev/$key";; esac
                printf 'NET\t%s\t%s\t%s\n' "$dev" "$key" "$value"
            done
        done
        for id in $IRQS; do
            printf 'AFF\t%s\t%s\t%s\n' "$id" "$(read_value "/proc/irq/$id/smp_affinity_list")" "$(read_value "/proc/irq/$id/effective_affinity_list")"
        done
        for tid in $WATCH_TIDS; do
            if [ -r "/proc/$tid/status" ]; then
                comm=$(read_value "/proc/$tid/comm")
                allowed=$(awk '/^Cpus_allowed_list:/ {print $2}' "/proc/$tid/status")
                # Strip through the LAST ') ' so spaces/parentheses in comm work.
                IFS= read -r line < "/proc/$tid/stat" || fail "TID $tid exited during snapshot"
                rest=${line##*) }
                fields=$(printf '%s\n' "$rest" | awk '{print $20 " " $37}')
                printf 'THREAD\t%s\t%s\t%s\t%s\n' "$tid" "$comm" "$allowed" "$fields"
            else
                printf 'THREAD\t%s\tMISSING\tNA\tNA\n' "$tid"
            fi
        done
        printf 'END\t%s\n' "$(uptime_now)"
    } >> "$OUT/raw_samples.tsv"
}

write_analyzer() {
cat <<'AWK'
BEGIN {
    FS="\t"; OFS=","; n=split(ids,irqlist," "); c=split(cpuheader,cpulist," ")
    print "sample,elapsed_s,interval_s,eth_tx_packets,eth_rx_packets,eth_tx_mbps,eth_rx_mbps,tap_rx_packets,tap_tx_packets,irq_total,irq_per_second,main_packets,main_packets_per_irq,irq_per_10k_main_packets,main_mbps,eth_tx_dropped,eth_rx_dropped,eth_tx_errors,eth_rx_errors" > out "/samples.csv"
    print "sample,elapsed_s,interval_s,irq,cpu,irq_delta" > out "/irq_samples.csv"
    print "sample\tirq\trequested\teffective" > out "/irq_affinity.tsv"
    print "sample\ttid\tcomm\tallowed_cpus\tstarttime_ticks last_cpu" > out "/thread_state.tsv"
}
function die(s) {print "INVALID CAPTURE: " s > "/dev/stderr"; bad=1; exit 3}
function number(s) {if(s !~ /^[0-9]+$/ || s+0>=9007199254740992) die("invalid/too-large counter: " s); return s+0}
function ratio(a,b) {return b>0?sprintf("%.6f",a/b):"NA"}
function total_irq(  i,j,s) {s=0; for(i=1;i<=n;i++) for(j=1;j<=c;j++) s+=iv[irqlist[i],cpulist[j]]; return s}
function summary(k,v) {print k "," v > out "/summary.csv"}
$1=="BEGIN" {seq=$2+0; left=$3+0; next}
$1=="DESC" {if(seq==0) names[$2]=$3; else if(names[$2]!=$3) die("IRQ " $2 " action/device changed"); next}
$1=="INDEX" {if(seq==0) idx[$2]=$3; else if(idx[$2]!=$3) die("interface " $2 " recreated"); next}
$1=="IRQ" {
    k=$2 SUBSEP $3; val=number($4)
    if(seq>0 && val<iv[k]) die("IRQ counter decreased")
    iv[k]=val; if(seq==0) firsti[k]=val
    next
}
$1=="NET" {
    k=$2 SUBSEP $3; val=number($4)
    if(seq>0 && val<nv[k]) die("network counter decreased")
    nv[k]=val; if(seq==0) firstn[k]=val
    next
}
$1=="AFF" {
    printf "%s\t%s\t%s\t%s\n",seq,$2,$3,$4 > out "/irq_affinity.tsv"
    val=$3 "|" $4
    if(seq==0) aff[$2]=val; else if(aff[$2]!=val) {affchanges++; aff[$2]=val}
    next
}
$1=="THREAD" {
    printf "%s\t%s\t%s\t%s\t%s\n",seq,$2,$3,$4,$5 > out "/thread_state.tsv"
    if($3=="MISSING") threadmissing++
    split($5,a," "); val=$3 "|" $4 "|" a[1]
    if(seq==0) thr[$2]=val; else if(thr[$2]!=val) {threadchanges++; thr[$2]=val}
    next
}
$1=="END" {
    right=$2+0; ts=(left+right)/2
    if(right<left) die("clock ran backwards")
    if(right-left>maxspan) maxspan=right-left
    si=total_irq()
    if(seq==0) {firstts=ts; mini=1e100}
    else {
        dt=ts-prevts; if(dt<=0) die("non-positive sampling interval")
        txp=nv[phy,"tx_packets"]-pn[phy,"tx_packets"]; rxp=nv[phy,"rx_packets"]-pn[phy,"rx_packets"]
        txb=nv[phy,"tx_bytes"]-pn[phy,"tx_bytes"]; rxb=nv[phy,"rx_bytes"]-pn[phy,"rx_bytes"]
        taprx=nv[tap,"rx_packets"]-pn[tap,"rx_packets"]; taptx=nv[tap,"tx_packets"]-pn[tap,"tx_packets"]
        iq=si-prevsi; mp=(direction=="up"?txp:rxp); mb=(direction=="up"?txb:rxb)*8/dt/1e6
        if(mb<mini) mini=mb; if(mb<startmbps/5) low++
        if((direction=="up"?rxb:txb)>(direction=="up"?txb:rxb)) reverse++
        printf "%d,%.3f,%.3f,%.0f,%.0f,%.3f,%.3f,%.0f,%.0f,%.0f,%.3f,%.0f,%s,%s,%.3f,%.0f,%.0f,%.0f,%.0f\n", \
            seq,ts-firstts,dt,txp,rxp,txb*8/dt/1e6,rxb*8/dt/1e6,taprx,taptx,iq,iq/dt,mp,ratio(mp,iq),ratio(iq*10000,mp),mb, \
            nv[phy,"tx_dropped"]-pn[phy,"tx_dropped"],nv[phy,"rx_dropped"]-pn[phy,"rx_dropped"], \
            nv[phy,"tx_errors"]-pn[phy,"tx_errors"],nv[phy,"rx_errors"]-pn[phy,"rx_errors"] > out "/samples.csv"
        for(i=1;i<=n;i++) for(j=1;j<=c;j++) {
            k=irqlist[i] SUBSEP cpulist[j]
            printf "%d,%.3f,%.3f,%s,%s,%.0f\n",seq,ts-firstts,dt,irqlist[i],cpulist[j],iv[k]-pi[k] > out "/irq_samples.csv"
        }
    }
    for(k in iv) pi[k]=iv[k]; for(k in nv) pn[k]=nv[k]
    prevts=ts; prevsi=si; records++
}
END {
    if(bad) exit 3
    if(records<2) {print "not enough snapshots" > "/dev/stderr"; exit 3}
    duration=ts-firstts; sum=0
    print "irq,cpu,irq_delta,irq_per_second" > out "/irq_delta.csv"
    for(i=1;i<=n;i++) {
        per=0
        for(j=1;j<=c;j++) {
            k=irqlist[i] SUBSEP cpulist[j]; d=iv[k]-firsti[k]; per+=d
            printf "%s,%s,%.0f,%.6f\n",irqlist[i],cpulist[j],d,d/duration > out "/irq_delta.csv"
        }
        printf "%s,ALL,%.0f,%.6f\n",irqlist[i],per,per/duration > out "/irq_delta.csv"; sum+=per
    }
    printf "ALL,ALL,%.0f,%.6f\n",sum,sum/duration > out "/irq_delta.csv"
    txp=nv[phy,"tx_packets"]-firstn[phy,"tx_packets"]; rxp=nv[phy,"rx_packets"]-firstn[phy,"rx_packets"]
    txb=nv[phy,"tx_bytes"]-firstn[phy,"tx_bytes"]; rxb=nv[phy,"rx_bytes"]-firstn[phy,"rx_bytes"]
    mp=(direction=="up"?txp:rxp); mb=(direction=="up"?txb:rxb)
    print "metric,value" > out "/summary.csv"
    summary("label",label); summary("direction",direction); summary("phy_if",phy); summary("tap_if",tap)
    summary("irq_list",ids); summary("capture_seconds",sprintf("%.3f",duration)); summary("sample_intervals",records-1)
    summary("max_snapshot_span_seconds",sprintf("%.3f",maxspan))
    summary("irq_total_delta",sprintf("%.0f",sum)); summary("irq_per_second",sprintf("%.3f",sum/duration))
    summary("eth_tx_packets_delta",sprintf("%.0f",txp)); summary("eth_rx_packets_delta",sprintf("%.0f",rxp))
    summary("eth_tx_bytes_delta",sprintf("%.0f",txb)); summary("eth_rx_bytes_delta",sprintf("%.0f",rxb))
    summary("eth_tx_pps",sprintf("%.3f",txp/duration)); summary("eth_rx_pps",sprintf("%.3f",rxp/duration))
    summary("eth_tx_mbps",sprintf("%.3f",txb*8/duration/1e6)); summary("eth_rx_mbps",sprintf("%.3f",rxb*8/duration/1e6))
    for(i=1;i<=2;i++) {
        side=(i==1?"rx":"tx")
        summary("tap_" side "_packets_delta",sprintf("%.0f",nv[tap,side "_packets"]-firstn[tap,side "_packets"]))
        summary("tap_" side "_mbps",sprintf("%.3f",(nv[tap,side "_bytes"]-firstn[tap,side "_bytes"])*8/duration/1e6))
        summary("eth_" side "_dropped_delta",sprintf("%.0f",nv[phy,side "_dropped"]-firstn[phy,side "_dropped"]))
        summary("eth_" side "_errors_delta",sprintf("%.0f",nv[phy,side "_errors"]-firstn[phy,side "_errors"]))
    }
    summary("main_packets_delta",sprintf("%.0f",mp)); summary("main_mbps",sprintf("%.3f",mb*8/duration/1e6))
    summary("main_packets_per_irq",ratio(mp,sum)); summary("irq_per_10k_main_packets",ratio(sum*10000,mp))
    summary("irq_per_main_gbit",ratio(sum,mb*8/1e9))
    summary("irq_per_10k_eth_tx_packets",ratio(sum*10000,txp)); summary("irq_per_10k_eth_rx_packets",ratio(sum*10000,rxp))
    summary("minimum_interval_main_mbps",sprintf("%.3f",mini)); summary("low_traffic_intervals",low+0)
    summary("reverse_dominant_intervals",reverse+0); summary("irq_affinity_changes",affchanges+0)
    summary("thread_identity_or_affinity_changes",threadchanges+0); summary("thread_missing_snapshots",threadmissing+0)
    summary("capture_status",(low || reverse || affchanges || threadchanges || threadmissing)?"CHECK_WARNINGS":"OK")
}
AWK
}

capture() {
    LABEL=$1; DIRECTION=$2; CAPTURE_INTERVALS=$3
    case "$LABEL" in ''|*[!A-Za-z0-9_.-]*) fail 'label must use letters, digits, _, - or .' ;; esac
    case "$DIRECTION" in up|down) ;; *) fail 'direction must be up or down, relative to Android' ;; esac
    uint "$CAPTURE_INTERVALS" seconds; [ "$CAPTURE_INTERVALS" -ge 1 ] && [ "$CAPTURE_INTERVALS" -le 3600 ] || fail 'seconds must be 1..3600'
    uint "$WARMUP" WARMUP; uint "$WAIT_TIMEOUT" WAIT_TIMEOUT; uint "$START_MBPS" START_MBPS
    [ "$START_MBPS" -gt 0 ] || fail 'START_MBPS must be > 0'
    valid_name "$TAP_IF" TAP_IF; [ "$TAP_IF" != "$PHY_IF" ] || fail 'TAP_IF and PHY_IF must differ'
    [ -d "/sys/class/net/$TAP_IF" ] || fail "TAP interface $TAP_IF missing"
    WATCH_TIDS=''
    for tid in ${IOEVENTFD_TID:-} ${BACKEND_TID:-}; do
        uint "$tid" TID; [ -r "/proc/$tid/status" ] || fail "TID $tid missing"
        WATCH_TIDS="$WATCH_TIDS $tid"
    done
    discover
    CPU_HEADER=$(awk 'NR==1 {for(i=1;i<=NF;i++) if($i ~ /^CPU[0-9]+$/) s=s (s==""?"":" ") $i; print s; exit}' /proc/interrupts)
    [ -n "$CPU_HEADER" ] || fail 'no per-CPU IRQ header found'
    mkdir -p "$OUT_BASE"
    OUT=$(mktemp -d "$OUT_BASE/${LABEL}_$(date +%Y%m%d_%H%M%S)_XXXXXX") || fail 'cannot create output directory'
    # Interrupted runs never receive a successful summary.
    trap 'echo "Interrupted; incomplete raw data retained at $OUT" >&2; exit 130' INT
    trap 'echo "Terminated; incomplete raw data retained at $OUT" >&2; exit 143' TERM
    save_context setup
    show_irqs
    wait_for_traffic
    save_context before
    echo "Capturing $DIRECTION IRQ/counter samples: $CAPTURE_INTERVALS one-second intervals."
    : > "$OUT/raw_samples.tsv"
    snapshot 0
    i=1
    while [ "$i" -le "$CAPTURE_INTERVALS" ]; do
        sleep 1
        snapshot "$i"
        i=$((i+1))
    done
    write_analyzer > "$OUT/analyze.awk"
    awk -v out="$OUT" -v ids="$IRQ_WORDS" -v cpuheader="$CPU_HEADER" -v phy="$PHY_IF" -v tap="$TAP_IF" \
        -v direction="$DIRECTION" -v label="$LABEL" -v startmbps="$START_MBPS" \
        -f "$OUT/analyze.awk" "$OUT/raw_samples.tsv" || fail "invalid capture; see raw data at $OUT"
    save_context after
    rm -f "$OUT/.interrupts.current"
    {
        echo "Android direction: $DIRECTION"
        echo "Main direction counters: $PHY_IF $([ "$DIRECTION" = up ] && echo TX || echo RX)"
        echo 'Device IRQ total is NOT a TX-only or RX-only interrupt count.'
        echo 'Interface Mbit/s is NOT iperf3 application goodput.'
        echo
        cat "$OUT/summary.csv"
        echo
        cat "$OUT/irq_delta.csv"
    } > "$OUT/result.txt"
    cat "$OUT/result.txt"
    echo
    echo "OUTPUT_DIR=$OUT"
}

compare() {
    A=$1; B=$2
    [ -r "$A/summary.csv" ] && [ -r "$B/summary.csv" ] || fail 'both case directories must have summary.csv'
    echo "caseA=$A"
    echo "caseB=$B"
    awk -F, '
        NR==FNR {if(FNR>1) {a[$1]=$2; order[++n]=$1}; next}
        FNR>1 {b[$1]=$2}
        END {
            if(a["direction"]!=b["direction"]) print "WARNING: different directions; this is NOT an affinity-only A/B comparison."
            if(a["capture_status"]!="OK" || b["capture_status"]!="OK") print "WARNING: inspect capture_status / *_changes / *_intervals."
            print "metric,caseA,caseB,B_over_A"
            for(i=1;i<=n;i++) {
                k=order[i]; r="NA"
                if(a[k] ~ /^[0-9]+([.][0-9]+)?$/ && b[k] ~ /^[0-9]+([.][0-9]+)?$/ && a[k]+0>0) r=sprintf("%.6f",b[k]/a[k])
                printf "%s,%s,%s,%s\n",k,a[k],b[k],r
            }
        }' "$A/summary.csv" "$B/summary.csv"
}

help() {
    cat <<'EOF'
Usage:
  sh eth0_irq_monitor.sh detect
  sh eth0_irq_monitor.sh irqs
  sh eth0_irq_monitor.sh capture <label> <up|down> [seconds=40]
  sh eth0_irq_monitor.sh compare <case_A_dir> <case_B_dir>

up   = Android client sends to PC (NO -R).
down = PC sends to Android client (WITH -R).

On ServerVM, start capture FIRST, then start Android iperf3 for 60 seconds.
The script waits for two traffic samples, warms up for 8 seconds, captures
40 intervals by default, and prints the ACTUAL elapsed seconds.

No IRQ/thread affinities, services or tracing settings are changed.
Selected IRQs must belong to eth0 by interface action name or MSI device.
A shared IRQ line cannot distinguish TX completion, RX, or other causes.

Optional:
  IOEVENTFD_TID=227 BACKEND_TID=1094
  PHY_IF=eth0 TAP_IF=tap1 OUT_BASE=/tmp/eth0_irq_monitor
  START_MBPS=100 WARMUP=8 WAIT_TIMEOUT=120
  IRQ_LIST="131"     # must pass device identity validation
  IRQ_TOKEN=<exact action token>  # only for a verified device-name alias
EOF
}

for tool in awk cat grep sed sort tr mktemp sleep; do command -v "$tool" >/dev/null 2>&1 || fail "missing command: $tool"; done
case "${1:-help}" in
    detect) [ "$#" -eq 1 ] || fail 'detect takes no arguments'; discover; show_irqs ;;
    irqs) [ "$#" -eq 1 ] || fail 'irqs takes no arguments'; discover; printf '%s\n' "$IRQS" ;;
    capture) [ "$#" -ge 3 ] && [ "$#" -le 4 ] || fail 'capture <label> <up|down> [seconds]'; capture "$2" "$3" "${4:-40}" ;;
    compare) [ "$#" -eq 3 ] || fail 'compare <case_A_dir> <case_B_dir>'; compare "$2" "$3" ;;
    help|-h|--help) help ;;
    *) fail 'unknown action; use help' ;;
esac

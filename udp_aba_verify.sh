#!/bin/sh
# Same-flow A -> B -> A verification. No new kernel instrumentation.
# Usage (ServerVM root, BEFORE starting Android iperf):
#   sh udp_aba_verify.sh <ioeventfd_TID> <vhost_TID>
# Android: one 180s UDP run, -A 1 --cport 41001 -b 1000M -l 1400.
# Only endpoint counters are read during the stable measurement windows.
set -u
umask 077
export LC_ALL=C

PROC=/proc
SYS=/sys
PHY_IF=${PHY_IF:-eth0}
TAP_IF=${TAP_IF:-tap1}
START_PPS=${START_PPS:-10000}
WAIT_TIMEOUT=${WAIT_TIMEOUT:-120}
PAYLOAD_BYTES=${PAYLOAD_BYTES:-1400}
BASE_DIR=${BASE_DIR:-/tmp}
LOCK="$BASE_DIR/udp_aba_verify.lock"
OUT=
CHANGED=0
LOCKED=0
SLEEP_PID=
RESULT=NOT_STARTED
REASON=
RESTORE=NOT_NEEDED
IO_ORIG=
VH_ORIG=
IO_ID=
VH_ID=
IRQS=

usage() {
    echo "Usage: sh $0 <ioeventfd_TID> <vhost_TID>" >&2
    echo "Start this script first; start ONE 180-second Android UDP run after READY." >&2
}
fail() {
    REASON=$*
    RESULT=FAILED
    echo "ERROR: $REASON" >&2
    exit 1
}
read_clock() { read CLOCK _unused < "$PROC/uptime" || return 1; }
thread_identity() {
    [ -r "$PROC/$1/comm" ] && [ -r "$PROC/$1/stat" ] || return 1
    _comm=$(cat "$PROC/$1/comm") || return 1
    _born=$(awk '{s=$0; sub(/^.*\) /,"",s); split(s,a,/ +/); print a[20]}' "$PROC/$1/stat") || return 1
    [ -n "$_born" ] || return 1
    printf '%s|%s\n' "$_comm" "$_born"
}
affinity() { awk '/^Cpus_allowed_list:/ {print $2}' "$PROC/$1/status"; }
irq_signature() {
    awk -v q="$1" 'NR==1 {n=NF; next}
        $1==q ":" {s=""; for(i=n+2;i<=NF;i++) s=s (s==""?"":" ") $i; print s; found=1}
        END {if(!found) exit 1}' "$PROC/interrupts"
}
nap() {
    sleep "$1" &
    SLEEP_PID=$!
    wait "$SLEEP_PID"
    _sleep_rc=$?
    SLEEP_PID=
    [ "$_sleep_rc" -eq 0 ] || fail "sleep interrupted"
}
wait_offset() {
    read_clock || fail "cannot read monotonic uptime"
    _remaining=$(awk -v t="$FLOW_T0" -v d="$1" -v n="$CLOCK" 'BEGIN{x=t+d-n; if(x<0)x=0; printf "%.3f",x}')
    nap "$_remaining"
}
validate_identity() {
    [ "$(thread_identity "$IO_TID")" = "$IO_ID" ] || fail "ioeventfd identity changed; do not continue after Guest restart"
    [ "$(thread_identity "$VH_TID")" = "$VH_ID" ] || fail "vhost identity changed"
    for _irq in $IRQS; do
        [ "$(irq_signature "$_irq")" = "$(cat "$OUT/irq_${_irq}.identity")" ] || fail "IRQ $_irq identity changed"
    done
}
validate_layout() {
    validate_identity
    [ "$(affinity "$IO_TID")" = "$1" ] || fail "ioeventfd affinity is not CPU$1"
    [ "$(affinity "$VH_TID")" = 0 ] || fail "vhost affinity is not CPU0"
    for _irq in $IRQS; do
        [ "$(cat "$PROC/irq/$_irq/smp_affinity_list")" = 0 ] || fail "IRQ $_irq requested CPU changed"
        [ "$(cat "$PROC/irq/$_irq/effective_affinity_list")" = 0 ] || fail "IRQ $_irq effective CPU is not 0"
    done
}
record_stage() {
    read_clock || fail "cannot read uptime"
    _relative=$(awk -v n="$CLOCK" -v b="${FLOW_T0:-$CLOCK}" 'BEGIN{printf "%.3f",n-b}')
    printf '%s,%s,%s,%s,%s\n' "$1" "$CLOCK" "$_relative" "$(affinity "$IO_TID")" "$(affinity "$VH_TID")" >> "$OUT/stages.csv"
}
# Values in /proc/net/dev are kept as decimal strings, not shell 32-bit integers.
flow_read() {
    read_clock || return 1
    FLOW_SAMPLE=$(awk -v p="$PHY_IF" -v t="$TAP_IF" -v now="$CLOCK" '
        NR>2 {gsub(":"," "); if($1==p){x=$11; pf=1} if($1==t){y=$3;tf=1}}
        END{if(!pf||!tf)exit 1; printf "%s %.0f %.0f\n",now,x,y}' "$PROC/net/dev") || return 1
}
flow_rate() {
    # $1 and $2 each contain: monotonic_seconds phy_TX_packets tap_RX_packets.
    awk -v a="$1" -v b="$2" 'BEGIN{split(a,x);split(b,y);d=y[1]-x[1];
        if(d<=0||y[2]<x[2]||y[3]<x[3]) exit 1;
        p=(y[2]-x[2])/d;q=(y[3]-x[3])/d;printf "%.3f\n",(p<q?p:q)}'
}
snapshot() {
    _dest=$1
    read_clock || fail "cannot read uptime"
    _begin=$CLOCK
    awk -v p="$PHY_IF" -v t="$TAP_IF" '
        NR>2 {gsub(":"," ");
          if($1==p){pf=1; printf "tx_packets=%.0f\nrx_packets=%.0f\ntx_bytes=%.0f\ntx_dropped=%.0f\ntx_errors=%.0f\n",$11,$3,$10,$13,$12}
          if($1==t){tf=1;printf "tap_rx_packets=%.0f\n",$3}}
        END{if(!pf||!tf)exit 1}' "$PROC/net/dev" > "$_dest" || fail "network snapshot failed"
    awk -v ids="$IRQS" '
        BEGIN{split(ids,a);for(i in a)if(a[i]!="")wanted[a[i]]=1; irq=0;off=0; ipi=0; ipifound=0}
        NR==1{nc=NF;for(i=1;i<=NF;i++)col[i+1]=$i;next}
        {key=$1;sub(/:$/,"",key);
         if(key in wanted){found[key]=1;for(i=2;i<=nc+1;i++){irq+=$i;if(col[i]!="CPU0")off+=$i}}
         if($0~/Function call interrupts/){ipifound=1;for(i=2;i<=nc+1;i++)ipi+=$i}}
        END{for(k in wanted)if(!(k in found))exit 1;
          printf "eth_irq=%.0f\neth_irq_off_cpu0=%.0f\n",irq,off;
          if(ipifound)printf "ipi=%.0f\n",ipi;else print "ipi=NA"}' "$PROC/interrupts" >> "$_dest" || fail "IRQ snapshot failed"
    read_clock || fail "cannot read uptime"
    printf 'begin_s=%s\nend_s=%s\n' "$_begin" "$CLOCK" >> "$_dest"
}
analyze_phase() {
    awk -F= -v stage="$1" -v cpu="$2" -v origin="$FLOW_T0" -v bytes="$PAYLOAD_BYTES" -v minpps="$START_PPS" '
      FNR==NR{a[$1]=$2;next}{b[$1]=$2}
      END{
        s=(a["begin_s"]+a["end_s"])/2;e=(b["begin_s"]+b["end_s"])/2;d=e-s;
        if(d<=0)exit 1; quality="OK";
        split("tx_packets rx_packets tx_bytes tx_dropped tx_errors tap_rx_packets eth_irq eth_irq_off_cpu0",fields," ");
        for(i in fields){k=fields[i];if(!(k in a)||!(k in b)||b[k]<a[k])quality="INVALID_COUNTER";diff[k]=b[k]-a[k]}
        pps=diff["tx_packets"]/d;tpps=diff["tap_rx_packets"]/d;
        if(pps<minpps||tpps<minpps)quality="LOW_TRAFFIC";
        if(diff["eth_irq_off_cpu0"]!=0)quality="IRQ_NOT_ONLY_CPU0";
        if(diff["rx_packets"]>diff["tx_packets"])quality="REVERSE_DOMINANT";
        skew=((a["end_s"]-a["begin_s"])+(b["end_s"]-b["begin_s"]))/d;
        if(skew>0.01)quality="SNAPSHOT_SPAN_HIGH";
        ipis="NA";ipin="NA";
        if(a["ipi"]!="NA"&&b["ipi"]!="NA"){
          delta=b["ipi"]-a["ipi"];if(delta<0)quality="INVALID_IPI_COUNTER";
          ipis=sprintf("%.3f",delta/d);if(diff["tx_packets"]>0)ipin=sprintf("%.3f",10000*delta/diff["tx_packets"])
        }
        printf "%s,%s,%.3f,%.3f,%.3f,%.3f,%.3f,%s,%s,%.3f,%.0f,%.0f,%.3f,%s\n",stage,cpu,s-origin,e-origin,d,pps,pps*bytes*8/1000000,ipis,ipin,diff["eth_irq"]/d,diff["tx_dropped"],diff["tx_errors"],tpps,quality;
      }' "$OUT/${1}_begin.txt" "$OUT/${1}_end.txt" >> "$OUT/summary.csv" || fail "phase analysis failed"
}
phase() {
    _stage=$1; _cpu=$2; _start=$3
    wait_offset "$_start"
    validate_identity
    # Only ioeventfd changes between A1, B, A2.
    if [ "$(affinity "$IO_TID")" != "$_cpu" ]; then
        taskset -pc "$_cpu" "$IO_TID" >> "$OUT/actions.log" 2>&1 || fail "cannot bind ioeventfd"
    fi
    validate_layout "$_cpu"
    record_stage "${_stage}_start"
    echo "STAGE=$_stage ioeventfd=CPU$_cpu; vhost/eth0=CPU0"
    # Discard first 20 seconds after the transition, measure the next 30 seconds.
    wait_offset "$((_start + 20))"
    validate_layout "$_cpu"
    snapshot "$OUT/${_stage}_begin.txt"
    wait_offset "$((_start + 50))"
    snapshot "$OUT/${_stage}_end.txt"
    validate_layout "$_cpu"
    analyze_phase "$_stage" "$_cpu"
    record_stage "${_stage}_measured"
}
restore_settings() {
    RESTORE=OK
    if [ "$(thread_identity "$IO_TID")" = "$IO_ID" ]; then
        taskset -pc "$IO_ORIG" "$IO_TID" >> "$OUT/actions.log" 2>&1 || RESTORE=CHECK_REQUIRED
        [ "$(affinity "$IO_TID")" = "$IO_ORIG" ] || RESTORE=CHECK_REQUIRED
    else RESTORE=CHECK_REQUIRED; fi
    if [ "$(thread_identity "$VH_TID")" = "$VH_ID" ]; then
        taskset -pc "$VH_ORIG" "$VH_TID" >> "$OUT/actions.log" 2>&1 || RESTORE=CHECK_REQUIRED
        [ "$(affinity "$VH_TID")" = "$VH_ORIG" ] || RESTORE=CHECK_REQUIRED
    else RESTORE=CHECK_REQUIRED; fi
    for _irq in $IRQS; do
        if [ "$(irq_signature "$_irq")" = "$(cat "$OUT/irq_${_irq}.identity")" ]; then
            cat "$OUT/irq_${_irq}.affinity" > "$PROC/irq/$_irq/smp_affinity_list" || RESTORE=CHECK_REQUIRED
            [ "$(cat "$PROC/irq/$_irq/smp_affinity_list")" = "$(cat "$OUT/irq_${_irq}.affinity")" ] || RESTORE=CHECK_REQUIRED
        else RESTORE=CHECK_REQUIRED; fi
    done
}
write_feedback() {
    {
      echo "UDP_ABA_VERIFY version=1.0"
      echo "capture_status=$RESULT reason=$REASON"
      echo "restore_status=$RESTORE"
      echo "kernel=$(uname -r)"
      echo "io_tid=$IO_TID io_identity=$IO_ID original_affinity=$IO_ORIG"
      echo "vhost_tid=$VH_TID vhost_identity=$VH_ID original_affinity=$VH_ORIG"
      echo "phy=$PHY_IF tap=$TAP_IF eth_irq_ids=$IRQS fixed_irq_cpu=0 fixed_vhost_cpu=0"
      echo "declared_udp_payload_bytes=$PAYLOAD_BYTES flow_detected_uptime_s=${FLOW_T0:-NA}"
      echo "NOTE: TX payload Mbps is estimated from packets, NOT PC receiver Mbps."
      echo "NOTE: IPI counts are Linux-visible function-call entries from /proc/interrupts; no timing probe enabled."
      echo "NOTE: Phase times are relative to traffic detection, not an exact iperf timestamp."
      echo "=== Phase summary ==="
      cat "$OUT/summary.csv"
      echo "=== Transitions ==="
      cat "$OUT/stages.csv"
      if [ "$RESULT" = OK ]; then
        echo "=== Derived endpoint-average comparison ==="
        awk -F, 'NR>1{p[$1]=$6;ip[$1]=$8;q[$1]=$14}
          END{if(p["A1"]>0&&p["A2"]>0&&p["B"]>0){
           ref=(p["A1"]+p["A2"])/2;dr=p["A2"]-p["A1"];if(dr<0)dr=-dr;
           printf "A_ref_pps=%.3f\nB_gain_percent=%.3f\nA_return_difference_percent=%.3f\n",ref,100*(p["B"]-ref)/ref,100*dr/ref;
           if(ip["A1"]!="NA"&&ip["A2"]!="NA"&&ip["B"]!="NA"&&(ip["A1"]+ip["A2"])>0)
             printf "B_function_call_IPI_rate_reduction_percent=%.3f\n",100*(1-ip["B"]/((ip["A1"]+ip["A2"])/2));
           printf "phase_quality=A1:%s B:%s A2:%s\n",q["A1"],q["B"],q["A2"];
           print "Interpret jointly with PC interval rates/loss. These are not a pure IPI causal percentage."}}' "$OUT/summary.csv"
      fi
    } > "$OUT/feedback.txt"
}
cleanup() {
    _exit=$?
    trap - 0 INT TERM HUP
    [ -z "$SLEEP_PID" ] || { kill "$SLEEP_PID" 2>/dev/null || :; wait "$SLEEP_PID" 2>/dev/null || :; }
    if [ -n "$OUT" ] && [ -d "$OUT" ]; then
        [ "$CHANGED" -eq 0 ] || restore_settings
        if [ "$RESULT" != OK ] && [ -z "$REASON" ]; then RESULT=FAILED; REASON="exit_$_exit"; fi
        write_feedback
        echo "OUTPUT_DIR=$OUT"
        echo "FEEDBACK=$OUT/feedback.txt"
        echo "RESTORE_STATUS=$RESTORE"
        if [ "$RESTORE" != OK ] && [ "$RESTORE" != NOT_NEEDED ]; then
            echo "WARNING: restore needs manual checking; backups are in OUTPUT_DIR." >&2
            _exit=1
        fi
    fi
    [ "$LOCKED" -eq 0 ] || rmdir "$LOCK" 2>/dev/null || :
    exit "$_exit"
}

[ "$#" -eq 2 ] || { usage; exit 2; }
IO_TID=$1; VH_TID=$2
for _n in "$IO_TID" "$VH_TID" "$START_PPS" "$WAIT_TIMEOUT" "$PAYLOAD_BYTES"; do
    case "$_n" in ''|*[!0-9]*) echo "Numeric arguments must be positive integers" >&2; exit 2;; esac
    [ "$_n" -gt 0 ] || exit 2
done
[ "$IO_TID" != "$VH_TID" ] || { echo "Two different TIDs are required" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "Run in ServerVM as root" >&2; exit 1; }
for _cmd in awk taskset sleep cat mkdir date; do command -v "$_cmd" >/dev/null 2>&1 || { echo "Missing $_cmd" >&2; exit 1; }; done
IO_ID=$(thread_identity "$IO_TID") || { echo "Cannot read ioeventfd task" >&2; exit 1; }
VH_ID=$(thread_identity "$VH_TID") || { echo "Cannot read vhost task" >&2; exit 1; }
case "$IO_ID" in *ioeventfd*) ;; *) echo "TID $IO_TID is not named ioeventfd" >&2; exit 1;; esac
case "$VH_ID" in vhost-*) ;; *) echo "TID $VH_TID is not named vhost-*" >&2; exit 1;; esac
# Multiple vhost workers must be resolved by the user from the existing VM mapping.
IRQS=$(awk -v dev="$PHY_IF" '$1~/^[0-9]+:$/ {for(i=2;i<=NF;i++)if($i==dev){q=$1;sub(/:$/,"",q);printf "%s ",q;break}}' "$PROC/interrupts")
[ -n "$IRQS" ] || { echo "No IRQ explicitly labelled $PHY_IF; refusing to guess an IRQ number" >&2; exit 1; }
IO_ORIG=$(affinity "$IO_TID"); VH_ORIG=$(affinity "$VH_TID")
[ -n "$IO_ORIG" ] && [ -n "$VH_ORIG" ] || exit 1
for _irq in $IRQS; do
    [ -r "$PROC/irq/$_irq/smp_affinity_list" ] && [ -r "$PROC/irq/$_irq/effective_affinity_list" ] || { echo "Missing IRQ affinity interface for $_irq" >&2; exit 1; }
done
[ -d "$BASE_DIR" ] || mkdir -p "$BASE_DIR" || exit 1
mkdir "$LOCK" 2>/dev/null || { echo "Another ABA script may be active: $LOCK (do not delete while active)" >&2; exit 1; }
LOCKED=1
trap cleanup 0
trap 'RESULT=ABORTED; REASON=signal; exit 130' INT
trap 'RESULT=ABORTED; REASON=signal; exit 143' TERM HUP
OUT="$BASE_DIR/udp_aba_$(date +%Y%m%d_%H%M%S)_$$"
mkdir "$OUT" || fail "cannot create output directory"
printf 'stage,io_cpu,measure_start_after_detect_s,measure_end_after_detect_s,measure_seconds,eth_tx_pps,tx_payload_mbps_est,ipi1_per_s,ipi1_per_10k_tx,eth_irq_per_s,eth_tx_dropped,eth_tx_errors,tap_rx_pps,quality\n' > "$OUT/summary.csv"
echo 'event,uptime_s,seconds_after_flow_detection,io_cpu,vhost_cpu' > "$OUT/stages.csv"
: > "$OUT/actions.log"
printf '%s\n' "$IO_ORIG" > "$OUT/io_affinity.before"
printf '%s\n' "$VH_ORIG" > "$OUT/vhost_affinity.before"
for _irq in $IRQS; do
    irq_signature "$_irq" > "$OUT/irq_${_irq}.identity" || fail "IRQ identity unavailable"
    cat "$PROC/irq/$_irq/smp_affinity_list" > "$OUT/irq_${_irq}.affinity" || fail "IRQ backup failed"
done
# Stop already-existing probes. They remain disabled after this script exits.
# Other capture scripts must not be running and restart them during the test.
for _p in "$PROC/r6_notify" "$PROC/ipi_origin" "$PROC/vhost_n5"; do
    [ ! -e "$_p" ] || { echo stop > "$_p" || fail "cannot stop $_p"; }
done
for _p in "$SYS"/module/*/parameters/ioem_run "$SYS"/module/*/parameters/n4_run; do
    [ ! -e "$_p" ] || { echo 0 > "$_p" || fail "cannot disable $_p"; }
done
# No global tracing settings are changed; stop independent trace collectors first.
CHANGED=1
RESULT=RUNNING
taskset -pc 1 "$IO_TID" >> "$OUT/actions.log" 2>&1 || fail "cannot set initial ioeventfd CPU1"
taskset -pc 0 "$VH_TID" >> "$OUT/actions.log" 2>&1 || fail "cannot bind vhost CPU0"
for _irq in $IRQS; do echo 0 > "$PROC/irq/$_irq/smp_affinity_list" || fail "IRQ affinity write failed"; done
validate_layout 1
# Require an idle network before READY, avoiding attachment to an old iperf run.
flow_read || fail "cannot read interface counters"; PREV=$FLOW_SAMPLE
nap 1
flow_read || fail "cannot read interface counters"
RATE=$(flow_rate "$PREV" "$FLOW_SAMPLE") || fail "invalid counter/time delta"
awk -v p="$RATE" -v lim="$START_PPS" 'BEGIN{exit !(p<lim)}' || fail "traffic already active; stop old iperf, then restart script"
echo "READY: now start ONE 180-second Android UDP test. Auto-switch near 60s and 120s."
echo "OUTPUT_DIR=$OUT"
read_clock || fail "cannot read uptime"; WAIT_BEGIN=$CLOCK
while :; do
    PREV=$FLOW_SAMPLE
    nap 1
    flow_read || fail "interface disappeared"
    RATE=$(flow_rate "$PREV" "$FLOW_SAMPLE") || fail "counter reset during wait"
    if awk -v p="$RATE" -v lim="$START_PPS" 'BEGIN{exit !(p>=lim)}'; then break; fi
    awk -v n="$CLOCK" -v s="$WAIT_BEGIN" -v lim="$WAIT_TIMEOUT" 'BEGIN{exit !(n-s<lim)}' || fail "timed out waiting for Android traffic"
done
FLOW_T0=$CLOCK
record_stage traffic_detected
echo "TRAFFIC_DETECTED: min(eth0 TX, tap1 RX)=$RATE packets/s"
phase A1 1 0
phase B 0 60
phase A2 1 120
# All measurements finish ~170s after detection; hold A2 until iperf ends.
# This avoids restoring affinity during the measured period or the last iperf intervals.
echo "MEASUREMENTS_DONE: waiting for Android traffic to end before restoring affinity..."
flow_read || fail "cannot read final traffic state"; HOLD_BEGIN=$CLOCK; LOW=0
while :; do
    PREV=$FLOW_SAMPLE; nap 1; flow_read || fail "interface disappeared at finish"
    RATE=$(flow_rate "$PREV" "$FLOW_SAMPLE") || fail "counter reset at finish"
    if awk -v p="$RATE" -v lim="$START_PPS" 'BEGIN{exit !(p<lim)}'; then LOW=$((LOW+1)); else LOW=0; fi
    [ "$LOW" -lt 2 ] || break
    if ! awk -v n="$CLOCK" -v s="$HOLD_BEGIN" 'BEGIN{exit !(n-s<40)}'; then
        REASON="traffic_still_active_after_measurements; restore occurred outside measured windows"; break
    fi
done
validate_layout 1
RESULT=OK
if awk -F, 'NR>1&&$14!="OK"{bad=1}END{exit !bad}' "$OUT/summary.csv"; then
    RESULT=CHECK_REQUIRED; REASON="inspect phase quality flags"
fi
record_stage before_restore
exit 0

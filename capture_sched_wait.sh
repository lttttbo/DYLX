#!/bin/sh
# Separate run from n4/ipi_origin/ioem captures. Only a private trace instance.
# Do not use SECONDS: some shells implement it as a changing timer.
set -eu
[ "$#" -ge 3 ] || { echo "Usage: sh $0 IOEVENT_TID VHOST_TID LABEL [TRACE_SECONDS=0.10]" >&2; exit 2; }
IO=$1; VH=$2; LABEL=$3; TRACE_SECONDS=${4:-0.10}
for v in "$IO" "$VH"; do case "$v" in ''|*[!0-9]*|0) echo "Invalid TID $v" >&2; exit 2;; esac; done
case "$LABEL" in ''|*[!A-Za-z0-9_-]*) echo "Invalid label" >&2; exit 2;; esac
awk -v s="$TRACE_SECONDS" 'BEGIN { if(s !~ /^[0-9]+([.][0-9]+)?$/ || s+0<=0 || s+0>1) exit 1; }' || {
 echo "Trace duration must be >0 and <=1 second" >&2; exit 2;
}
[ -r "/proc/$IO/status" ] && [ -r "/proc/$VH/status" ] || { echo "Missing target TID" >&2; exit 1; }
TR=/sys/kernel/tracing
[ -d "$TR/events" ] || TR=/sys/kernel/debug/tracing
[ -d "$TR/instances" ] || { echo "No trace instances at $TR" >&2; exit 1; }
INS="$TR/instances/n4wait_$$"
OUT=${OUT_BASE:-/tmp/notify_round4}/"${LABEL}_sched_$(date +%Y%m%d_%H%M%S)_$$"
mkdir -p "$OUT"
mkdir "$INS"
cleanup() {
 echo 0 > "$INS/tracing_on" 2>/dev/null || :
 echo 0 > "$INS/events/enable" 2>/dev/null || :
 rmdir "$INS" 2>/dev/null || :
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo 0 > "$INS/tracing_on"
echo nop > "$INS/current_tracer"
for e in sched_waking sched_wakeup sched_switch; do
 [ -f "$INS/events/sched/$e/format" ] || { echo "Missing event: $e" >&2; exit 1; }
 cat "$INS/events/sched/$e/format" > "$OUT/${e}_format.txt"
done
# Cross-CPU timestamp comparison requires a common clock, not per-CPU local.
echo mono > "$INS/trace_clock"
cat "$INS/trace_clock" > "$OUT/trace_clock.txt"
echo "${BUFFER_KB:-2048}" > "$INS/buffer_size_kb"
echo "pid == $IO || pid == $VH" > "$INS/events/sched/sched_waking/filter"
echo "pid == $IO || pid == $VH" > "$INS/events/sched/sched_wakeup/filter"
echo "prev_pid == $IO || next_pid == $IO || prev_pid == $VH || next_pid == $VH" > "$INS/events/sched/sched_switch/filter"
for e in sched_waking sched_wakeup sched_switch; do
 cat "$INS/events/sched/$e/filter" > "$OUT/${e}_filter.txt"
 echo 1 > "$INS/events/sched/$e/enable"
done
{
 echo "io_tid=$IO vhost_tid=$VH requested_seconds=$TRACE_SECONDS"
 uname -a
 for t in "$IO" "$VH"; do cat "/proc/$t/comm"; grep -E '^(Pid|Cpus_allowed_list):' "/proc/$t/status"; done
} > "$OUT/context.txt"
: > "$INS/trace"
echo 1 > "$INS/tracing_on"
sleep "$TRACE_SECONDS"
echo 0 > "$INS/tracing_on"
sleep "${REPORT_DELAY:-60}"
cat "$INS/trace" > "$OUT/trace.txt"
for p in "$INS"/per_cpu/cpu*/stats; do
 [ -r "$p" ] || continue
 c=${p%/stats}; c=${c##*/}
 cat "$p" > "$OUT/${c}_stats.txt"
done
cleanup
trap - EXIT INT TERM
echo "OUTPUT_DIR=$OUT"
echo "Analyze on PC: python3 analyze_sched_wait.py $OUT $IO $VH"

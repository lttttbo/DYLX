/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Temporary, source-integrated Linux 5.15 call-function origin profiler.
 * Include ONCE in kernel/smp.c, after its normal includes.
 * Read README.md before integration. This is NOT a loadable probe module.
 *
 * Receiver observes an already detached call_single_queue BEFORE callbacks
 * run/unlock/recycle their objects. Producer metadata is copied BEFORE llist_add.
 * No callback is called, no queue is changed, and no event is printed here.
 * Not for NMI use. Intended for a controlled debug kernel, not production.
 */
#ifndef _DEBUG_IPI_ORIGIN_PROBE_H
#define _DEBUG_IPI_ORIGIN_PROBE_H

#include <linux/init.h>
#include <linux/smp.h>
#include <linux/smp_types.h>
#include <linux/percpu.h>
#include <linux/interrupt.h>
#include <linux/irq_work.h>
#include <linux/sched.h>
#include <linux/sched/task.h>
#include <linux/seq_file.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/mutex.h>
#include <linux/spinlock.h>
#include <linux/hash.h>
#include <linux/ktime.h>
#include <linux/string.h>

#define IPIO_BITS 7
#define IPIO_SLOTS (1U << IPIO_BITS)

enum ipio_kind {
	IPIO_ASYNC, IPIO_SYNC, IPIO_IRQ_WORK, IPIO_TTWU, IPIO_OTHER,
	IPIO_KINDS
};
static const char * const ipio_kind_names[] = {
	"ASYNC", "SYNC", "IRQ_WORK", "TTWU", "OTHER"
};

/* Names are best-effort labels; keys use numeric IDs/function addresses. */
struct ipio_key {
	unsigned long func;
	unsigned long caller;
	pid_t source_tid;
	pid_t target_tid;
	int dest_cpu;
	u8 kind;
	u8 context; /* RX: 1=inside generic call-IPI handler, 0=other drain.
		     * ENQ: bit0=hardirq, bit1=serving softirq. */
};
struct ipio_row {
	struct ipio_key key;
	u64 count;
	char source_comm[TASK_COMM_LEN];
	char target_comm[TASK_COMM_LEN];
};
struct ipio_data {
	u64 irq_handler_calls;
	u64 batches[2][1U << IPIO_KINDS];
	u64 items[2][IPIO_KINDS];
	u64 rx_overflow;
	u64 enqueue_overflow;
	struct ipio_row rx[IPIO_SLOTS];
	struct ipio_row enq[IPIO_SLOTS];
};
struct ipio_cpu {
	raw_spinlock_t lock;
	struct ipio_data data;
};
static DEFINE_PER_CPU(struct ipio_cpu, ipio_cpus);
/* Scope marker maintained even while collection is off; never reset by users. */
static DEFINE_PER_CPU(unsigned int, ipio_handler_depth);
static DEFINE_MUTEX(ipio_control_lock);
static bool ipio_enabled;
static bool ipio_sources;
static u64 ipio_start_ns, ipio_stop_ns;
static struct proc_dir_entry *ipio_proc;

static unsigned int ipio_decode(struct llist_node *n,
			       struct task_struct **task,
			       unsigned long *func)
{
	struct __call_single_node *common;
	unsigned int type;
	*task = NULL;
	*func = 0;
	common = container_of(n, struct __call_single_node, llist);
	type = READ_ONCE(common->u_flags) & CSD_FLAG_TYPE_MASK;
	switch (type) {
	case CSD_TYPE_TTWU:
		*task = container_of(n, struct task_struct, wake_entry.llist);
		return IPIO_TTWU;
	case CSD_TYPE_SYNC:
	case CSD_TYPE_ASYNC: {
		call_single_data_t *csd;
		csd = container_of(n, call_single_data_t, node.llist);
		*func = (unsigned long)READ_ONCE(csd->func);
		return type == CSD_TYPE_SYNC ? IPIO_SYNC : IPIO_ASYNC;
	}
	case CSD_TYPE_IRQ_WORK: {
		struct irq_work *work;
		work = container_of(n, struct irq_work, node.llist);
		*func = (unsigned long)READ_ONCE(work->func);
		return IPIO_IRQ_WORK;
	}
	default:
		return IPIO_OTHER; /* Never dereference unknown payloads. */
	}
}

static void ipio_copy_comm(char *dest, const struct task_struct *p)
{
	unsigned int i;
	if (!p) {
		dest[0] = '-'; dest[1] = '\0';
		return;
	}
	/* Avoid taking task_lock from the call-function/IRQ path. Rename may race;
	 * TID remains the identity used by this short-window diagnostic. */
	for (i = 0; i < TASK_COMM_LEN - 1; i++) {
		char c = READ_ONCE(p->comm[i]);
		dest[i] = (c == ',' || c == '"' || c == '\n' ||
			   c == '\r' || c == '\t') ? '_' : c;
	}
	dest[TASK_COMM_LEN - 1] = '\0';
}

static bool ipio_same_key(const struct ipio_key *a, const struct ipio_key *b)
{
	return a->func == b->func && a->caller == b->caller &&
	       a->source_tid == b->source_tid && a->target_tid == b->target_tid &&
	       a->dest_cpu == b->dest_cpu && a->kind == b->kind &&
	       a->context == b->context;
}

static void ipio_add(struct ipio_row *table, const struct ipio_key *key,
		     const struct task_struct *source,
		     const struct task_struct *target, u64 *overflow)
{
	unsigned long h = key->func ^ (key->caller >> 3) ^
		((unsigned long)(u32)key->source_tid << 7) ^
		((unsigned long)(u32)key->target_tid << 1) ^
		((unsigned long)(u32)key->dest_cpu << 11) ^
		((unsigned long)key->kind << 4) ^ key->context;
	unsigned int slot = hash_long(h, IPIO_BITS), i;
	for (i = 0; i < IPIO_SLOTS; i++) {
		struct ipio_row *row = &table[(slot + i) & (IPIO_SLOTS - 1)];
		if (!row->count) {
			row->key = *key;
			ipio_copy_comm(row->source_comm, source);
			ipio_copy_comm(row->target_comm, target);
			row->count = 1;
			return;
		}
		if (ipio_same_key(&row->key, key)) {
			row->count++;
			return;
		}
	}
	(*overflow)++; /* Totals still count; attribution is incomplete. */
}

/* Hooks A/B: wrap ONLY generic_smp_call_function_single_interrupt().
 * Original contract: IRQs are disabled. No change to existing IRQ state. */
static void ipio_irq_enter(void)
{
	struct ipio_cpu *pc;
	__this_cpu_inc(ipio_handler_depth);
	if (!READ_ONCE(ipio_enabled))
		return;
	pc = this_cpu_ptr(&ipio_cpus);
	raw_spin_lock(&pc->lock);
	if (READ_ONCE(ipio_enabled))
		pc->data.irq_handler_calls++;
	raw_spin_unlock(&pc->lock);
}
static void ipio_irq_exit(void)
{
	__this_cpu_dec(ipio_handler_depth);
}

/* Hook C: once per detached batch, BEFORE any callback/unlock.
 * Call just after entry = llist_reverse_order(entry).
 * Queue items are counted, NOT inferred from sched_waking totals. */
static void ipio_note_batch(struct llist_node *entry)
{
	struct ipio_cpu *pc;
	struct llist_node *n;
	unsigned int mask = 0, ctx;
	if (!READ_ONCE(ipio_enabled) || in_nmi())
		return;
	pc = this_cpu_ptr(&ipio_cpus);
	ctx = __this_cpu_read(ipio_handler_depth) ? 1 : 0;
	raw_spin_lock(&pc->lock); /* Caller must already have IRQs disabled. */
	if (!READ_ONCE(ipio_enabled))
		goto out;
	for (n = entry; n; n = n->next) {
		struct task_struct *target;
		struct ipio_key key = { 0 };
		key.kind = ipio_decode(n, &target, &key.func);
		key.context = ctx;
		key.target_tid = target ? task_pid_nr(target) : 0;
		key.dest_cpu = raw_smp_processor_id();
		pc->data.items[ctx][key.kind]++;
		mask |= 1U << key.kind;
		ipio_add(pc->data.rx, &key, NULL, target, &pc->data.rx_overflow);
	}
	pc->data.batches[ctx][mask]++;
out:
	raw_spin_unlock(&pc->lock);
}

/* Optional Hook D: __smp_call_single_queue(), BEFORE publication via llist_add.
 * Records queue requests only. Multi-target calls can bypass this function.
 * Current task in interrupt context is not necessarily the business waker.
 * caller is captured at the call site using (unsigned long)_RET_IP_. */
static void __maybe_unused ipio_note_enqueue(int dest, struct llist_node *n,
					    unsigned long caller)
{
	struct ipio_cpu *pc;
	struct task_struct *target;
	struct ipio_key key = { 0 };
	unsigned long flags;
	if (!READ_ONCE(ipio_enabled) || !READ_ONCE(ipio_sources) || in_nmi())
		return;
	key.kind = ipio_decode(n, &target, &key.func);
	key.caller = caller;
	key.dest_cpu = dest;
	key.target_tid = target ? task_pid_nr(target) : 0;
	key.source_tid = task_pid_nr(current);
	key.context = (in_irq() ? 1 : 0) | (in_serving_softirq() ? 2 : 0);
	local_irq_save(flags);
	pc = this_cpu_ptr(&ipio_cpus);
	raw_spin_lock(&pc->lock);
	if (READ_ONCE(ipio_enabled) && READ_ONCE(ipio_sources))
		ipio_add(pc->data.enq, &key, current, target,
			 &pc->data.enqueue_overflow);
	raw_spin_unlock(&pc->lock);
	local_irq_restore(flags);
}

/* Control runs outside the measured IRQ path. Private per-CPU locks allow
 * stop/reset/read without sending cross-CPU calls to synchronize counters. */
static void ipio_quiesce(void)
{
	int cpu;
	unsigned long flags;
	WRITE_ONCE(ipio_enabled, false);
	for_each_possible_cpu(cpu) {
		struct ipio_cpu *pc = &per_cpu(ipio_cpus, cpu);
		raw_spin_lock_irqsave(&pc->lock, flags);
		raw_spin_unlock_irqrestore(&pc->lock, flags);
	}
}

static ssize_t ipio_write(struct file *file, const char __user *user,
			  size_t len, loff_t *pos)
{
	char buf[32];
	char *cmd;
	int cpu;
	unsigned long flags;
	if (!len || len >= sizeof(buf))
		return -EINVAL;
	if (copy_from_user(buf, user, len))
		return -EFAULT;
	buf[len] = '\0';
	cmd = strim(buf);
	if (strcmp(cmd, "start") && strcmp(cmd, "start_sources") &&
	    strcmp(cmd, "stop"))
		return -EINVAL;
	mutex_lock(&ipio_control_lock);
	ipio_quiesce();
	ipio_stop_ns = ktime_get_ns();
	if (strcmp(cmd, "stop")) {
		for_each_possible_cpu(cpu) {
			struct ipio_cpu *pc = &per_cpu(ipio_cpus, cpu);
			raw_spin_lock_irqsave(&pc->lock, flags);
			memset(&pc->data, 0, sizeof(pc->data));
			raw_spin_unlock_irqrestore(&pc->lock, flags);
		}
		WRITE_ONCE(ipio_sources, !strcmp(cmd, "start_sources"));
		ipio_start_ns = ktime_get_ns();
		ipio_stop_ns = 0;
		WRITE_ONCE(ipio_enabled, true);
	}
	mutex_unlock(&ipio_control_lock);
	return len;
}

static int ipio_show(struct seq_file *m, void *unused)
{
	struct ipio_data *d;
	unsigned int cpu, ctx, i;
	unsigned long flags;
	int ret = 0;
	mutex_lock(&ipio_control_lock);
	if (READ_ONCE(ipio_enabled)) {
		ret = -EBUSY; /* Deliberately prohibit polling while collecting. */
		goto done;
	}
	d = kmalloc(sizeof(*d), GFP_KERNEL);
	if (!d) { ret = -ENOMEM; goto done; }
	seq_puts(m, "# ipi_origin v1; items/batches/IRQ entries are distinct counts\n");
	seq_printf(m, "# sources=%u start_ns=%llu stop_ns=%llu\n",
		   ipio_sources, (unsigned long long)ipio_start_ns,
		   (unsigned long long)ipio_stop_ns);
	seq_puts(m, "# BATCH bits: ASYNC=1 SYNC=2 IRQ_WORK=4 TTWU=8 OTHER=16; mask0=empty\n");
	seq_puts(m, "# RX context: ipi=inside generic call-IPI handler; other=non-IPI drain\n");
	seq_puts(m, "# ENQ context: task/hardirq/softirq; ENQ is not a physical IPI-send count\n");
	seq_puts(m, "# CPU,cpu,irq_handler_calls,rx_key_overflow,enqueue_key_overflow\n");
	seq_puts(m, "# ITEMS,cpu,context,ASYNC,SYNC,IRQ_WORK,TTWU,OTHER\n");
	seq_puts(m, "# BATCH,cpu,context,mask,batches\n");
	seq_puts(m, "# RX,cpu,context,type,target_tid,target_comm,func_addr,func_symbol,count\n");
	seq_puts(m, "# ENQ,src_cpu,dst_cpu,type,source_tid,source_comm,context,target_tid,target_comm,func_addr,func_symbol,caller_addr,caller_symbol,count\n");
	for_each_possible_cpu(cpu) {
		struct ipio_cpu *pc = &per_cpu(ipio_cpus, cpu);
		raw_spin_lock_irqsave(&pc->lock, flags);
		memcpy(d, &pc->data, sizeof(*d));
		raw_spin_unlock_irqrestore(&pc->lock, flags);
		seq_printf(m, "CPU,%u,%llu,%llu,%llu\n", cpu,
			(unsigned long long)d->irq_handler_calls,
			(unsigned long long)d->rx_overflow,
			(unsigned long long)d->enqueue_overflow);
		for (ctx = 0; ctx < 2; ctx++) {
			seq_printf(m, "ITEMS,%u,%s", cpu, ctx ? "ipi" : "other");
			for (i = 0; i < IPIO_KINDS; i++)
				seq_printf(m, ",%llu", (unsigned long long)d->items[ctx][i]);
			seq_putc(m, '\n');
			for (i = 0; i < (1U << IPIO_KINDS); i++)
				if (d->batches[ctx][i])
					seq_printf(m, "BATCH,%u,%s,0x%x,%llu\n", cpu,
						ctx ? "ipi" : "other", i,
						(unsigned long long)d->batches[ctx][i]);
		}
		for (i = 0; i < IPIO_SLOTS; i++) {
			struct ipio_row *r = &d->rx[i];
			if (!r->count) continue;
			seq_printf(m, "RX,%u,%s,%s,%d,%s,0x%lx,%ps,%llu\n", cpu,
				r->key.context ? "ipi" : "other", ipio_kind_names[r->key.kind],
				r->key.target_tid, r->target_comm, r->key.func,
				(void *)r->key.func, (unsigned long long)r->count);
		}
		for (i = 0; i < IPIO_SLOTS; i++) {
			struct ipio_row *r = &d->enq[i];
			const char *context;
			if (!r->count) continue;
			context = (r->key.context & 1) ? "hardirq" :
				  (r->key.context & 2) ? "softirq" : "task";
			seq_printf(m, "ENQ,%u,%d,%s,%d,%s,%s,%d,%s,0x%lx,%ps,0x%lx,%ps,%llu\n",
				cpu, r->key.dest_cpu, ipio_kind_names[r->key.kind],
				r->key.source_tid, r->source_comm, context,
				r->key.target_tid, r->target_comm,
				r->key.func, (void *)r->key.func,
				r->key.caller, (void *)r->key.caller,
				(unsigned long long)r->count);
		}
	}
	kfree(d);
done:
	mutex_unlock(&ipio_control_lock);
	return ret;
}
static int ipio_open(struct inode *inode, struct file *file)
{
	return single_open(file, ipio_show, NULL);
}
static const struct proc_ops ipio_ops = {
	.proc_open = ipio_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
	.proc_write = ipio_write,
};
static int __init ipio_init(void)
{
	int cpu;
	for_each_possible_cpu(cpu)
		raw_spin_lock_init(&per_cpu(ipio_cpus, cpu).lock);
	ipio_proc = proc_create("ipi_origin", 0600, NULL, &ipio_ops);
	return ipio_proc ? 0 : -ENOMEM;
}
#ifndef IPIO_NO_AUTO_INIT
late_initcall(ipio_init);
#endif
#endif

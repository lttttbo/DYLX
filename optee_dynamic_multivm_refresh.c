
// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * OP-TEE mediator for Xvisor
 *
 * Target:
 *   - multi-guest (up to OPTEE_MAX_GUESTS) support
 *   - require secure-world virtualization + dynamic SHM
 *   - Xen-like mediation for:
 *       * EXCHANGE_CAPABILITIES
 *       * CALL_WITH_ARG
 *       * CALL_RETURN_FROM_RPC
 *       * RPC ALLOC/FREE/CMD
 *       * NONCONTIG pagelist translation (guest IPA -> host PA)
 *
 * Assumptions / places you may need to adjust to your Xvisor tree:
 *   1) vmm_host_ram_alloc()/free() exist and return host PA
 *   2) vmm_host_memmap()/memunmap() exist with mem_flags argument
 *   3) vmm_guest_physical_map() translates guest IPA -> host PA and returns
 *      region size + flags; VMM_REGION_ISRAM is defined for RAM regions
 *   4) arm_guest_priv(guest)->tee is available for per-guest opaque pointer
 *
 * This file intentionally does NOT support static reserved SHM for guests.
 * Guests are forced onto Dynamic SHM (REGISTER_SHM / NONCONTIG).
 */

#include <vmm_error.h>
#include <vmm_stdio.h>
#include <vmm_compiler.h>
#include <vmm_spinlocks.h>
#include <vmm_heap.h>
#include <vmm_manager.h>
#include <vmm_host_aspace.h>
#include <vmm_host_ram.h>
#include <vmm_guest_aspace.h>
#include <cpu_vcpu_helper.h>
#include <arch_regs.h>

#include <tee.h>
#include <smccc.h>
#include <optee_msg.h>
#include <optee_smc.h>
#include <optee_rpc_cmd.h>

typedef unsigned long uintptr_t;

/* -------------------------------------------------------------------------- */
/* Compatibility glue for older vendor trees */

#ifndef OPTEE_SMC_SEC_CAP_VIRTUALIZATION
#define OPTEE_SMC_SEC_CAP_VIRTUALIZATION    (1U << 3)
#endif
#ifndef OPTEE_SMC_SEC_CAP_RPC_ARG
#define OPTEE_SMC_SEC_CAP_RPC_ARG           (1U << 6)
#endif
#ifndef OPTEE_SMC_SEC_CAP_ASYNC_NOTIF
#define OPTEE_SMC_SEC_CAP_ASYNC_NOTIF       (1U << 5)
#endif
#ifndef OPTEE_SMC_RETURN_UNKNOWN_FUNCTION
#define OPTEE_SMC_RETURN_UNKNOWN_FUNCTION   0xFFFFFFFFU
#endif
#ifndef OPTEE_SMC_RETURN_RPC_PREFIX
#define OPTEE_SMC_RETURN_RPC_PREFIX         0xFFFF0000U
#endif
#ifndef OPTEE_SMC_RETURN_RPC_ALLOC
#define OPTEE_SMC_RETURN_RPC_ALLOC          (OPTEE_SMC_RETURN_RPC_PREFIX | OPTEE_SMC_RPC_FUNC_ALLOC)
#endif
#ifndef OPTEE_SMC_RETURN_RPC_FREE
#define OPTEE_SMC_RETURN_RPC_FREE           (OPTEE_SMC_RETURN_RPC_PREFIX | OPTEE_SMC_RPC_FUNC_FREE)
#endif
#ifndef OPTEE_SMC_RETURN_RPC_CMD
#define OPTEE_SMC_RETURN_RPC_CMD            (OPTEE_SMC_RETURN_RPC_PREFIX | OPTEE_SMC_RPC_FUNC_CMD)
#endif
#ifndef OPTEE_SMC_RETURN_IS_RPC
#define OPTEE_SMC_RETURN_IS_RPC(ret) \
	((((u32)(ret)) & OPTEE_SMC_RETURN_RPC_PREFIX) == OPTEE_SMC_RETURN_RPC_PREFIX)
#endif
#ifndef OPTEE_SMC_RETURN_GET_RPC_FUNC
#define OPTEE_SMC_RETURN_GET_RPC_FUNC(ret)  (((u32)(ret)) & 0xFFFFU)
#endif

#ifndef OPTEE_MSG_GET_ARG_SIZE
#define OPTEE_MSG_GET_ARG_SIZE(num_params) \
	(sizeof(struct optee_msg_arg) + \
	 ((num_params) * sizeof(struct optee_msg_param)))
#endif

#ifndef OPTEE_MSG_ATTR_NONCONTIG
#define OPTEE_MSG_ATTR_NONCONTIG            (1U << 9)
#endif

#ifndef OPTEE_MSG_NONCONTIG_PAGE_SIZE
#define OPTEE_MSG_NONCONTIG_PAGE_SIZE       4096U
#endif

#ifndef OPTEE_MSG_ATTR_TYPE_MASK
#define OPTEE_MSG_ATTR_TYPE_MASK            0xFFU
#endif

#ifndef OPTEE_MSG_ATTR_TYPE_NONE
#define OPTEE_MSG_ATTR_TYPE_NONE            0x0
#define OPTEE_MSG_ATTR_TYPE_VALUE_INPUT     0x1
#define OPTEE_MSG_ATTR_TYPE_VALUE_OUTPUT    0x2
#define OPTEE_MSG_ATTR_TYPE_VALUE_INOUT     0x3
#define OPTEE_MSG_ATTR_TYPE_RMEM_INPUT      0x5
#define OPTEE_MSG_ATTR_TYPE_RMEM_OUTPUT     0x6
#define OPTEE_MSG_ATTR_TYPE_RMEM_INOUT      0x7
#define OPTEE_MSG_ATTR_TYPE_TMEM_INPUT      0x9
#define OPTEE_MSG_ATTR_TYPE_TMEM_OUTPUT     0xA
#define OPTEE_MSG_ATTR_TYPE_TMEM_INOUT      0xB
#endif

#ifndef OPTEE_MSG_CMD_OPEN_SESSION
#define OPTEE_MSG_CMD_OPEN_SESSION          0
#define OPTEE_MSG_CMD_INVOKE_COMMAND        1
#define OPTEE_MSG_CMD_CLOSE_SESSION         2
#define OPTEE_MSG_CMD_CANCEL                3
#define OPTEE_MSG_CMD_REGISTER_SHM          4
#define OPTEE_MSG_CMD_UNREGISTER_SHM        5
#endif

#ifndef TEEC_SUCCESS
#define TEEC_SUCCESS                        0x00000000
#define TEEC_ERROR_GENERIC                  0xFFFF0000
#define TEEC_ERROR_BAD_PARAMETERS           0xFFFF0006
#define TEEC_ERROR_OUT_OF_MEMORY            0xFFFF000C
#define TEEC_ERROR_COMMUNICATION            0xFFFF000E
#define TEEC_ORIGIN_COMMS                   0x00000002
#endif

#ifndef OPTEE_SMC_NSEC_CAP_UNIPROCESSOR
#define OPTEE_SMC_NSEC_CAP_UNIPROCESSOR     (1U << 0)
#endif
#ifndef OPTEE_SMC_SEC_CAP_HAVE_RESERVED_SHM
#define OPTEE_SMC_SEC_CAP_HAVE_RESERVED_SHM (1U << 0)
#define OPTEE_SMC_SEC_CAP_UNREGISTERED_SHM  (1U << 1)
#define OPTEE_SMC_SEC_CAP_DYNAMIC_SHM       (1U << 2)
#define OPTEE_SMC_SEC_CAP_MEMREF_NULL       (1U << 4)
#endif

/* -------------------------------------------------------------------------- */

#define OPTEE_KNOWN_NSEC_CAPS   (OPTEE_SMC_NSEC_CAP_UNIPROCESSOR)
#define OPTEE_KNOWN_SEC_CAPS    (OPTEE_SMC_SEC_CAP_HAVE_RESERVED_SHM | \
                                 OPTEE_SMC_SEC_CAP_UNREGISTERED_SHM  | \
                                 OPTEE_SMC_SEC_CAP_DYNAMIC_SHM       | \
                                 OPTEE_SMC_SEC_CAP_VIRTUALIZATION    | \
                                 OPTEE_SMC_SEC_CAP_MEMREF_NULL       | \
                                 OPTEE_SMC_SEC_CAP_RPC_ARG           | \
                                 OPTEE_SMC_SEC_CAP_ASYNC_NOTIF)

#define OPTEE_MEDIATOR_SMC_COUNT           12U

#define OPTEE_MAX_GUESTS                   8U
#define OPTEE_MAX_SHM_BUFS_DEFAULT         128U
#define OPTEE_MAX_SHM_PAGES_DEFAULT        2048U   /* ~8MB if 4K */
#define OPTEE_MAX_SHM_BUFFER_PG            129U

#ifndef VMM_PAGE_SIZE
#define VMM_PAGE_SIZE                      4096UL
#endif
#define OPTEE_PAGE_SIZE                    VMM_PAGE_SIZE
#define OPTEE_PAGE_MASK                    (~(OPTEE_PAGE_SIZE - 1UL))

#define OPTEE_NONCONTIG_ENTRIES_PER_PAGE   ((OPTEE_MSG_NONCONTIG_PAGE_SIZE / sizeof(u64)) - 1U)

/* -------------------------------------------------------------------------- */
/* Small helpers */

static inline unsigned long optee_align_down(unsigned long x, unsigned long a)
{
	return x & ~(a - 1UL);
}

static inline unsigned long optee_align_up(unsigned long x, unsigned long a)
{
	return (x + a - 1UL) & ~(a - 1UL);
}

static inline unsigned long optee_min_ul(unsigned long a, unsigned long b)
{
	return (a < b) ? a : b;
}

static inline u64 regpair_to_u64(u64 lo, u64 hi)
{
	return ((u64)(lo & 0xffffffffULL)) | (((u64)(hi & 0xffffffffULL)) << 32);
}

static inline void u64_to_regpair(u64 v, u64 *lo, u64 *hi)
{
	*lo = (u32)(v & 0xffffffffULL);
	*hi = (u32)((v >> 32) & 0xffffffffULL);
}

static inline void *optee_host_memmap_ptr(physical_addr_t pa, virtual_size_t sz)
{
	virtual_addr_t va = vmm_host_memmap(pa, sz, VMM_MEMORY_FLAGS_NORMAL);
	return (void *)(uintptr_t)va;
}

static inline void optee_host_memunmap_ptr(void *ptr)
{
	if (!ptr)
		return;
	(void)vmm_host_memunmap((virtual_addr_t)(uintptr_t)ptr);
}

/* -------------------------------------------------------------------------- */
/* Host-side page wrapper */

struct optee_host_page {
	physical_addr_t pa;
	void *va;
	physical_size_t sz;
};

static int optee_host_page_alloc(struct optee_host_page *pg, physical_size_t sz)
{
	int rc;
	physical_addr_t pa;

	if (!pg || !sz)
		return VMM_EINVALID;

	sz = optee_align_up(sz, OPTEE_PAGE_SIZE);

	rc = vmm_host_ram_alloc(&pa, sz, OPTEE_PAGE_SIZE);
	if (rc != VMM_OK)
		return rc;

	pg->va = optee_host_memmap_ptr(pa, sz);
	if (!pg->va) {
		vmm_host_ram_free(pa, sz);
		return VMM_ENOMEM;
	}

	vmm_memset(pg->va, 0, sz);
	pg->pa = pa;
	pg->sz = sz;

	return VMM_OK;
}

static void optee_host_page_free(struct optee_host_page *pg)
{
	if (!pg || !pg->va || !pg->sz)
		return;

	optee_host_memunmap_ptr(pg->va);
	vmm_host_ram_free(pg->pa, pg->sz);

	pg->pa = 0;
	pg->va = NULL;
	pg->sz = 0;
}

/* -------------------------------------------------------------------------- */
/* Guest IPA -> Host PA helpers */

static int optee_guest_pa_to_host_pa(struct vmm_guest *guest,
                                     physical_addr_t gpa,
                                     physical_addr_t *hpa)
{
	physical_size_t availsz = 0;
	u32 reg_flags = 0;
	int rc;

	if (!guest || !hpa)
		return VMM_EINVALID;

	rc = vmm_guest_physical_map(guest, gpa, 1, hpa, &availsz, &reg_flags);
	if (rc != VMM_OK)
		return rc;

#ifdef VMM_REGION_ISRAM
	if (!(reg_flags & VMM_REGION_ISRAM))
		return VMM_EACCESS;
#endif

	return VMM_OK;
}

static int optee_guest_read(struct vmm_guest *guest,
                            physical_addr_t gpa,
                            void *dst,
                            unsigned long len)
{
	unsigned long done = 0;

	if (!guest || (!dst && len))
		return VMM_EINVALID;

	while (done < len) {
		physical_addr_t hpa;
		physical_size_t availsz = 0;
		u32 reg_flags = 0;
		int rc;
		unsigned long chunk;
		void *hva;

		rc = vmm_guest_physical_map(guest, gpa + done, len - done,
		                            &hpa, &availsz, &reg_flags);
		if (rc != VMM_OK)
			return rc;

#ifdef VMM_REGION_ISRAM
		if (!(reg_flags & VMM_REGION_ISRAM))
			return VMM_EACCESS;
#endif

		chunk = optee_min_ul((unsigned long)availsz, len - done);
		hva = optee_host_memmap_ptr(hpa, chunk);
		if (!hva)
			return VMM_ENOMEM;

		vmm_memcpy((u8 *)dst + done, hva, chunk);
		optee_host_memunmap_ptr(hva);
		done += chunk;
	}

	return VMM_OK;
}

static int optee_guest_write(struct vmm_guest *guest,
                             physical_addr_t gpa,
                             const void *src,
                             unsigned long len)
{
	unsigned long done = 0;

	if (!guest || (!src && len))
		return VMM_EINVALID;

	while (done < len) {
		physical_addr_t hpa;
		physical_size_t availsz = 0;
		u32 reg_flags = 0;
		int rc;
		unsigned long chunk;
		void *hva;

		rc = vmm_guest_physical_map(guest, gpa + done, len - done,
		                            &hpa, &availsz, &reg_flags);
		if (rc != VMM_OK)
			return rc;

#ifdef VMM_REGION_ISRAM
		if (!(reg_flags & VMM_REGION_ISRAM))
			return VMM_EACCESS;
#endif

		chunk = optee_min_ul((unsigned long)availsz, len - done);
		hva = optee_host_memmap_ptr(hpa, chunk);
		if (!hva)
			return VMM_ENOMEM;

		vmm_memcpy(hva, (const u8 *)src + done, chunk);
		optee_host_memunmap_ptr(hva);
		done += chunk;
	}

	return VMM_OK;
}

/* -------------------------------------------------------------------------- */
/* Data structures */

enum optee_call_state {
	OPTEE_CALL_STATE_NORMAL = 0,
	OPTEE_CALL_STATE_XVISOR_RPC = 1,
};

struct optee_msg_noncontig_page {
	u64 pages[OPTEE_NONCONTIG_ENTRIES_PER_PAGE];
	u64 next;
};

struct optee_shm_buf {
	struct optee_shm_buf *next;
	u64 cookie;
	u32 page_cnt;

	u32 pg_list_cnt;
	struct optee_host_page *pg_list;
};

struct optee_shm_rpc {
	struct optee_shm_rpc *next;
	u64 cookie;

	physical_addr_t guest_cmd_gpa;
	struct optee_host_page xvisor_arg_pg;
};

struct optee_std_call {
	struct optee_std_call *next;

	physical_addr_t guest_arg_gpa;

	struct optee_host_page xvisor_arg_pg;
	struct optee_msg_arg *arg;

	u32 thread_id;
	bool in_flight;

	u32 rpc_func;
	u32 rpc_buffer_type;
	u64 rpc_data_cookie;

	enum optee_call_state state;
};

struct optee_ctx {
	u32 client_id;

	u32 max_calls;
	u32 max_shm_bufs;
	u32 max_shm_pages;

	u32 call_count;
	u32 shm_buf_count;
	u32 shm_page_count;

	vmm_spinlock_t lock;

	struct optee_std_call *calls;
	struct optee_shm_buf  *shm_bufs;
	struct optee_shm_rpc  *shm_rpcs;
};

/* -------------------------------------------------------------------------- */
/* Globals */

static vmm_spinlock_t optee_smc_lock;
static bool optee_smc_lock_init;

static u32  optee_host_sec_caps;
static bool optee_host_probe_done;
static bool optee_dyn_shm_supported;
static bool optee_virt_supported;
static u32  optee_rpc_max_params;
static u32  optee_max_threads = 1U;

/* -------------------------------------------------------------------------- */
/* Debug */

static void optee_dump_host_caps(u32 caps, unsigned long a2, unsigned long a3)
{
	vmm_init_printf("OPTEE: host sec_caps=0x%x a2=%#lx a3=%#lx\n", caps, a2, a3);
	if (caps & OPTEE_SMC_SEC_CAP_HAVE_RESERVED_SHM)
		vmm_init_printf("OPTEE:   - HAVE_RESERVED_SHM\n");
	if (caps & OPTEE_SMC_SEC_CAP_UNREGISTERED_SHM)
		vmm_init_printf("OPTEE:   - UNREGISTERED_SHM\n");
	if (caps & OPTEE_SMC_SEC_CAP_DYNAMIC_SHM)
		vmm_init_printf("OPTEE:   - DYNAMIC_SHM\n");
	if (caps & OPTEE_SMC_SEC_CAP_VIRTUALIZATION)
		vmm_init_printf("OPTEE:   - VIRTUALIZATION\n");
	if (caps & OPTEE_SMC_SEC_CAP_MEMREF_NULL)
		vmm_init_printf("OPTEE:   - MEMREF_NULL\n");
	if (caps & OPTEE_SMC_SEC_CAP_RPC_ARG)
		vmm_init_printf("OPTEE:   - RPC_ARG (max_params=%lu)\n", a3);
}

/* -------------------------------------------------------------------------- */
/* Lock init */

static inline void optee_lock_init_once(void)
{
	if (!optee_smc_lock_init) {
		INIT_SPIN_LOCK(&optee_smc_lock);
		optee_smc_lock_init = true;
	}
}

/* -------------------------------------------------------------------------- */
/* SMC wrappers */

static inline void optee_smc_call(u32 client_id,
                                  unsigned long a0, unsigned long a1,
                                  unsigned long a2, unsigned long a3,
                                  unsigned long a4, unsigned long a5,
                                  unsigned long a6,
                                  struct arm_smccc_res *res)
{
	vmm_spin_lock(&optee_smc_lock);
	arm_smccc_smc(a0, a1, a2, a3, a4, a5, a6, (unsigned long)client_id, res);
	vmm_spin_unlock(&optee_smc_lock);
}

static inline void optee_smc_call_host(unsigned long a0, unsigned long a1,
                                       unsigned long a2, unsigned long a3,
                                       unsigned long a4, unsigned long a5,
                                       unsigned long a6,
                                       struct arm_smccc_res *res)
{
	vmm_spin_lock(&optee_smc_lock);
	arm_smccc_smc(a0, a1, a2, a3, a4, a5, a6, 0 /* a7=0 for host */, res);
	vmm_spin_unlock(&optee_smc_lock);
}

/* -------------------------------------------------------------------------- */
/* Linked-list helpers */

static struct optee_shm_buf *optee_find_shm_buf(struct optee_ctx *ctx, u64 cookie)
{
	struct optee_shm_buf *p;

	for (p = ctx->shm_bufs; p; p = p->next)
		if (p->cookie == cookie)
			return p;
	return NULL;
}

static void optee_remove_shm_buf_locked(struct optee_ctx *ctx, struct optee_shm_buf *sb)
{
	struct optee_shm_buf **pp = &ctx->shm_bufs;

	while (*pp) {
		if (*pp == sb) {
			*pp = sb->next;
			return;
		}
		pp = &(*pp)->next;
	}
}

static struct optee_shm_rpc *optee_find_shm_rpc(struct optee_ctx *ctx, u64 cookie)
{
	struct optee_shm_rpc *p;

	for (p = ctx->shm_rpcs; p; p = p->next)
		if (p->cookie == cookie)
			return p;
	return NULL;
}

static void optee_remove_shm_rpc_locked(struct optee_ctx *ctx, struct optee_shm_rpc *sr)
{
	struct optee_shm_rpc **pp = &ctx->shm_rpcs;

	while (*pp) {
		if (*pp == sr) {
			*pp = sr->next;
			return;
		}
		pp = &(*pp)->next;
	}
}

static struct optee_std_call *optee_find_call_by_thread(struct optee_ctx *ctx,
                                                        u32 thread_id,
                                                        bool require_not_inflight)
{
	struct optee_std_call *c;

	for (c = ctx->calls; c; c = c->next) {
		if (c->thread_id == thread_id) {
			if (require_not_inflight && c->in_flight)
				continue;
			return c;
		}
	}
	return NULL;
}

static void optee_remove_call_locked(struct optee_ctx *ctx, struct optee_std_call *c)
{
	struct optee_std_call **pp = &ctx->calls;

	while (*pp) {
		if (*pp == c) {
			*pp = c->next;
			return;
		}
		pp = &(*pp)->next;
	}
}

/* -------------------------------------------------------------------------- */
/* SHM buffer management */

static struct optee_shm_buf *optee_alloc_shm_buf(struct optee_ctx *ctx,
                                                 u64 cookie, u32 page_cnt)
{
	struct optee_shm_buf *sb;

	vmm_spin_lock(&ctx->lock);
	if (ctx->shm_buf_count >= ctx->max_shm_bufs ||
	    (ctx->shm_page_count + page_cnt) > ctx->max_shm_pages) {
		vmm_spin_unlock(&ctx->lock);
		return NULL;
	}

	if (optee_find_shm_buf(ctx, cookie)) {
		vmm_spin_unlock(&ctx->lock);
		return NULL;
	}

	ctx->shm_buf_count++;
	ctx->shm_page_count += page_cnt;
	vmm_spin_unlock(&ctx->lock);

	sb = vmm_zalloc(sizeof(*sb));
	if (!sb) {
		vmm_spin_lock(&ctx->lock);
		ctx->shm_buf_count--;
		ctx->shm_page_count -= page_cnt;
		vmm_spin_unlock(&ctx->lock);
		return NULL;
	}

	sb->cookie = cookie;
	sb->page_cnt = page_cnt;
	sb->pg_list_cnt = 0;
	sb->pg_list = NULL;

	vmm_spin_lock(&ctx->lock);
	sb->next = ctx->shm_bufs;
	ctx->shm_bufs = sb;
	vmm_spin_unlock(&ctx->lock);

	return sb;
}

static void optee_free_shm_buf_pg_list(struct optee_ctx *ctx, u64 cookie)
{
	struct optee_shm_buf *sb;

	vmm_spin_lock(&ctx->lock);
	sb = optee_find_shm_buf(ctx, cookie);
	vmm_spin_unlock(&ctx->lock);

	if (!sb || !sb->pg_list || !sb->pg_list_cnt)
		return;

	for (u32 i = 0; i < sb->pg_list_cnt; i++)
		optee_host_page_free(&sb->pg_list[i]);

	vmm_free(sb->pg_list);
	sb->pg_list = NULL;
	sb->pg_list_cnt = 0;
}

static void optee_free_shm_buf(struct optee_ctx *ctx, u64 cookie)
{
	struct optee_shm_buf *sb;

	vmm_spin_lock(&ctx->lock);
	sb = optee_find_shm_buf(ctx, cookie);
	if (sb)
		optee_remove_shm_buf_locked(ctx, sb);
	if (sb) {
		ctx->shm_buf_count--;
		ctx->shm_page_count -= sb->page_cnt;
	}
	vmm_spin_unlock(&ctx->lock);

	if (!sb)
		return;

	if (sb->pg_list && sb->pg_list_cnt) {
		for (u32 i = 0; i < sb->pg_list_cnt; i++)
			optee_host_page_free(&sb->pg_list[i]);
		vmm_free(sb->pg_list);
	}
	vmm_free(sb);
}

static void optee_free_tmem_buffers(struct optee_ctx *ctx, struct optee_msg_arg *arg)
{
	if (!arg)
		return;

	for (u32 i = 0; i < arg->num_params; i++) {
		struct optee_msg_param *p = &arg->params[i];
		u32 t = (u32)(p->attr & OPTEE_MSG_ATTR_TYPE_MASK);

		if (t == OPTEE_MSG_ATTR_TYPE_TMEM_INPUT ||
		    t == OPTEE_MSG_ATTR_TYPE_TMEM_OUTPUT ||
		    t == OPTEE_MSG_ATTR_TYPE_TMEM_INOUT) {
			if (p->u.tmem.shm_ref)
				optee_free_shm_buf(ctx, p->u.tmem.shm_ref);
		}
	}
}

/* -------------------------------------------------------------------------- */
/* RPC SHM management */

static struct optee_shm_rpc *optee_alloc_shm_rpc(struct optee_ctx *ctx,
                                                 u64 cookie,
                                                 physical_addr_t guest_cmd_gpa)
{
	struct optee_shm_rpc *sr;
	int rc;

	sr = vmm_zalloc(sizeof(*sr));
	if (!sr)
		return NULL;

	sr->cookie = cookie;
	sr->guest_cmd_gpa = guest_cmd_gpa;

	rc = optee_host_page_alloc(&sr->xvisor_arg_pg, OPTEE_PAGE_SIZE);
	if (rc != VMM_OK) {
		vmm_free(sr);
		return NULL;
	}

	vmm_spin_lock(&ctx->lock);
	sr->next = ctx->shm_rpcs;
	ctx->shm_rpcs = sr;
	vmm_spin_unlock(&ctx->lock);

	return sr;
}

static void optee_free_shm_rpc(struct optee_ctx *ctx, u64 cookie)
{
	struct optee_shm_rpc *sr;

	vmm_spin_lock(&ctx->lock);
	sr = optee_find_shm_rpc(ctx, cookie);
	if (sr)
		optee_remove_shm_rpc_locked(ctx, sr);
	vmm_spin_unlock(&ctx->lock);

	if (!sr)
		return;

	optee_host_page_free(&sr->xvisor_arg_pg);
	vmm_free(sr);
}

/* -------------------------------------------------------------------------- */
/* Standard call context */

static struct optee_std_call *optee_alloc_call(struct optee_ctx *ctx)
{
	struct optee_std_call *c;
	int rc;

	vmm_spin_lock(&ctx->lock);
	if (ctx->call_count >= ctx->max_calls) {
		vmm_spin_unlock(&ctx->lock);
		return NULL;
	}
	ctx->call_count++;
	vmm_spin_unlock(&ctx->lock);

	c = vmm_zalloc(sizeof(*c));
	if (!c) {
		vmm_spin_lock(&ctx->lock);
		ctx->call_count--;
		vmm_spin_unlock(&ctx->lock);
		return NULL;
	}

	rc = optee_host_page_alloc(&c->xvisor_arg_pg, OPTEE_PAGE_SIZE);
	if (rc != VMM_OK) {
		vmm_free(c);
		vmm_spin_lock(&ctx->lock);
		ctx->call_count--;
		vmm_spin_unlock(&ctx->lock);
		return NULL;
	}

	c->arg = (struct optee_msg_arg *)c->xvisor_arg_pg.va;
	c->thread_id = 0;
	c->in_flight = true;
	c->rpc_func = 0;
	c->rpc_buffer_type = 0;
	c->rpc_data_cookie = 0;
	c->state = OPTEE_CALL_STATE_NORMAL;

	vmm_spin_lock(&ctx->lock);
	c->next = ctx->calls;
	ctx->calls = c;
	vmm_spin_unlock(&ctx->lock);

	return c;
}

static void optee_put_call(struct optee_ctx *ctx, struct optee_std_call *c)
{
	if (!c)
		return;

	vmm_spin_lock(&ctx->lock);
	c->in_flight = false;
	vmm_spin_unlock(&ctx->lock);
}

static struct optee_std_call *optee_get_call_by_thread(struct optee_ctx *ctx, u32 thread_id)
{
	struct optee_std_call *c;

	vmm_spin_lock(&ctx->lock);
	c = optee_find_call_by_thread(ctx, thread_id, true);
	if (c)
		c->in_flight = true;
	vmm_spin_unlock(&ctx->lock);

	return c;
}

static void optee_destroy_call(struct optee_ctx *ctx, struct optee_std_call *c)
{
	if (!c)
		return;

	vmm_spin_lock(&ctx->lock);
	optee_remove_call_locked(ctx, c);
	ctx->call_count--;
	vmm_spin_unlock(&ctx->lock);

	optee_host_page_free(&c->xvisor_arg_pg);
	vmm_free(c);
}

/* -------------------------------------------------------------------------- */
/* NONCONTIG translation */

static int optee_translate_noncontig(struct optee_ctx *ctx,
                                     struct vmm_guest *guest,
                                     struct optee_msg_param *p)
{
	u64 buf_ptr = p->u.tmem.buf_ptr;
	u64 size = p->u.tmem.size;
	u64 cookie = p->u.tmem.shm_ref;
	unsigned long offset;
	physical_addr_t list_gpa;
	unsigned long total;
	u32 page_cnt;
	u32 list_pages_needed;
	struct optee_shm_buf *sb;
	struct optee_msg_noncontig_page guest_pg;
	u32 gi = 0;
	u32 pi = 0;
	u32 li = 0;

	if (!buf_ptr || !size)
		return VMM_OK;

	offset = (unsigned long)(buf_ptr & (OPTEE_PAGE_SIZE - 1UL));
	list_gpa = (physical_addr_t)(buf_ptr & OPTEE_PAGE_MASK);

	total = optee_align_up((unsigned long)size + offset, OPTEE_PAGE_SIZE);
	page_cnt = (u32)(total / OPTEE_PAGE_SIZE);

	if (!cookie)
		return VMM_EINVALID;
	if (!page_cnt || page_cnt > OPTEE_MAX_SHM_BUFFER_PG)
		return VMM_EOVERFLOW;

	list_pages_needed = (page_cnt + OPTEE_NONCONTIG_ENTRIES_PER_PAGE - 1U) /
	                    OPTEE_NONCONTIG_ENTRIES_PER_PAGE;

	sb = optee_alloc_shm_buf(ctx, cookie, page_cnt);
	if (!sb)
		return VMM_ENOMEM;

	sb->pg_list_cnt = list_pages_needed;
	sb->pg_list = vmm_zalloc(sizeof(struct optee_host_page) * list_pages_needed);
	if (!sb->pg_list) {
		optee_free_shm_buf(ctx, cookie);
		return VMM_ENOMEM;
	}

	for (u32 i = 0; i < list_pages_needed; i++) {
		int rc = optee_host_page_alloc(&sb->pg_list[i], OPTEE_PAGE_SIZE);
		if (rc != VMM_OK) {
			for (u32 j = 0; j < i; j++)
				optee_host_page_free(&sb->pg_list[j]);
			vmm_free(sb->pg_list);
			sb->pg_list = NULL;
			sb->pg_list_cnt = 0;
			optee_free_shm_buf(ctx, cookie);
			return rc;
		}
	}

	for (u32 n = 0; n < page_cnt; n++) {
		if (gi == 0) {
			int rc = optee_guest_read(guest, list_gpa, &guest_pg, sizeof(guest_pg));
			if (rc != VMM_OK) {
				optee_free_shm_buf(ctx, cookie);
				return rc;
			}
		}

		physical_addr_t page_gpa = (physical_addr_t)guest_pg.pages[gi];
		physical_addr_t page_hpa;
		int rc = optee_guest_pa_to_host_pa(guest, page_gpa, &page_hpa);
		if (rc != VMM_OK) {
			optee_free_shm_buf(ctx, cookie);
			return rc;
		}

		((struct optee_msg_noncontig_page *)sb->pg_list[pi].va)->pages[li] = (u64)page_hpa;

		gi++;
		li++;

		if (gi >= OPTEE_NONCONTIG_ENTRIES_PER_PAGE) {
			list_gpa = (physical_addr_t)guest_pg.next;
			gi = 0;
		}
		if (li >= OPTEE_NONCONTIG_ENTRIES_PER_PAGE) {
			if ((pi + 1U) < sb->pg_list_cnt)
				((struct optee_msg_noncontig_page *)sb->pg_list[pi].va)->next =
					(u64)sb->pg_list[pi + 1U].pa;
			li = 0;
			pi++;
		}
	}

	p->u.tmem.buf_ptr = ((u64)sb->pg_list[0].pa) | (u64)offset;
	return VMM_OK;
}

/* -------------------------------------------------------------------------- */
/* Shadow request/response */

static int optee_copy_std_request(struct vmm_guest *guest,
                                  struct optee_std_call *call,
                                  physical_addr_t guest_arg_gpa)
{
	int rc;
	u32 arg_sz;

	call->guest_arg_gpa = guest_arg_gpa;

	rc = optee_guest_read(guest, guest_arg_gpa, call->xvisor_arg_pg.va,
	                      sizeof(struct optee_msg_arg));
	if (rc != VMM_OK)
		return rc;

	arg_sz = OPTEE_MSG_GET_ARG_SIZE(call->arg->num_params);
	if (arg_sz > OPTEE_PAGE_SIZE)
		return VMM_EOVERFLOW;

	return optee_guest_read(guest, guest_arg_gpa, call->xvisor_arg_pg.va, arg_sz);
}

static int optee_copy_std_response_back(struct vmm_guest *guest,
                                        struct optee_std_call *call)
{
	u8 guest_buf[OPTEE_PAGE_SIZE];
	struct optee_msg_arg hdr;
	struct optee_msg_arg *garg;
	u32 arg_sz;
	int rc;

	rc = optee_guest_read(guest, call->guest_arg_gpa, &hdr, sizeof(hdr));
	if (rc != VMM_OK)
		return rc;

	arg_sz = OPTEE_MSG_GET_ARG_SIZE(hdr.num_params);
	if (arg_sz > OPTEE_PAGE_SIZE)
		return VMM_EOVERFLOW;

	rc = optee_guest_read(guest, call->guest_arg_gpa, guest_buf, arg_sz);
	if (rc != VMM_OK)
		return rc;

	garg = (struct optee_msg_arg *)guest_buf;
	garg->ret = call->arg->ret;
	garg->ret_origin = call->arg->ret_origin;
	garg->session = call->arg->session;

	u32 n = (garg->num_params < call->arg->num_params) ?
	        garg->num_params : call->arg->num_params;

	for (u32 i = 0; i < n; i++) {
		struct optee_msg_param *gp = &garg->params[i];
		struct optee_msg_param *hp = &call->arg->params[i];
		u32 gt = (u32)(gp->attr & OPTEE_MSG_ATTR_TYPE_MASK);

		if (gt == OPTEE_MSG_ATTR_TYPE_VALUE_OUTPUT ||
		    gt == OPTEE_MSG_ATTR_TYPE_VALUE_INOUT) {
			gp->u.value.a = hp->u.value.a;
			gp->u.value.b = hp->u.value.b;
			gp->u.value.c = hp->u.value.c;
		}

		if (gt == OPTEE_MSG_ATTR_TYPE_TMEM_OUTPUT ||
		    gt == OPTEE_MSG_ATTR_TYPE_TMEM_INOUT) {
			gp->u.tmem.size = hp->u.tmem.size;
		}
		if (gt == OPTEE_MSG_ATTR_TYPE_RMEM_OUTPUT ||
		    gt == OPTEE_MSG_ATTR_TYPE_RMEM_INOUT) {
			gp->u.rmem.size = hp->u.rmem.size;
		}
	}

	return optee_guest_write(guest, call->guest_arg_gpa, guest_buf, arg_sz);
}

static int optee_translate_params(struct optee_ctx *ctx,
                                  struct vmm_guest *guest,
                                  struct optee_msg_arg *arg)
{
	for (u32 i = 0; i < arg->num_params; i++) {
		struct optee_msg_param *p = &arg->params[i];
		u32 t = (u32)(p->attr & OPTEE_MSG_ATTR_TYPE_MASK);

		if (t == OPTEE_MSG_ATTR_TYPE_TMEM_INPUT ||
		    t == OPTEE_MSG_ATTR_TYPE_TMEM_OUTPUT ||
		    t == OPTEE_MSG_ATTR_TYPE_TMEM_INOUT) {
			if (p->attr & OPTEE_MSG_ATTR_NONCONTIG) {
				int rc = optee_translate_noncontig(ctx, guest, p);
				if (rc != VMM_OK)
					return rc;
			} else {
				/* dynamic SHM path normally uses NONCONTIG; contiguous guest buffers are refused */
				if (p->u.tmem.buf_ptr)
					return VMM_EINVALID;
			}
		}
	}

	return VMM_OK;
}

/* -------------------------------------------------------------------------- */
/* RPC helpers */

static int optee_rpc_copy_to_guest(struct vmm_guest *guest,
                                   struct optee_shm_rpc *sr)
{
	struct optee_msg_arg *xarg = (struct optee_msg_arg *)sr->xvisor_arg_pg.va;
	u32 sz = OPTEE_MSG_GET_ARG_SIZE(xarg->num_params);

	if (sz > OPTEE_PAGE_SIZE)
		return VMM_EOVERFLOW;

	return optee_guest_write(guest, sr->guest_cmd_gpa, xarg, sz);
}

static int optee_rpc_copy_from_guest(struct vmm_guest *guest,
                                     struct optee_shm_rpc *sr)
{
	u8 tmp[sizeof(struct optee_msg_arg)];
	struct optee_msg_arg *hdr = (struct optee_msg_arg *)tmp;
	u32 sz;
	int rc;

	rc = optee_guest_read(guest, sr->guest_cmd_gpa, tmp, sizeof(tmp));
	if (rc != VMM_OK)
		return rc;

	sz = OPTEE_MSG_GET_ARG_SIZE(hdr->num_params);
	if (sz > OPTEE_PAGE_SIZE)
		return VMM_EOVERFLOW;

	return optee_guest_read(guest, sr->guest_cmd_gpa, sr->xvisor_arg_pg.va, sz);
}

static bool optee_issue_rpc_cmd_free(struct optee_ctx *ctx,
                                     struct vmm_vcpu *vcpu,
                                     arch_regs_t *regs,
                                     struct optee_std_call *call,
                                     struct optee_shm_rpc *sr,
                                     u64 cookie_to_free)
{
	struct optee_msg_arg *xarg = (struct optee_msg_arg *)sr->xvisor_arg_pg.va;

	vmm_memset(xarg, 0, OPTEE_PAGE_SIZE);
	xarg->cmd = OPTEE_RPC_CMD_SHM_FREE;
	xarg->ret = TEEC_ERROR_GENERIC;
	xarg->ret_origin = TEEC_ORIGIN_COMMS;
	xarg->num_params = 1;
	xarg->params[0].attr = OPTEE_MSG_ATTR_TYPE_VALUE_INPUT;
	xarg->params[0].u.value.a = (u64)call->rpc_buffer_type;
	xarg->params[0].u.value.b = cookie_to_free;
	xarg->params[0].u.value.c = 0;

	if (optee_rpc_copy_to_guest(vcpu->guest, sr) != VMM_OK)
		return false;

	cpu_vcpu_reg_write(vcpu, regs, 0, OPTEE_SMC_RETURN_RPC_CMD);
	cpu_vcpu_reg_write(vcpu, regs, 1, (u32)(sr->cookie & 0xffffffffULL));
	cpu_vcpu_reg_write(vcpu, regs, 2, (u32)((sr->cookie >> 32) & 0xffffffffULL));

	call->state = OPTEE_CALL_STATE_XVISOR_RPC;
	call->rpc_func = OPTEE_SMC_RPC_FUNC_CMD;

	return true;
}

/* -------------------------------------------------------------------------- */
/* RPC path */

static int optee_handle_rpc_return(struct optee_ctx *ctx,
                                   struct vmm_vcpu *vcpu,
                                   arch_regs_t *regs,
                                   struct optee_std_call *call,
                                   struct arm_smccc_res *res)
{
	call->thread_id = (u32)(res->a3 & 0xffffffffUL);
	call->rpc_func = OPTEE_SMC_RETURN_GET_RPC_FUNC(res->a0);

	cpu_vcpu_reg_write(vcpu, regs, 0, res->a0);
	cpu_vcpu_reg_write(vcpu, regs, 1, res->a1);
	cpu_vcpu_reg_write(vcpu, regs, 2, res->a2);
	cpu_vcpu_reg_write(vcpu, regs, 3, res->a3);

	if (call->rpc_func == OPTEE_SMC_RPC_FUNC_FREE) {
		u64 cookie = regpair_to_u64(res->a1, res->a2);
		optee_free_shm_rpc(ctx, cookie);
		return VMM_OK;
	}

	if (call->rpc_func == OPTEE_SMC_RPC_FUNC_CMD) {
		u64 cookie = regpair_to_u64(res->a1, res->a2);

		vmm_spin_lock(&ctx->lock);
		struct optee_shm_rpc *sr = optee_find_shm_rpc(ctx, cookie);
		vmm_spin_unlock(&ctx->lock);
		if (!sr)
			return VMM_EAGAIN;

		int rc = optee_rpc_copy_to_guest(vcpu->guest, sr);
		if (rc != VMM_OK)
			return VMM_EAGAIN;

		struct optee_msg_arg *xarg = (struct optee_msg_arg *)sr->xvisor_arg_pg.va;
		if (xarg->num_params >= 1 &&
		    ((xarg->params[0].attr & OPTEE_MSG_ATTR_TYPE_MASK) ==
		     OPTEE_MSG_ATTR_TYPE_VALUE_INPUT)) {
			call->rpc_buffer_type = (u32)(xarg->params[0].u.value.a & 0xffffffffUL);
		}

		if (xarg->num_params >= 1 &&
		    ((xarg->params[0].attr & OPTEE_MSG_ATTR_TYPE_MASK) ==
		     OPTEE_MSG_ATTR_TYPE_VALUE_INPUT)) {
			u64 maybe_cookie = xarg->params[0].u.value.b;

			vmm_spin_lock(&ctx->lock);
			struct optee_shm_buf *sb = optee_find_shm_buf(ctx, maybe_cookie);
			vmm_spin_unlock(&ctx->lock);
			if (sb)
				optee_free_shm_buf(ctx, maybe_cookie);
		}

		return VMM_OK;
	}

	return VMM_OK;
}

static void optee_do_call_with_arg(struct optee_ctx *ctx,
                                   struct vmm_vcpu *vcpu,
                                   arch_regs_t *regs,
                                   struct optee_std_call *call,
                                   unsigned long smc_fid,
                                   unsigned long a1,
                                   unsigned long a2,
                                   unsigned long a3,
                                   unsigned long a4,
                                   unsigned long a5)
{
	struct arm_smccc_res res;

	optee_smc_call(ctx->client_id, smc_fid, a1, a2, a3, a4, a5, 0, &res);

	while (OPTEE_SMC_RETURN_IS_RPC(res.a0)) {
		int rc = optee_handle_rpc_return(ctx, vcpu, regs, call, &res);

		if (rc == VMM_EAGAIN) {
			/* resume OP-TEE immediately */
			optee_smc_call(ctx->client_id, res.a0, res.a1, res.a2, res.a3,
			               0, 0, 0, &res);
			continue;
		}

		optee_put_call(ctx, call);
		return;
	}

	optee_copy_std_response_back(vcpu->guest, call);
	cpu_vcpu_reg_write(vcpu, regs, 0, res.a0);

	switch (call->arg->cmd) {
	case OPTEE_MSG_CMD_REGISTER_SHM:
		if (call->arg->ret == TEEC_SUCCESS) {
			if (call->arg->num_params >= 1)
				optee_free_shm_buf_pg_list(ctx, call->arg->params[0].u.tmem.shm_ref);
		} else {
			if (call->arg->num_params >= 1)
				optee_free_shm_buf(ctx, call->arg->params[0].u.tmem.shm_ref);
		}
		break;

	case OPTEE_MSG_CMD_UNREGISTER_SHM:
		if (call->arg->ret == TEEC_SUCCESS) {
			if (call->arg->num_params >= 1)
				optee_free_shm_buf(ctx, call->arg->params[0].u.rmem.shm_ref);
		}
		break;

	default:
		optee_free_tmem_buffers(ctx, call->arg);
		break;
	}

	optee_destroy_call(ctx, call);
}

/* -------------------------------------------------------------------------- */
/* SMC handlers */

static void optee_handle_exchange_caps(struct optee_ctx *ctx,
                                       struct vmm_vcpu *vcpu,
                                       arch_regs_t *regs)
{
	struct arm_smccc_res res;
	u32 nsec_caps = (u32)cpu_vcpu_reg_read(vcpu, regs, 1);
	u32 sec_caps;

	nsec_caps &= OPTEE_KNOWN_NSEC_CAPS;

	optee_smc_call(ctx->client_id,
	               OPTEE_SMC_EXCHANGE_CAPABILITIES,
	               (unsigned long)nsec_caps, 0, 0, 0, 0, 0, &res);

	if ((u32)res.a0 != OPTEE_SMC_RETURN_OK) {
		cpu_vcpu_reg_write(vcpu, regs, 0, res.a0);
		cpu_vcpu_reg_write(vcpu, regs, 1, res.a1);
		cpu_vcpu_reg_write(vcpu, regs, 2, res.a2);
		cpu_vcpu_reg_write(vcpu, regs, 3, res.a3);
		return;
	}

	sec_caps = (u32)res.a1;
	sec_caps &= OPTEE_KNOWN_SEC_CAPS;

	/* Xen-style: guests must not use global static SHM */
	sec_caps &= ~OPTEE_SMC_SEC_CAP_HAVE_RESERVED_SHM;

	if (!(sec_caps & OPTEE_SMC_SEC_CAP_DYNAMIC_SHM)) {
		cpu_vcpu_reg_write(vcpu, regs, 0, OPTEE_SMC_RETURN_ENOTAVAIL);
		cpu_vcpu_reg_write(vcpu, regs, 1, sec_caps);
		return;
	}

	cpu_vcpu_reg_write(vcpu, regs, 0, OPTEE_SMC_RETURN_OK);
	cpu_vcpu_reg_write(vcpu, regs, 1, sec_caps);
	cpu_vcpu_reg_write(vcpu, regs, 2, res.a2);
	cpu_vcpu_reg_write(vcpu, regs, 3, res.a3);
}

static void optee_handle_get_shm_config(struct vmm_vcpu *vcpu, arch_regs_t *regs)
{
	/* multi-VM mediator forbids global static SHM for guests */
	cpu_vcpu_reg_write(vcpu, regs, 0, OPTEE_SMC_RETURN_ENOTAVAIL);
}

static void optee_handle_std_call(struct optee_ctx *ctx,
                                  struct vmm_vcpu *vcpu,
                                  arch_regs_t *regs)
{
	struct optee_std_call *call;
	u64 gpa;
	unsigned long a3 = (unsigned long)cpu_vcpu_reg_read(vcpu, regs, 3);

	gpa = regpair_to_u64(cpu_vcpu_reg_read(vcpu, regs, 1),
	                     cpu_vcpu_reg_read(vcpu, regs, 2));

	call = optee_alloc_call(ctx);
	if (!call) {
		cpu_vcpu_reg_write(vcpu, regs, 0, OPTEE_SMC_RETURN_ENOMEM);
		return;
	}

	if (optee_copy_std_request(vcpu->guest, call, (physical_addr_t)gpa) != VMM_OK) {
		optee_destroy_call(ctx, call);
		cpu_vcpu_reg_write(vcpu, regs, 0, OPTEE_SMC_RETURN_EBADADDR);
		return;
	}

	u32 arg_sz = OPTEE_MSG_GET_ARG_SIZE(call->arg->num_params);
	if (arg_sz > OPTEE_PAGE_SIZE) {
		optee_destroy_call(ctx, call);
		cpu_vcpu_reg_write(vcpu, regs, 0, OPTEE_SMC_RETURN_EBADADDR);
		return;
	}

	if (optee_translate_params(ctx, vcpu->guest, call->arg) != VMM_OK) {
		call->arg->ret = TEEC_ERROR_COMMUNICATION;
		call->arg->ret_origin = TEEC_ORIGIN_COMMS;
		optee_copy_std_response_back(vcpu->guest, call);
		optee_destroy_call(ctx, call);
		cpu_vcpu_reg_write(vcpu, regs, 0, OPTEE_SMC_RETURN_OK);
		return;
	}

	u64 lo, hi;
	u64_to_regpair(call->xvisor_arg_pg.pa, &lo, &hi);

	optee_do_call_with_arg(ctx, vcpu, regs, call,
	                       OPTEE_SMC_CALL_WITH_ARG,
	                       (unsigned long)lo, (unsigned long)hi,
	                       a3, 0, 0);
}

static void optee_handle_rpc(struct optee_ctx *ctx,
                             struct vmm_vcpu *vcpu,
                             arch_regs_t *regs)
{
	u32 thread_id = (u32)(cpu_vcpu_reg_read(vcpu, regs, 3) & 0xffffffffUL);
	struct optee_std_call *call = optee_get_call_by_thread(ctx, thread_id);

	if (!call) {
		cpu_vcpu_reg_write(vcpu, regs, 0, OPTEE_SMC_RETURN_ERESUME);
		return;
	}

	if (call->rpc_func == OPTEE_SMC_RPC_FUNC_ALLOC) {
		u64 ptr = regpair_to_u64(cpu_vcpu_reg_read(vcpu, regs, 1),
		                         cpu_vcpu_reg_read(vcpu, regs, 2));
		u64 cookie = regpair_to_u64(cpu_vcpu_reg_read(vcpu, regs, 4),
		                            cpu_vcpu_reg_read(vcpu, regs, 5));

		if (ptr & (OPTEE_PAGE_SIZE - 1UL)) {
			cpu_vcpu_reg_write(vcpu, regs, 0, OPTEE_SMC_RETURN_EBADADDR);
			optee_destroy_call(ctx, call);
			return;
		}

		if (!optee_alloc_shm_rpc(ctx, cookie, (physical_addr_t)ptr)) {
			cpu_vcpu_reg_write(vcpu, regs, 0, OPTEE_SMC_RETURN_ENOMEM);
			optee_destroy_call(ctx, call);
			return;
		}

		vmm_spin_lock(&ctx->lock);
		struct optee_shm_rpc *sr = optee_find_shm_rpc(ctx, cookie);
		vmm_spin_unlock(&ctx->lock);

		u64 lo, hi;
		u64_to_regpair(sr->xvisor_arg_pg.pa, &lo, &hi);

		optee_do_call_with_arg(ctx, vcpu, regs, call,
		                       OPTEE_SMC_CALL_RETURN_FROM_RPC,
		                       (unsigned long)lo, (unsigned long)hi,
		                       thread_id,
		                       (unsigned long)cpu_vcpu_reg_read(vcpu, regs, 4),
		                       (unsigned long)cpu_vcpu_reg_read(vcpu, regs, 5));
		return;
	}

	if (call->rpc_func == OPTEE_SMC_RPC_FUNC_CMD) {
		u64 cookie = regpair_to_u64(cpu_vcpu_reg_read(vcpu, regs, 1),
		                            cpu_vcpu_reg_read(vcpu, regs, 2));

		vmm_spin_lock(&ctx->lock);
		struct optee_shm_rpc *sr = optee_find_shm_rpc(ctx, cookie);
		vmm_spin_unlock(&ctx->lock);

		if (!sr) {
			cpu_vcpu_reg_write(vcpu, regs, 0, OPTEE_SMC_RETURN_ERESUME);
			optee_destroy_call(ctx, call);
			return;
		}

		if (optee_rpc_copy_from_guest(vcpu->guest, sr) != VMM_OK) {
			cpu_vcpu_reg_write(vcpu, regs, 0, OPTEE_SMC_RETURN_ERESUME);
			optee_destroy_call(ctx, call);
			return;
		}

		struct optee_msg_arg *xarg = (struct optee_msg_arg *)sr->xvisor_arg_pg.va;

		if (call->state == OPTEE_CALL_STATE_XVISOR_RPC) {
			call->state = OPTEE_CALL_STATE_NORMAL;
			vmm_memset(xarg, 0, OPTEE_PAGE_SIZE);
			xarg->ret = TEEC_ERROR_GENERIC;
			xarg->ret_origin = TEEC_ORIGIN_COMMS;
			xarg->num_params = 0;
		} else {
			if (xarg->num_params >= 1) {
				struct optee_msg_param *p0 = &xarg->params[0];
				u32 t0 = (u32)(p0->attr & OPTEE_MSG_ATTR_TYPE_MASK);

				if ((p0->attr & OPTEE_MSG_ATTR_NONCONTIG) &&
				    (t0 == OPTEE_MSG_ATTR_TYPE_TMEM_OUTPUT ||
				     t0 == OPTEE_MSG_ATTR_TYPE_TMEM_INOUT)) {

					if (call->rpc_data_cookie)
						optee_free_shm_buf_pg_list(ctx, call->rpc_data_cookie);

					int rc = optee_translate_noncontig(ctx, vcpu->guest, p0);
					if (rc != VMM_OK) {
						u64 cfree = p0->u.tmem.shm_ref;
						call->rpc_data_cookie = 0;

						if (optee_issue_rpc_cmd_free(ctx, vcpu, regs, call, sr, cfree)) {
							optee_put_call(ctx, call);
							return;
						}

						vmm_memset(xarg, 0, OPTEE_PAGE_SIZE);
						xarg->ret = TEEC_ERROR_GENERIC;
						xarg->ret_origin = TEEC_ORIGIN_COMMS;
						xarg->num_params = 0;
					} else {
						call->rpc_data_cookie = p0->u.tmem.shm_ref;
					}
				}
			}
		}

		optee_do_call_with_arg(ctx, vcpu, regs, call,
		                       OPTEE_SMC_CALL_RETURN_FROM_RPC,
		                       0, 0, thread_id, 0, 0);
		return;
	}

	optee_do_call_with_arg(ctx, vcpu, regs, call,
	                       OPTEE_SMC_CALL_RETURN_FROM_RPC,
	                       0, 0, thread_id, 0, 0);
}

/* -------------------------------------------------------------------------- */
/* Fastcall passthrough */

static inline void optee_forward_x0_to_x3(struct optee_ctx *ctx,
                                          struct vmm_vcpu *vcpu,
                                          arch_regs_t *regs,
                                          unsigned long fid)
{
	struct arm_smccc_res res;

	optee_smc_call(ctx->client_id,
	               fid,
	               (unsigned long)cpu_vcpu_reg_read(vcpu, regs, 1),
	               (unsigned long)cpu_vcpu_reg_read(vcpu, regs, 2),
	               (unsigned long)cpu_vcpu_reg_read(vcpu, regs, 3),
	               (unsigned long)cpu_vcpu_reg_read(vcpu, regs, 4),
	               (unsigned long)cpu_vcpu_reg_read(vcpu, regs, 5),
	               (unsigned long)cpu_vcpu_reg_read(vcpu, regs, 6),
	               &res);

	cpu_vcpu_reg_write(vcpu, regs, 0, res.a0);
	cpu_vcpu_reg_write(vcpu, regs, 1, res.a1);
	cpu_vcpu_reg_write(vcpu, regs, 2, res.a2);
	cpu_vcpu_reg_write(vcpu, regs, 3, res.a3);
}

/* -------------------------------------------------------------------------- */
/* Probe */

static bool optee_probe(void)
{
	struct arm_smccc_res res;
	u32 nsec_caps = OPTEE_KNOWN_NSEC_CAPS;

	optee_lock_init_once();

	/* Basic API UID check (host context => a7 = 0) */
	optee_smc_call_host(OPTEE_SMC_CALLS_UID, 0, 0, 0, 0, 0, 0, &res);
	vmm_init_printf("OPTEE: CALLS_UID = %08lx %08lx %08lx %08lx\n",
	                res.a0, res.a1, res.a2, res.a3);

	if (res.a0 != OPTEE_MSG_UID_0 || res.a1 != OPTEE_MSG_UID_1 ||
	    res.a2 != OPTEE_MSG_UID_2 || res.a3 != OPTEE_MSG_UID_3) {
		vmm_printf("OPTEE: UID mismatch, not OP-TEE?\n");
		return false;
	}

	/* Get thread count */
	optee_smc_call_host(OPTEE_SMC_GET_THREAD_COUNT, 0, 0, 0, 0, 0, 0, &res);
	if ((u32)res.a0 == OPTEE_SMC_RETURN_OK && (u32)res.a1 > 0)
		optee_max_threads = (u32)res.a1;

	/* Host EXCHANGE_CAPS decides whether multi-VM dynamic SHM is possible */
	optee_smc_call_host(OPTEE_SMC_EXCHANGE_CAPABILITIES,
	                    (unsigned long)nsec_caps, 0, 0, 0, 0, 0, &res);

	if ((u32)res.a0 != OPTEE_SMC_RETURN_OK) {
		vmm_printf("OPTEE: host EXCHANGE_CAPS failed: a0=%#lx\n", res.a0);
		optee_host_probe_done = false;
		return false;
	}

	optee_host_sec_caps = (u32)res.a1;
	optee_dyn_shm_supported = !!(optee_host_sec_caps & OPTEE_SMC_SEC_CAP_DYNAMIC_SHM);
	optee_virt_supported = !!(optee_host_sec_caps & OPTEE_SMC_SEC_CAP_VIRTUALIZATION);
	optee_rpc_max_params = (u32)(res.a3 & 0xFF);
	optee_host_probe_done = true;

	optee_dump_host_caps(optee_host_sec_caps, res.a2, res.a3);

	if (!optee_dyn_shm_supported || !optee_virt_supported) {
		vmm_printf("OPTEE: multi-VM dynamic SHM not possible: sec_caps=0x%x\n",
		           optee_host_sec_caps);
		return false;
	}

	return true;
}

/* -------------------------------------------------------------------------- */
/* Guest lifecycle */

static int optee_guest_init(struct vmm_guest *guest)
{
	struct optee_ctx *ctx;
	struct arm_smccc_res res;

	if (!guest)
		return VMM_EINVALID;
	if (!optee_host_probe_done)
		return VMM_ENOTAVAIL;

	ctx = vmm_zalloc(sizeof(*ctx));
	if (!ctx)
		return VMM_ENOMEM;

	ctx->client_id = (u32)guest->id + 1U;
	ctx->max_calls = optee_max_threads ? optee_max_threads : 1U;
	ctx->max_shm_bufs = OPTEE_MAX_SHM_BUFS_DEFAULT;
	ctx->max_shm_pages = OPTEE_MAX_SHM_PAGES_DEFAULT;
	ctx->call_count = 0;
	ctx->shm_buf_count = 0;
	ctx->shm_page_count = 0;
	ctx->calls = NULL;
	ctx->shm_bufs = NULL;
	ctx->shm_rpcs = NULL;
	INIT_SPIN_LOCK(&ctx->lock);

	optee_smc_call_host(OPTEE_SMC_VM_CREATED,
	                    (unsigned long)ctx->client_id,
	                    0, 0, 0, 0, 0, &res);
	if ((u32)res.a0 != OPTEE_SMC_RETURN_OK) {
		vmm_printf("OPTEE: VM_CREATED vm id=%u failed: a0=%#lx\n",
		           ctx->client_id, res.a0);
		vmm_free(ctx);
		return VMM_EFAIL;
	}

	arm_guest_priv(guest)->tee = ctx;
	vmm_init_printf("OPTEE: bound guest '%s' id=%u -> client_id=%u\n",
	                guest->name, guest->id, ctx->client_id);
	return VMM_OK;
}

static int optee_guest_teardown(struct vmm_guest *guest)
{
	struct optee_ctx *ctx;
	struct arm_smccc_res res;

	if (!guest)
		return VMM_EINVALID;

	ctx = (struct optee_ctx *)arm_guest_priv(guest)->tee;
	if (!ctx)
		return VMM_OK;

	optee_smc_call_host(OPTEE_SMC_VM_DESTROYED,
	                    (unsigned long)ctx->client_id,
	                    0, 0, 0, 0, 0, &res);

	while (ctx->calls)
		optee_destroy_call(ctx, ctx->calls);
	while (ctx->shm_rpcs)
		optee_free_shm_rpc(ctx, ctx->shm_rpcs->cookie);
	while (ctx->shm_bufs)
		optee_free_shm_buf(ctx, ctx->shm_bufs->cookie);

	arm_guest_priv(guest)->tee = NULL;
	vmm_free(ctx);
	return VMM_OK;
}

static int optee_relinquish_resources(struct vmm_guest *guest)
{
	return optee_guest_teardown(guest);
}

/* -------------------------------------------------------------------------- */
/* Main handler */

static bool optee_handle_call(struct vmm_vcpu *vcpu, arch_regs_t *regs)
{
	struct optee_ctx *ctx;
	u32 fid;

	if (!vcpu || !regs)
		return false;

	ctx = (struct optee_ctx *)arm_guest_priv(vcpu->guest)->tee;
	if (!ctx)
		return false;

	fid = (u32)(cpu_vcpu_reg_read(vcpu, regs, 0) & 0xffffffffUL);

	switch (fid) {
	case OPTEE_SMC_CALLS_COUNT:
		cpu_vcpu_reg_write(vcpu, regs, 0, OPTEE_MEDIATOR_SMC_COUNT);
		return true;

	case OPTEE_SMC_CALLS_UID:
	case OPTEE_SMC_CALLS_REVISION:
	case OPTEE_SMC_CALL_GET_OS_UUID:
	case OPTEE_SMC_CALL_GET_OS_REVISION:
	case OPTEE_SMC_ENABLE_SHM_CACHE:
	case OPTEE_SMC_DISABLE_SHM_CACHE:
		optee_forward_x0_to_x3(ctx, vcpu, regs, (unsigned long)fid);
		return true;

	case OPTEE_SMC_EXCHANGE_CAPABILITIES:
		optee_handle_exchange_caps(ctx, vcpu, regs);
		return true;

	case OPTEE_SMC_GET_SHM_CONFIG:
		optee_handle_get_shm_config(vcpu, regs);
		return true;

	case OPTEE_SMC_CALL_WITH_ARG:
		optee_handle_std_call(ctx, vcpu, regs);
		return true;

	case OPTEE_SMC_CALL_RETURN_FROM_RPC:
		optee_handle_rpc(ctx, vcpu, regs);
		return true;

	default:
		return false;
	}
}

/* -------------------------------------------------------------------------- */

static const struct tee_mediator_ops optee_ops = {
	.probe = optee_probe,
	.guest_init = optee_guest_init,
	.guest_teardown = optee_guest_teardown,
	.relinquish_resources = optee_relinquish_resources,
	.handle_call = optee_handle_call,
};

REGISTER_TEE_MEDIATOR(optee, "OP-TEE", TEE_TYPE_OPTEE, &optee_ops);

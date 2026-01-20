// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * OP-TEE mediator for Xvisor (single guest, 1:1 passthrough)
 *
 * This implementation is intentionally minimal:
 *   - supports a single guest only;
 *   - assumes the reserved SHM region returned by OP-TEE is identity mapped for
 *     that guest (IPA == PA), so we can forward SMC calls without translating
 *     pointers;
 *   - hides Dynamic SHM in EXCHANGE_CAPABILITIES so Linux uses static reserved
 *     SHM.
 *
 * If you later want multiple guests or dynamic SHM, you must implement
 * address translation + SHM registration like Xen does.
 */

#include <vmm_error.h>
#include <vmm_stdio.h>
#include <vmm_compiler.h>
#include <vmm_spinlocks.h>
#include <vmm_manager.h>
#include <cpu_vcpu_helper.h>
#include <vmm_guest_aspace.h>

#include <arch_regs.h>

#include <tee.h>
#include <smccc.h>
#include <optee_smc.h>

/* ------------------------------------------------------------ */
/* Policy knobs */

/* If you truly want a fixed client_id regardless of guest->id */
#define OPTEE_SINGLE_GUEST_CLIENT_ID   1U

/* Optional sanity: refuse to expose dynamic shm to guest */
#define OPTEE_FORCE_STATIC_SHM         1

/* Serialize SMCs to OP-TEE (safer on some platforms/firmwares) */
static vmm_spinlock_t optee_smc_lock;
static bool optee_smc_lock_init;

struct optee_ctx {
    u32 client_id;
};

/* only one guest may own OP-TEE */
static struct vmm_guest *optee_owner_guest;

static inline void optee_lock_init_once(void)
{
    if (!optee_smc_lock_init) {
        INIT_SPIN_LOCK(&optee_smc_lock);
        optee_smc_lock_init = true;
    }
}

static inline void optee_smc_call(u32 client_id,
                                 unsigned long a0, unsigned long a1,
                                 unsigned long a2, unsigned long a3,
                                 unsigned long a4, unsigned long a5,
                                 unsigned long a6,
                                 struct arm_smccc_res *res)
{
    /* a7 carries OP-TEE client id for virtualized NS */
    vmm_spin_lock(&optee_smc_lock);
    arm_smccc_smc(a0, a1, a2, a3, a4, a5, a6, (unsigned long)client_id, res);
    vmm_spin_unlock(&optee_smc_lock);
}

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

/* ------------------------------------------------------------ */
/* Probe */

static bool optee_probe(void)
{
    struct arm_smccc_res res;

    optee_lock_init_once();

    /* Basic API UID check (host context => a7 = 0) */
    vmm_spin_lock(&optee_smc_lock);
    arm_smccc_smc(OPTEE_SMC_CALLS_UID, 0, 0, 0, 0, 0, 0, 0, &res);
    vmm_spin_unlock(&optee_smc_lock);

    vmm_init_printf("OPTEE: CALLS_UID = %08lx %08lx %08lx %08lx\n",
                    res.a0, res.a1, res.a2, res.a3);

#ifdef OPTEE_MSG_UID_0
    /* If optee_msg.h provides UID words, validate them */
    if (res.a0 != OPTEE_MSG_UID_0 || res.a1 != OPTEE_MSG_UID_1 ||
        res.a2 != OPTEE_MSG_UID_2 || res.a3 != OPTEE_MSG_UID_3) {
        vmm_printf("OPTEE: UID mismatch, not OP-TEE?\n");
        return false;
    }
#endif

    return true;
}

static int optee_init_secondary(void)
{
    /* nothing */
    return VMM_OK;
}

/* ------------------------------------------------------------ */
/* Guest lifecycle */

static int optee_guest_init(struct vmm_guest *guest)
{
    struct optee_ctx *ctx;
    struct arm_smccc_res res;

    if (!guest)
        return VMM_EINVALID;

    if (optee_owner_guest && optee_owner_guest != guest) {
        vmm_printf("OPTEE: refusing guest '%s' (id=%u): single-guest mode already bound to '%s'\n",
                   guest->name, guest->id, optee_owner_guest->name);
        return VMM_EBUSY;
    }

    ctx = vmm_zalloc(sizeof(*ctx));
    if (!ctx)
        return VMM_ENOMEM;

    /*
     * For single guest passthrough, keep it simple.
     * If you prefer guest->id+1, you can change here.
     */
    ctx->client_id = OPTEE_SINGLE_GUEST_CLIENT_ID;

    /* Notify OP-TEE that a VM/client is created (host context => a7 = 0) */
    optee_lock_init_once();
    vmm_spin_lock(&optee_smc_lock);
    arm_smccc_smc(OPTEE_SMC_VM_CREATED,
                  (unsigned long)ctx->client_id,
                  0, 0, 0, 0, 0, 0,
                  &res);
    vmm_spin_unlock(&optee_smc_lock);

    if ((u32)res.a0 != OPTEE_SMC_RETURN_OK) {
        vmm_printf("OPTEE: VM_CREATED failed: a0=%#lx\n", res.a0);
        vmm_free(ctx);
        return VMM_EFAIL;
    }

    arm_guest_priv(guest)->tee = ctx;
    optee_owner_guest = guest;

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

    /* Notify OP-TEE that the VM/client is destroyed (host context => a7 = 0) */
    vmm_spin_lock(&optee_smc_lock);
    arm_smccc_smc(OPTEE_SMC_VM_DESTROYED,
                  (unsigned long)ctx->client_id,
                  0, 0, 0, 0, 0, 0,
                  &res);
    vmm_spin_unlock(&optee_smc_lock);

    arm_guest_priv(guest)->tee = NULL;

    if (optee_owner_guest == guest)
        optee_owner_guest = NULL;

    vmm_free(ctx);

    return VMM_OK;
}

static void optee_free_guest_ctx(struct vmm_guest *guest, void *guest_ctx)
{
    /* In this simple implementation, guest_teardown already frees ctx. */
    (void)guest;
    (void)guest_ctx;
}

static int optee_relinquish_resources(struct vmm_guest *guest)
{
    /* called on hard teardown paths; reuse guest_teardown */
    return optee_guest_teardown(guest);
}

/* ------------------------------------------------------------ */
/* EXCHANGE_CAPABILITIES */

static void optee_handle_exchange_caps(struct optee_ctx *ctx,
                                       struct vmm_vcpu *vcpu,
                                       arch_regs_t *regs)
{
    struct arm_smccc_res res;
    u32 nsec_caps;
    u32 sec_caps;

    nsec_caps = (u32)cpu_vcpu_reg_read(vcpu, regs, 1);

    /* The only defined NS cap today is UNIPROCESSOR. Mask unknown bits. */
#ifdef OPTEE_SMC_NSEC_CAP_UNIPROCESSOR
    nsec_caps &= OPTEE_SMC_NSEC_CAP_UNIPROCESSOR;
#else
    nsec_caps = 0;
#endif

    optee_smc_call(ctx->client_id,
                   OPTEE_SMC_EXCHANGE_CAPABILITIES,
                   (unsigned long)nsec_caps,
                   0, 0, 0, 0, 0,
                   &res);

    /* Forward status */
    cpu_vcpu_reg_write(vcpu, regs, 0, res.a0);

    if ((u32)res.a0 != OPTEE_SMC_RETURN_OK) {
        /* On error, still forward caps if present (Linux tolerates). */
        cpu_vcpu_reg_write(vcpu, regs, 1, res.a1);
        cpu_vcpu_reg_write(vcpu, regs, 2, res.a2);
        cpu_vcpu_reg_write(vcpu, regs, 3, res.a3);
        return;
    }

    /*
     * IMPORTANT:
     * Linux uses:
     *   x1 = secure capabilities bitfield
     *   x2 = optional (async notif max)
     *   x3 = optional (RPC arg param count, when RPC_ARG cap is set)
     * If we drop x2/x3, Linux may fail with "capabilities mismatch".
     */
    sec_caps = (u32)res.a1;

#if OPTEE_FORCE_STATIC_SHM
#ifdef OPTEE_SMC_SEC_CAP_DYNAMIC_SHM
    sec_caps &= ~OPTEE_SMC_SEC_CAP_DYNAMIC_SHM;
#endif
#endif

    cpu_vcpu_reg_write(vcpu, regs, 0, OPTEE_SMC_RETURN_OK);
    cpu_vcpu_reg_write(vcpu, regs, 1, (unsigned long)sec_caps);
    cpu_vcpu_reg_write(vcpu, regs, 2, res.a2);
    cpu_vcpu_reg_write(vcpu, regs, 3, res.a3);
}

/* ------------------------------------------------------------ */
/* GET_SHM_CONFIG */

static void optee_handle_get_shm_config(struct optee_ctx *ctx,
                                        struct vmm_vcpu *vcpu,
                                        arch_regs_t *regs)
{
    struct arm_smccc_res res;

    optee_smc_call(ctx->client_id,
                   OPTEE_SMC_GET_SHM_CONFIG,
                   0, 0, 0, 0, 0, 0,
                   &res);

    /*
     * In strict passthrough mode we simply forward x0-x3.
     * (If you want safety checks: verify the guest stage-2 maps res.a1..a1+a2
     * with IPA==PA, otherwise return ENOTAVAIL.)
     */
    cpu_vcpu_reg_write(vcpu, regs, 0, res.a0);
    cpu_vcpu_reg_write(vcpu, regs, 1, res.a1);
    cpu_vcpu_reg_write(vcpu, regs, 2, res.a2);
    cpu_vcpu_reg_write(vcpu, regs, 3, res.a3);
}

/* ------------------------------------------------------------ */
/* Main handler */

static bool optee_handle_call(struct vmm_vcpu *vcpu, arch_regs_t *regs)
{
    struct optee_ctx *ctx;
    u32 fid;

    if (!vcpu || !regs)
        return false;

    /* Single-guest policy: only handle calls from the bound guest */
    if (optee_owner_guest && vcpu->guest != optee_owner_guest)
        return false;

    ctx = (struct optee_ctx *)arm_guest_priv(vcpu->guest)->tee;
    if (!ctx)
        return false;

    fid = (u32)(cpu_vcpu_reg_read(vcpu, regs, 0) & 0xffffffffUL);

    switch (fid) {
    case OPTEE_SMC_EXCHANGE_CAPABILITIES:
        optee_handle_exchange_caps(ctx, vcpu, regs);
        return true;

    case OPTEE_SMC_GET_SHM_CONFIG:
        optee_handle_get_shm_config(ctx, vcpu, regs);
        return true;

    default:
        /*
         * For single-guest identity-mapped reserved SHM, most OP-TEE SMCs can
         * be forwarded directly by forcing a7=client_id.
         */
        optee_forward_x0_to_x3(ctx, vcpu, regs, (unsigned long)fid);
        return true;
    }
}

/* ------------------------------------------------------------ */

static const struct tee_mediator_ops optee_ops = {
    .probe = optee_probe,
    .init_secondary = optee_init_secondary,
    .guest_init = optee_guest_init,
    .guest_teardown = optee_guest_teardown,
    .free_guest_ctx = optee_free_guest_ctx,
    .relinquish_resources = optee_relinquish_resources,
    .handle_call = optee_handle_call,
};

REGISTER_TEE_MEDIATOR(optee, "OP-TEE", TEE_TYPE_OPTEE, &optee_ops);

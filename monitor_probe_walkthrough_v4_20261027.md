# Monitor v4 打点逐处说明

版本：v4；整理日期：2026-10-27。

本文把对话中已经讲解的 cpu_hcall.c、cpu_interrupts.c、cpu_vcpu_excep.c，以及调度器、共享内存、CCM 缓冲区、内存命令中的其他打点放在一起。每一处都说明：原函数做什么、为什么在这里记录、记录字段是什么意思、之后仍执行什么原有处理，以及这处记录不能证明什么。

**本文描述已经交付源码的实际行为，不修改源码，也不把拟议功能写成已经实现。** 当前生产实现采用 schema=3；调度器以用户最新上传后适配的产品版本为准。原有内存分配、CCM 注册、内存命令权限、异常处置策略均按产品原逻辑理解。

## 1. 阅读范围与关键结论

### 1.1 本文依据哪一版代码

当前记录版基线为 monitor_observer_from_20261023_v4_20261025；后续统一测试、采样进度修正和真实 exit 风暴测试以工作区最终参考树为依据。产品调度器单独使用基于附件 084362A2-2DDC-4267-98D5-77EDC5AE0EA6 适配的文件，不能用上游调度器直接覆盖它。

文末列出实际读取文件、源码行号、哈希和全部生产打点位置。正文中的行号属于这些文件；手工合入时应按函数、原分支和相邻语句定位。

用户提供的 VGIC 文件还含有早期注入延时接口。本文单独解释其语义，但不把它们算作当前精简版 monitor 已保留的注入延时功能。用户已有的 history、trace、trap_stat 属于产品原统计，不因 monitor 加入而自动删除。

### 1.2 三类“计数”不能混为一谈

| 记录对象 | 回答的问题 | 主要位置 |
|---|---|---|
| READY 等待、dispatch 耗时 | 调度对象等待了多久，调度代码执行了多久 | vmm_scheduler.c |
| Guest exit | Guest 经已接入入口进入 EL2 多少次，是否持续超限 | cpu_interrupts.c |
| 内存类异常摘要 | 原检查或异常处理发现了什么失败 | excep、shmem、CCM、cmd_memory |
| 产品原 trap_stat.irq_cnt | 向虚拟中断 LR 写入或更新了多少次 | 用户 VGIC |

同一次 Guest 内存异常可以增加一次 exit 计数，并生成一条内存类摘要。这是对同一事件的不同维度记录，不是给 exit 加了两次。

### 1.3 必须先明确的实现边界

- 调度统计覆盖已接入调度路径上的 Guest、Hypervisor 线程和 idle；exit 风暴只针对 Guest vCPU。
- CPU 调度数据当前只统计，不设置延迟阈值，也不自动生成调度超限日志。
- 内存打点记录原有检查的拒绝结果和指定异常类型；不会重新建立访问授权策略，也不能观察所有普通指针越界。
- 当前 ARM64 参考异常向量调用 do_irq，但不调用 do_hyp_fiq。FIQ 函数里虽然有打点，不能据此认定已覆盖 FIQ。
- JSON 的 code 必须结合 type 解析；address 和 detail 必须再结合 code 解析。
- 内存摘要按记录主体聚合，不按错误类型、地址分别建桶。次数是聚合期间的总次数，明细是最后一次。
- 日志调用返回不等于已经落盘。产品日志系统会同时输出控制台；控制台截断也不代表事件缓冲中原始字段必然丢失。

## 2. 所有打点共用的入口

### 2.1 头文件把五类入口汇总到记录器

core/include/vmm_monitor.h 中的生产宏为：

~~~c
#define vmm_monitor_state(v,s,t)     vmm_monitor_record(v, MON_STATE, s, t)
#define vmm_monitor_selected(v,t)    vmm_monitor_record(v, MON_SELECTED, t, 0)
#define vmm_monitor_dispatch(v,a,b)  vmm_monitor_record(v, MON_DISPATCH, a, b)
#define vmm_monitor_exit(v,r)        vmm_monitor_record(v, MON_EXIT, r, 0)
#define vmm_monitor_mem_fault(v,k,a,d) +        vmm_monitor_record(v, MON_FAULT + (k), a, d)
~~~

这些宏传入的第二、第三个数据参数复用同一存储接口，但含义并不相同。

| 入口 | 数据参数 | 记录器的动作 |
|---|---|---|
| state | 新状态、原调度时间戳 | 进入 READY 时保存等待起点；其他状态取消等待 |
| selected | 被选中时间戳 | 如存在有效等待起点，累计一次 READY 等待 |
| dispatch | 调度区间起点、终点 | 累计一次调度路径耗时 |
| exit | 退出原因 | 退出计数加一，更新最后原因 |
| mem_fault | 异常代码、地址、附加信息 | 更新内存类摘要 |

CONFIG_MONITOR_AGENT 关闭时，生产打点宏展开为空语句，参数不求值。运行时 stop 则只关闭采集，已编译的函数调用和部分计时开销仍存在，两者不能视为同一种关闭方式。

### 2.2 记录对象如何确定

vmm_monitor_record() 根据 vCPU ID 选择静态槽；另外预留一个槽供 NULL 主体使用。

| 传入主体 | JSON 身份 | 例子 |
|---|---|---|
| 正常 Guest vCPU | guest 为 Guest ID，vcpu 为全局 vCPU ID | Guest abort、HVC 注册失败 |
| Hypervisor 线程 | guest=4294967295，vcpu 为线程对应 vCPU ID | 内存命令拒绝 |
| NULL | guest=4294967295，vcpu=4294967295 | 通用 shmem、sbuf_put |

4294967295 即无符号 32 位的 ~0U，是没有可用 Guest/主体身份的标记，不表示系统真的存在这个编号的 Guest。

分类使用 is_normal 和 idle 身份，不仅看 vcpu->guest 是否非空。产品某些后台线程也挂有 guest 指针，不能因此把其统计算作 Guest exit。

### 2.3 热路径中做什么、不做什么

记录器先检查初始化和运行状态，再取得单槽锁，更新静态数据。不会在每次异常或调度点创建日志对象、分配监控事件内存或直接执行日志打印。内存异常需要读取当前时间，调度事件尽量使用调用者已获取的时间戳。

本实现使用静态槽和固定事件环。初始化阶段创建内部工作队列允许分配内存；产品原函数、命令检查和日志后端是否分配内存，需要与 monitor 新增采集路径分开统计。

~~~mermaid
flowchart TD
    A["原调度、异常或访问检查路径"] --> B["monitor 宏"]
    B --> C{"已初始化且允许记录？"}
    C -- 否 --> D["返回原处理流程"]
    C -- 是 --> E["锁定对应静态槽"]
    E --> F["更新统计或内存摘要"]
    F --> D
    F --> G["周期采样：生成事件"]
    G --> H["固定事件环"]
    H --> I["monitor events 查询"]
    H --> J["后台线程调用日志接口"]
~~~

## 3. vmm_scheduler.c：等待时间与调度耗时

### 3.1 两个指标的准确起止点

当前 status 中：

~~~text
ready    = [样本数, 平均等待时间_ns, 最大等待时间_ns]
dispatch = [样本数, 平均调度耗时_ns, 最大调度耗时_ns]
~~~

ready 表示 monitor 观察到调度对象进入 READY 后，到被调度器选中的时间。dispatch 表示产品调度函数中 t1 到 t2 的代码执行区间。

**dispatch 不是“从唤醒到 Guest 第一条指令执行”的完整延迟。** t2 位于架构 post_switch 之后的 C 路径，并不在最终异常返回后、Guest 真正执行第一条指令的位置。

ready 与 dispatch 的区间可能有重叠。不能直接把两者平均值相加当作唤醒总延迟，也不能要求两个样本数始终相同。

### 3.2 为什么复用原有打点，而不读取 history 环

产品调度器已有状态时间戳、CONFIG_SCHED_HISTORY，以及 CONFIG_CMD_LAT_CTX 的 t1/t2。适配复用这些已有时间点和局部变量，把时间传给 monitor；不扫描 history 环，不依赖 history 的运行时开关。

原因是同一次调度可能同时写入 CPU history 和 vCPU history。如果把两份 history 写入都当作 monitor 样本入口，会重复计算。history 环还可能关闭、覆盖或被独立清理，不能直接成为 monitor 的唯一数据来源。

复用时间点并不意味着所有原计数与 monitor 数值逐项相等。原 state_tstamp 统计、history 记录时间、monitor 选中时间，仍应按各自具体位置理解。

### 3.3 打点 S1：成功提交状态变化，保存 READY 起点

函数：vmm_scheduler_state_change()；适配后约 1232 行。

~~~c
vmm_monitor_state(vcpu, new_state, tstamp);
state_packed = VCPU_STATE_PACK(vhcpu, new_state);
vmm_scheduler_set_state_packed(vcpu, state_packed);
vcpu->state_tstamp = tstamp;
~~~

这段位于原 rc == VMM_OK 的成功提交区间内。打点收到原始 new_state，不是打包了 CPU 信息的 state_packed。

当 RESET/PAUSED 的对象成功进入 READY，原路径已经执行入队及相关处理，随后在成功提交处读取的 tstamp 被传给 monitor。它是逻辑 READY 提交时间，不严格等同于 rq_enqueue 指令执行的瞬间。

记录器遇到 READY 时，只在 waiting 尚未建立的情况下设置 ready_since。重复 READY 不覆盖已有起点，避免把长等待不断重置成短等待。

PAUSED、HALTED 等状态会清除 waiting，避免把主动阻塞时间继续算成就绪队列等待。RESET/UNKNOWN 会按生命周期清理槽，防止 vCPU 重置或 ID 复用沿用旧统计；已有内存摘要先尝试发布。

原状态检查失败、RUNNING 上收到 resume、READY→READY 等走 skip_state_change 的分支，不会因这处新打点凭空产生一次状态提交。

### 3.4 打点 S2：运行对象重新入队

函数：__vmm_scheduler_next2()；适配后约 480 行。

~~~c
vmm_scheduler_set_state_raw(current, VMM_VCPU_STATE_READY);
current->state_tstamp = tstamp;
vmm_monitor_state(current, VMM_VCPU_STATE_READY, tstamp);
rq_enqueue(schedp, current);
~~~

运行对象被重新放回就绪队列，是另一条进入 READY 的路径，不能只依靠 state_change()。这里直接复用更新原状态时的 tstamp。

例如对象 A 时间片结束，仍可运行但本次轮到 B。A 从这里开始等待，到下一次被选中才结束。原有调度策略、入队顺序和时间片都不由 monitor 修改。

### 3.5 打点 S3：首次调度选中对象

函数：__vmm_scheduler_next1()；约 398 行。

~~~c
vmm_write_lock_irqsave_lite(&next->sched_lock, nf);
tstamp = vmm_timer_timestamp();
vmm_monitor_selected(next, tstamp);
/* 原 history 时间及 arch_vcpu_switch() 继续执行 */
~~~

首次调度没有 current，也需要结束 next 的 READY 等待。打点在取得目标锁之后，使用原本就在这里读取的时间。

如果 monitor 从未观察到此对象的 READY 起点，selected 不补造起点，也不生成一个人为的等待样本。因此刚 start 时，已有 READY 对象的第一段等待可能不完整。

### 3.6 打点 S4：普通切换选中不同对象

函数：__vmm_scheduler_next2()；约 513 行。

原代码出队之后还会加锁并复查 next 的状态。其他 CPU 可能已把它暂停、复位或停止。复查失败时重新选对象，不能把失败候选当作真正调度目标。

因此打点放在通过复查后：

~~~c
tstamp = vmm_timer_timestamp();
vmm_monitor_selected(next, tstamp);
arch_vcpu_switch(tcurrent, next, regs);
~~~

时间戳重新读取也保留了原有并发考虑：加目标锁之前读出的旧时间可能早于目标最新 state_tstamp。

### 3.7 打点 S5：同一个对象被重新选中

函数：__vmm_scheduler_next2()；约 519/523 行，两个编译分支只会生效一个。

~~~c
#ifdef CONFIG_SCHED_HISTORY
    sched_out_tstamp = sched_in_tstamp = vmm_timer_timestamp();
    if (next == current)
        vmm_monitor_selected(next, sched_in_tstamp);
#else
    if (next == current)
        vmm_monitor_selected(next, vmm_timer_timestamp());
#endif
~~~

当前对象可能先变 READY，再被立即选回。即使没有切换到另一个对象，也应该结束这一段等待。

有 history 时复用 sched_in_tstamp；没有 history 时，为 monitor 提供终点。monitor 编译关闭时，后一个宏为空，时间戳参数也不求值。

### 3.8 打点 S6：统一记录 dispatch

函数：vmm_scheduler_switch()；约 583～655 行，最终调用位于 653 行。

产品原来的 CONFIG_CMD_LAT_CTX 使用 t1/t2 测量切换区间。适配把声明和读取的编译条件扩展为 trace 或 monitor 任一个开启时生效。

| 路径 | t1 | t2 | 是否记录 dispatch |
|---|---|---|---|
| 有 current，允许调度，选择不同 next | 取得 current 锁后、调用 next2 前 | arch_vcpu_post_switch 后 | 是，归属 next |
| 同一对象重选 | 同上 | next2 返回后外层补读 | 是，归属 current |
| 首次调度 | 调用 next1 前补读 | post_switch 后 | 是，归属 next |
| 当前禁止抢占，本次未执行调度选择 | 不建立有效测量区间 | 无 | 否 |

关键变量为 scheduled。next2 在“同一个对象重选”时返回 NULL，禁止抢占分支也会让 next 为 NULL；只判断 next 不足以区分这两种情况。

~~~c
if (scheduled) {
    if (!next)
        t2 = vmm_timer_timestamp();
    vmm_monitor_dispatch(next ? next : current, t1, t2);
}
~~~

t2 在 trace 输出之前读取，避免把 trace 消费本身计入测量终点。但 t1～t2 区间里仍有调度器自身代码和已插入的部分 monitor 调用，不能宣称测量完全无扰动。

正常路径的 t1 在取得 current 锁之后，因此不包含取得该锁之前的等待。它包含后续 next2 选择、目标锁操作、必要架构切换及 post_switch 等工作，边界应与原 trace 点位保持一致。

### 3.9 状态、样本和优先级的关系

~~~mermaid
flowchart LR
    A["成功进入 READY"] --> B["保存 ready_since"]
    B --> C["等待期间，可能迁核"]
    C --> D["通过复查，被选中"]
    D --> E["累计 selected - ready_since"]
    E --> F["清除 waiting"]
    B --> G["期间 PAUSED / HALTED"]
    G --> H["取消等待，不生成完整 READY 样本"]
~~~

槽按 vCPU ID 保存，不按所在核保存，因此连续 READY 的等待可以跨迁核保留。重复 READY 不会自动把起点改为迁核时间。

monitor 日志线程优先级为 3，不妨碍这些调度打点观察优先级 7 的 IPI 线程：记录发生在调度器路径中，不依赖优先级 3 的线程先获得运行机会。日志何时打印是另一件事。

ready_age_ns 只表示已经被 monitor 观察到、尚未结束的当前等待年龄；长期未被选中的对象尚未贡献新的 ready 完整样本。stop 后该字段输出 0，不代表之前没有等待。

上游参考树在 next1/next2 内记录 dispatch；产品适配版在外层 switch 统一复用 t1/t2。两套不能同时合入，否则可能重复计数且统计区间不同。

## 4. cpu_interrupts.c：Guest exit 的入口记录

### 4.1 打点 E1：do_sync() 在 switch 之前

位置约 101 行：

~~~c
/* 原 EL2 自身异常分支已经先行处理 */
vmm_monitor_exit(vcpu, ec);
vmm_scheduler_irq_enter(regs, TRUE);
switch (ec) {
    /* 原异常分发 */
}
~~~

ec 来自 ESR_EL2 的异常分类字段。这里计数的是到达该位置的 Guest 同步异常，包括已识别 case，以及之后落入 default 的情况。

EL2 自身用于 orphan 抢占的 HVC 在前面的专门分支处理并返回；EL2 自身其他致命同步异常也不会被这处打点作为正常 Guest exit 记录。

放在分发之前有两个作用：进入哪个 case 都能计一次；后续模拟失败也不会漏掉这次已经发生的退出。它不测量该 case 的执行耗时，也没有保存异常 PC。

### 4.2 与原 trap_stat 的关系

用户提供过：

~~~c
case EC_TRAP_HVC_A64:
    arch_atomic64_add(&vcpu->trap_stat.hvc_inst, 1);
    rc = cpu_vcpu_emulate_hvc64(vcpu, regs, il, iss);
    break;
~~~

这个计数是 HVC 分类累计；monitor 是已接入入口的退出总量，随后按采样区间计算速率。两者更新不同字段，不会自动给 monitor 的 exits 加两次。

只有在所有分支均恰好计一次、包含 default、采集起止和复位规则相同、并发读取可靠时，分类型统计的区间增量总和才可能替代 do_sync 的这部分总量。用户完整产品 cpu_interrupts.c 在本次资料中未逐行验证，因此本文不假定这些条件全部满足。

即使同步异常分类计数完全可复用，也不能直接加上 VGIC 的 irq_cnt 来替代总 exit；VGIC 的计量点见第 10 章。

### 4.3 打点 E2：do_irq() 的来源判断

位置约 223～224 行：

~~~c
if ((regs->pstate & PSR_EL_MASK) != PSR_EL_2)
    vmm_monitor_exit(vmm_scheduler_current_vcpu(), 0x100);
~~~

regs->pstate 由异常入口汇编从 SPSR_EL2 保存，表示异常发生前的状态。当前函数本身在 EL2 执行，不应拿进入函数后的当前级别判断异常来源。

| 被 IRQ 打断时的上下文 | 是否增加 Guest exit |
|---|---|
| Guest EL0 或 EL1 | 对有效 Guest vCPU 计一次 |
| Hypervisor EL2 | 不计 |

为什么还需要检查 pstate，而不是只检查 current_vcpu？Guest 进入 HVC 处理后，调度器当前对象仍可能指向这个 Guest。如果 EL2 处理期间又允许并发生 IRQ，这不是一次新的 Guest→EL2 退出。只看 current_vcpu 会把它误算进去。

条件只控制监控调用。后面的 irq_enter、物理中断分发、irq_exit 无论如何都会按原逻辑执行，不会因为不计数而跳过 IRQ 处理。

0x100 即十进制 256，是 monitor 使用的软件标记；不是 ARM EC，也不是物理或虚拟 IRQ 号。

### 4.4 打点 E3：do_hyp_fiq() 有代码，但参考向量没有调用它

约 234～235 行也有相同判断和 0x100 标记。但本次核对 cpu_entry.S 后，实际关系如下：

| 汇编入口 | 调用函数 |
|---|---|
| hyp_irq | do_irq |
| guest_irq_a64 / guest_irq_a32 | do_irq |
| hyp_fiq | do_bad_mode |
| guest_fiq_a64 / guest_fiq_a32 | do_bad_mode |

**当前参考代码不能声称 FIQ 监控已接通。** do_hyp_fiq 只在找到并实际调用它的路径上才可能生效。用户产品如修改了向量，应按产品实际入口重新核对。

此前讨论中出现的 do_hyp_irq 不是这份 C 文件的函数名；它可能混淆了汇编 hyp_irq 与 C 函数 do_hyp_fiq。hyp_irq 是有效入口，且与 Guest IRQ 入口共用 do_irq。

### 4.5 exit 记录之后何时产生日志

每次入口只增加 exits 并保存 last_exit，不每次打印。周期采样发现同一 Guest vCPU 连续有效窗口超过门限，才产生 type=1 的风暴事件。

事件 code 是触发窗口累计到的最后一次退出原因，不是次数最多的原因，更不是已经证明的根因。例：一个窗口中多数是 HVC，最后一次恰好是 IRQ，事件 code 仍可能为 256。

## 5. cpu_vcpu_excep.c：映射失败与访问权限异常

### 5.1 与 do_sync() 的关系

~~~mermaid
flowchart TD
    A["Guest 同步异常进入 do_sync"] --> B["exit 计数加一"]
    B --> C{"异常分类"}
    C -- 取指异常 --> D["cpu_vcpu_inst_abort"]
    C -- 数据访问异常 --> E["cpu_vcpu_data_abort"]
    D --> F{"FSC 权限错误？"}
    E --> F
    F -- 是 --> G["记录 PERMISSION，继续原处理"]
    D --> H["翻译错误分支：尝试建立映射"]
    E --> H
    H --> I{"基本页映射查询成功？"}
    I -- 否 --> J["记录 MAP_REJECT，返回原错误"]
    I -- 是 --> K["按原流程建页表或回退"]
~~~

同一次异常可能同时进入 exit 计数和内存摘要。excep 中没有再调用 exit 宏，所以不是重复增加退出计数。

### 5.2 打点 M1：cpu_vcpu_stage2_map() 基本页映射查询失败

位置约 54～60 行：

~~~c
rc = vmm_guest_physical_map(vcpu->guest, inaddr, size,
                           &outaddr, &availsz, &reg_flags);
if (rc) {
    vmm_monitor_mem_fault(vcpu, VMM_MONITOR_MAP_REJECT, fipa, rc);
    /* 原打印 */
    return rc;
}
~~~

stage2 指 IPA→HPA 地址转换。函数先将 fipa 按基本页对齐，再按该 Guest 的区域配置查询映射。当前 vmm_guest_physical_map 在找不到区域、别名转换后找不到区域、参数不合法等情况下返回失败。

合法地址首次访问也可能发生翻译异常，因为地址区域已经配置但页表映射尚未按需建立。因此不是一进入 abort 就报“越界”，而是在原基本页查询已经失败时记录。

| 字段 | 含义 |
|---|---|
| type=3 | 内存类摘要 |
| code=2 | MAP_REJECT |
| guest/vcpu | 发起异常的 Guest 与 vCPU |
| address | 原路径传入的 fipa，按异常 IPA 语义解释 |
| detail | rc，转换到公共 u64 字段 |

保存 fipa 而不是页对齐后的 inaddr，保留原传入的地址信息。detail 的负错误码输出成无符号十进制时可能看起来很大，应按有符号 64 位还原，不能解释成次数或内存大小。

MAP_REJECT 的准确结论是“映射查询失败”。未配置区域访问是典型原因，但配置缺失、别名配置问题也会产生它，不能单凭这个 code 判定恶意越权。

### 5.3 打点 M2：cpu_vcpu_inst_abort() 的权限错误

位置约 126～130 行：

~~~c
if ((iss & ISS_ABORT_FSC_MASK) >= FSC_PERM_FAULT_LEVEL0 &&
    (iss & ISS_ABORT_FSC_MASK) <= FSC_PERM_FAULT_LEVEL3)
    vmm_monitor_mem_fault(vcpu, VMM_MONITOR_PERMISSION,
                         mrs(far_el2), iss);
~~~

该函数处理取指异常。FSC 是 ISS 低 6 位的故障状态；当前常量 0x0C～0x0F 对应权限错误 Level 0～3。这里的 Level 是页表层级，不是 EL0～EL3。

例如 Guest 尝试从 Hypervisor 页表禁止执行的区域取指，并进入这条异常处理路径，monitor 会记录权限异常。

记录为 type=3、code=4，address=FAR_EL2，detail=ISS。选择 FAR 是因为不能对所有权限异常都假定 HPFAR 提供有效 IPA；有效条件依体系结构特性及异常类型而定。[Arm 的 HPFAR_EL2 有效条件说明](https://documentation-service.arm.com/static/649ae5b238511951cb799288)

因此 code=4 的 address 不能统一当作 GPA/HPA，而应按故障虚拟地址及实际异常有效条件解释。不能只用这一数值去查物理内存分区。

### 5.4 打点 M3：cpu_vcpu_data_abort() 的权限错误

位置约 152～156 行，条件和记录方式与取指权限异常相同。

典型场景是 Guest 写入 Hypervisor 页表禁止写的映射。硬件报告权限错误，函数在原 switch 之前记录，然后继续原处理。它没有重新查询内存所有者、重新比较分区范围或添加授权规则。

对于已经明确属于 Data Abort 的 ISS，可以按其定义分析读写方向等字段。但当前事件没有单独保存 EC，取指和数据权限异常都用 code=4，不能仅凭该 JSON 稳妥区分所有取指、读、写情况。

### 5.5 原异常处置是否变化

打点返回后，原 switch 和返回值不变。在当前参考代码中，权限错误最终返回 VMM_EFAIL；do_sync 的原错误分支打印异常寄存器，并按原逻辑 halt 对应 vCPU。

这不是 monitor 新加的重置、隔离或停止策略。用户产品可能有不同的错误处置，应以实际产品原逻辑为准。

### 5.6 没有覆盖的分支

| 场景 | 当前这三个打点的行为 |
|---|---|
| 基本页查询失败 | 记录 code=2 |
| 查询成功但 availsz 小于基本页 | 原返回失败，本文件没有追加打点 |
| 尝试较大页查询失败，仍能使用小页 | 不记录新的违规 |
| mmu_map_page 失败，竞争重查成功 | 沿用原恢复逻辑 |
| mmu_map_page 失败且重查也失败 | 本文件当前没有追加打点 |
| 其他未接入的 FSC／模拟失败 | 不保证生成内存事件 |
| Guest 内部已经处理、没有进入这些 EL2 函数的异常 | 看不到 |
| Hypervisor 自身 EL2 普通指针异常 | 不由这些 Guest abort 打点覆盖 |
| 在有效映射内越过软件对象边界 | 页表可能不报错，这些打点不能识别 |

当前记录还没有异常 PC、完整 ESR、目标分区或共享对象名称。能定位到 Guest/vCPU 和已记录的错误类别，不等于已经给出访问者代码位置和完整根因。

## 6. cpu_hcall.c：共享缓冲区注册流程中的失败记录

### 6.1 这是 Hypervisor 侧代码

这里使用用户提供的私有 cpu_hcall.c 适配结果，不是 Linux CCM 驱动代码。monitor 的修改集中在 hcall_set_sbuf()，没有为 Linux 添加 ioctl，也没有把“只能 serverVM 注册”写成新的策略。

根据用户提供的分发关系：

~~~text
Guest 发起 HVC
    → do_sync() 识别 HVC，计一次 exit
    → cpu_vcpu_emulate_hvc64()
    → iss == HYPERCALL_ISS 时进入 dispatch_hcall()
    → HC_SET_SBUF 分支
    → hcall_set_sbuf(vcpu, target_vm, param1)
~~~

iss 不符合 HYPERCALL_ISS 时进入原 PSCI 路径，不能认为每一次 HVC 都会走注册函数。

### 6.2 这个函数原来做什么

hcall_set_sbuf() 的主要工作是：

1. 检查调用 vCPU 与目标 VM 指针。
2. 从调用者 Guest 的 gpa_sbuf_param 地址读取 struct sbuf_param。
3. 根据 sp.gpa 查询共享缓冲区物理映射。
4. 映射到 Hypervisor 虚拟地址，调用 sbuf_setup_common()。
5. 返回原处理结果。

这里必须区分三个对象：

| 对象 | 含义 |
|---|---|
| vcpu->guest | 发起此次 HVC 的 Guest，参数按它的地址空间读取 |
| target_vm | 注册操作的目标 VM |
| sp.gpa | 参数结构中给出的缓冲区地址 |

事件使用传入 vcpu 作为主体，所以 JSON guest 是调用者，不一定等于 target_vm。当前事件没有独立 target_guest 字段。

### 6.3 打点 C1：读取参数结构没有得到完整长度

位置约 845～849 行：

~~~c
res = vmm_guest_memory_read(vcpu->guest, gpa_sbuf_param,
                           &sp, sizeof(sp), TRUE);
if (res != sizeof(sp)) {
    vmm_monitor_mem_fault(vcpu, VMM_MONITOR_CCM_READ_FAILED,
                         gpa_sbuf_param, sizeof(sp));
    return VMM_EIO;
}
~~~

打点依据是实际返回字节数 res 不等于期望字节数 sizeof(sp)，不是 monitor 自己推断用户缓冲区越界。

| 字段 | 含义 |
|---|---|
| type=3、code=5 | CCM_READ_FAILED |
| address | 参数结构所在的调用者 GPA：gpa_sbuf_param |
| detail | 期望读取长度 sizeof(sp) |
| guest/vcpu | 调用者 |

detail 不是 res，不是未读取的字节数，也不是返回的 VMM_EIO。当前 JSON 没有保存实际读取了多少字节。

可能原因包括地址没有可读映射、跨越可访问区域导致短读等；记录本身只证明原参数读取没有成功完成。vcpu/target_vm 为空的更早返回分支没有这处记录。

### 6.4 打点 C2：注册流程最终返回失败

位置约 859～862 行：

~~~c
if (ret != VMM_OK)
    vmm_monitor_mem_fault(vcpu, VMM_MONITOR_CCM_REGISTER_FAILED,
                         sp.gpa, (u64)(s64)ret);
return ret;
~~~

| 字段 | 含义 |
|---|---|
| type=3、code=6 | CCM_REGISTER_FAILED |
| address | 参数中的缓冲区 GPA：sp.gpa |
| detail | 最终 ret，先按有符号 64 位扩展再保存为 u64 |
| guest/vcpu | 调用者，并非自动表示注册目标 |

这个打点位于最终返回前，不会重复执行参数读取失败分支中的 code=5，因为前者已经提前返回。

例如 sbuf_setup_common() 遇到不支持的 sbuf_id 会返回错误，也能触发 code=6。这显然不能直接解释成某次硬件内存越权。因此应将它描述为 CCM 注册失败证据。

### 6.5 为什么不能说“所有物理映射失败都会记录”

提供的原函数大致是：

~~~c
ret = vmm_guest_physical_map(..., &hpa, ...);
if (hpa) {
    hva = vmm_host_memmap(...);
    ret = sbuf_setup_common(...);
} else {
    ret = VMM_EINVALID;
}
/* 这里检查最终 ret */
~~~

它没有在 physical_map 返回错误后立即按 ret 分支退出，并且当前局部 hpa 没有在声明处初始化；后续代码还可能覆盖 ret。monitor 记录版沿用这个原流程，没有借机修复或重构。

因此 code=6 表示走到最终失败分支时的最终 ret。不能据此断言第一次映射调用的所有失败都被可靠保留，更不能把 detail 一律解读为该次映射调用的返回码。该原流程需要另行审查时，应作为独立代码问题处理。

## 7. vmm_u_ioreq.c：CCM 元素长度拒绝

### 7.1 打点 I1 的准确位置

函数：sbuf_put()；当前适配文件约 256 行。不同产品版本中它可能在 323 行附近，应以函数分支定位。

该函数把一个元素写入共享环形缓冲。原控制流为：

~~~c
ele_size = sbuf->ele_size;
next_tail = sbuf_next_ptr(sbuf->tail, ele_size, sbuf->size);

if (/* 队列满且禁止覆盖 */) {
    ret = 0U;
} else if (ele_size <= max_len) {
    /* 原复制、内存屏障、head/tail 更新 */
    ret = ele_size;
} else {
    vmm_monitor_mem_fault(NULL, VMM_MONITOR_CCM_ELEMENT_REJECTED,
                         0, ((u64)ele_size << 32) | max_len);
    ret = U32_MAX;
}
~~~

### 7.2 为什么这里与内存边界有关

ele_size 来自共享缓冲描述，max_len 是本次调用可提供数据的最大长度。请求按 ele_size 复制，但 ele_size 超过 max_len，原函数就进入尺寸拒绝分支，避免按更大尺寸执行该次 memmove。

这是“描述的元素长度超过本次可提供数据长度”的失败证据，与共享缓冲区的数据边界有关；max_len 不是整个环形缓冲区总容量。

它不代表 monitor 进行了完整的 head/tail、缓冲区容量、描述符所有权或访问授权检查。

### 7.3 记录字段怎样解析

| 字段 | 含义 |
|---|---|
| type=3、code=7 | CCM_ELEMENT_REJECTED |
| guest/vcpu | 都为 ~0U，打点传入 NULL |
| address | 0，没有保存具体缓冲区地址 |
| detail 高 32 位 | ele_size |
| detail 低 32 位 | max_len |

解码为：

~~~c
u32 ele_size = (u32)(detail >> 32);
u32 max_len  = (u32)detail;
~~~

例如 ele_size=16、max_len=8，说明描述要求复制 16 字节，但本次接口只提供 8 字节的长度边界。不能把整个 detail 当作一个长度。

NULL 主体使记录不依赖此函数没有传入的 vCPU 上下文，但也失去了发起方、目标 VM 和 sbuf 身份。不能从这条事件确定是 serverVM 还是 Android 的哪个请求造成的。

### 7.4 保留的原行为和漏报边界

原返回 0 表示缓冲区满且不覆盖，返回 ele_size 表示成功写入，返回 U32_MAX 表示失败。monitor 没有改变这些返回值、head/tail 更新、通知或覆盖策略。

分支顺序也没有改变：满且禁止覆盖的判断优先于 ele_size 检查。因此即使 ele_size > max_len，只要先命中满队列分支，本次调用仍返回 0，不会走到新增记录处。不能把代码简化描述为“任何 ele_size 超限都会记录”。

普通缓冲区满不是这处内存异常。原 sbuf 为空、损坏字段触发其他问题、地址未授权等情况，也不能靠这一条打点保证覆盖。

此外，调用这处宏的源文件必须包含当前 vmm_monitor.h；用户此前遇到的隐式声明和枚举未定义，就是接口声明或版本没有配套的典型表现。

## 8. vmm_shmem.c：通用共享内存接口的越界拒绝

### 8.1 三个函数对应三处打点

| 函数 | 参考行 | 原操作 |
|---|---:|---|
| vmm_shmem_read() | 47 | 从共享内存读到调用者缓冲区 |
| vmm_shmem_write() | 60 | 将调用者缓冲区写入共享内存 |
| vmm_shmem_set() | 73 | 把共享内存范围填成指定字节 |

三者都在原来的边界检查失败分支加一条：

~~~c
if (shm->size < (off + len)) {
    vmm_monitor_mem_fault(NULL, VMM_MONITOR_SHMEM_BOUNDS, off, len);
    return 0;
}
~~~

### 8.2 原判断与打点依据

shm->size 是共享对象大小，off 是对象内偏移，len 是访问长度。当原检查发现访问终点超过对象大小时，返回 0，并在返回前记录。

以大小 4096 字节的对象为例，在算术没有溢出的情况下：

| off | len | 访问含义 | 原检查 |
|---:|---:|---|---|
| 4095 | 1 | 最后一个字节 | 允许 |
| 4096 | 1 | 从对象末尾之外开始访问一个字节 | 拒绝并记录 |
| 4095 | 2 | 跨过对象末尾 | 拒绝并记录 |
| 4096 | 0 | 边界处零长度请求 | 不因该条件拒绝 |

拒绝发生在调用 vmm_host_memory_read/write/set 之前。因此在这些明确拒绝分支上，不会为了测试越界而真的执行越界物理访问。

### 8.3 字段含义及归属

| 字段 | 内容 |
|---|---|
| type=3、code=1 | SHMEM_BOUNDS |
| address | off，即对象内偏移 |
| detail | len |
| guest/vcpu | NULL 主体标记 |

address=4096 表示对象内偏移 4096，不是 HPA 0x1000，也不是 GPA 0x1000。记录未保存 shm 指针、名称、基地址和 size，也没有区分 read/write/set。

多个共享对象以及 CCM 的 NULL 主体错误共用额外摘要槽，所以可能被合并为同一摘要。只能通过最后的 code/address/detail 看最后一次错误细节，不能还原所有对象的错误分布。

### 8.4 不改变原策略意味着什么

空 shm、空源／目标缓冲区等原参数错误仍按原分支返回，不全部记录成边界越界。

原条件 off + len 存在无符号回绕的可能；记录版没有改写为防溢出的判断。极端参数绕过原条件时，新打点也不会自动发现。这一点已在隔离白盒中使用假后端观察，不能把测试通过解释成原判断已经修复。

头文件中的 vmm_monitor_range_valid() 使用减法形式判断范围，但它的存在不意味着已经替换了这里或所有产品边界条件。

这里也没有新增 Guest 白名单、对象所有者检查或共享内存授权 API。此前新增的 vmm_shmem_guest_read/write 等包装不属于当前记录版。

### 8.5 不经过这些 API 的访问

Guest 直接访问已经映射的共享页、设备 DMA、其他后端直接 memcpy 共享区，都不一定调用 vmm_shmem_read/write/set。若未产生已接入的硬件异常，也不会被这里记录。

所以这三处打点证明的是“通用 shmem 接口原边界拒绝可以被观察”，不是“任意共享内存访问均由 monitor 检查”。

## 9. cmd_memory.c：Hypervisor 命令原检查的记录

### 9.1 为什么内存命令也能作为测试入口

用户产品的 mem 命令已经有 RAM、设备区域、Guest 区域分类和访问检查。monitor 加在原拒绝分支，能验证 Hypervisor 侧主动检查失败到事件记录的链路。

这不是硬件异常处理入口。它不通过构造任意 EL2 非法指针访问来触发异常，而是执行现有命令的合法性检查。

### 9.2 打点 H1：check_read_memory() 的范围拒绝

位置约 303～308 行：

~~~c
if (rc) {
    if (rc == VMM_ERANGE)
        vmm_monitor_mem_fault(vmm_scheduler_current_vcpu(),
                             VMM_MONITOR_HOST_RANGE_REJECT,
                             addr, (u64)wsz);
    return rc;
}
~~~

原函数根据 io 选择设备范围检查或 RAM 范围检查。这里只记录 rc == VMM_ERANGE，不把其他错误码，例如检查过程中分配失败，全部归为读越界。

记录 type=3、code=8，address 为命令待访问的宿主物理地址，detail 为本次访问宽度（字节）。检查函数每次收到的范围按原调用语义处理，不能把 detail 当作整条命令的总访问字节数。

### 9.3 打点 H2：check_write_memory() 的地址类型分类失败

位置约 333～339 行：

~~~c
rc = check_type_memory(cdev, addr, wsz, io);
if (rc) {
    vmm_cprintf(cdev, "Accessed an illegal address.\n");
    vmm_monitor_mem_fault(vmm_scheduler_current_vcpu(),
                         VMM_MONITOR_HOST_RANGE_REJECT,
                         addr, (1ULL << 32) | (u64)wsz);
    return rc;
}
~~~

check_type_memory() 按原逻辑尝试 RAM 和设备地址分类，失败后原命令拒绝写入。monitor 记录 type=3、code=8。

detail 高 32 位为 1，表示写；低 32 位为宽度。例：4294967297 = 0x00000001_00000001，表示写、宽度 1 字节。

与读检查不同，这里记录的是原分类函数返回失败。原分类过程可能合并底层失败原因，不能仅凭 code=8 就还原出是哪一个区域遍历或资源查询出了问题。

### 9.4 打点 H3：原策略禁止写 Guest 所属内存

位置约 341～347 行：

~~~c
if (!(*io)) {
    if (!check_guest_addr_range(cdev, addr, wsz, 1)) {
        vmm_cprintf(cdev,
            "This address belongs to the guest and can't be modified.\n");
        vmm_monitor_mem_fault(vmm_scheduler_current_vcpu(),
                             VMM_MONITOR_ACCESS_DENIED,
                             addr, (1ULL << 32) | (u64)wsz);
        return VMM_EFAIL;
    }
}
~~~

这里 code=3 的依据是产品原有命令权限规则：该写访问被判断属于 Guest 内存，命令不允许修改它。

这条规则在 monitor 之前就存在；monitor 没有新增“Hypervisor 绝对不能访问 Guest 内存”的通用规则。Hypervisor 正常仿真、后端和内存管理仍可通过各自原接口执行授权工作。

JSON 的 vcpu 是运行检查函数的线程，例如 mterm 或 unittest 线程；guest 常为 ~0U。它不是被保护 Guest 的 vCPU ID。事件没有另外保存被保护的目标 Guest ID。

### 9.5 原检查、测试适配和真实内存访问的区别

为复用原检查而提供的测试接口只有 CONFIG_WBOXTEST_MONITOR 开启时存在，声明合并在 vmm_monitor.h 中。

| 测试接口 | 做什么 | 是否实际访问物理内存 |
|---|---|---|
| vmm_monitor_host_probe() | 使用原分类函数识别 RAM、DEVICE、GUEST 候选 | 否 |
| vmm_monitor_host_guard() | 调用原读／写检查，命中拒绝时经过真实生产打点 | 否 |

测试适配要求 width 为 1、2 或 4，并检查地址运算边界。这是测试接口的输入约束，没有插入到所有原命令调用路径中。

原 check_addr_range/check_device_addr_range 存在临时分配。执行命令或测试看到堆活动，不能直接推断 monitor 采集器在每次打点动态分配了内存。

~~~mermaid
flowchart TD
    A["mem 命令或白盒 guard"] --> B["原地址分类 / 范围 / Guest 保护检查"]
    B --> C{"是否进入已接入拒绝分支？"}
    C -- 是 --> D["记录 HOST_RANGE_REJECT 或 ACCESS_DENIED"]
    D --> E["返回原错误"]
    C -- 否 --> F["检查通过"]
    F --> G["真实命令继续原访问流程"]
    F --> H["测试 guard 直接返回，不执行物理访问"]
~~~

### 9.6 这组打点证明不了什么

它不能监控绕过命令检查的任意 C 指针访问，也没有把 Hypervisor 整个地址空间变成逐次软件检查。某个地址被原代码分类为允许访问时，monitor 不会根据需求文字另行否决。

原区域判断、地址运算、重叠配置有缺陷时，记录器不会补出原代码没有作出的拒绝。这是记录版保持策略不变的实际边界。

## 10. 用户 VGIC / vmm_host_irq 原打点与 monitor 的关系

### 10.1 VGIC 的 irq_cnt 究竟统计什么

用户提供的 vgic.c.txt 中，__vgic_queue_irq() 约 555 行和 619 行均有：

~~~c
vgich.ops.set_lr(lr, &lrv);
vmm_monitor_irq_injected(vs->vcpu, irq);
arch_atomic64_add(&vs->vcpu->trap_stat.irq_cnt[index], 1);
~~~

一处位于已有 LR 更新分支，随后返回 TRUE；另一处位于分配新 LR 后。因此一次函数调用不会同时执行两次加一；没有可用 LR 而返回 FALSE 时不会增加这两处计数。

index 的代码分类为：

| 下标 | 条件与含义 |
|---|---|
| 0 | irq <= 15，SGI |
| 1 | irq < 32，PPI |
| 3 | VGIC_IRQ_IS_LPI 成立，LPI |
| 2 | 其余进入该路径的非 LPI 中断，通常对应 SPI 分类 |

准确地说，它统计在这条路径中完成的 LR 写入/更新次数。已有 LR 即使本来就是 PENDING，仍可能再次执行 set_lr 和计数，所以不能等同于独立的新中断次数，更不表示 Guest 已执行完成中断处理。

### 10.2 为什么不能替换 do_irq 的 exit 计数

| 对比 | VGIC irq_cnt | do_irq 中 monitor_exit |
|---|---|---|
| 观察动作 | 写入/更新 Guest 虚拟中断 LR | 进入 EL2 IRQ 异常处理 |
| 归属语义 | 接收虚拟中断的目标 vCPU | 被中断打断的 Guest vCPU |
| 是否一定有一次新的 Guest exit | 不一定 | 符合来源条件才计数 |
| 是否一定有一次 Guest 虚拟注入 | 记录 LR 操作 | 不一定 |

例如 Hypervisor 自身定时器打断 Guest，do_irq 计一次 exit，但可能不向 Guest 注入中断。一次退出处理或调度恢复又可能提交多个 pending 中断，使 LR 操作次数多于入口次数。

该 __vgic_queue_irq 要求目标是当前 vCPU；这条执行约束不改变其“向目标提交中断”的含义，不能由此推导每次 LR 写入都对应一次新 IRQ 入口。

可以保留 irq_cnt 作为虚拟中断活动的产品统计；如果要用它替换 exit 计数，统计口径会改变。

### 10.3 邻近的早期注入延时打点

桌面参考文件中还保留了以下历史接口：

| 文件与位置 | 历史打点 | 设计上记录的阶段 |
|---|---|---|
| vmm_host_irq.c::vmm_host_generic_irq_exec | hirq_enter/hirq_exit | 软件开始/结束处理某个物理 IRQ 的上下文 |
| vgic::__vgic_set_pending | irq_pending | 虚拟中断由未 pending 进入 pending |
| vgic::__vgic_clear_pending | irq_cancel | 清除 pending 对应的追踪 |
| vgic::__vgic_queue_irq | irq_injected | 写入 LR 的终点 |

它们属于早期注入延时设计，与当前 exit 风暴入口计数不是同一个功能。早期软件处理起点也不等于外设真实拉起物理中断线的瞬间。

当前 vmm_monitor.h 没有这些历史接口，当前精简版也没有保留其完整测量链路。不要把桌面参考文件里出现这些调用理解成当前 schema=3 已支持注入延时上报。

历史片段本身还显示覆盖差异：set_pending/cancel 的 monitor 调用只在非 LPI 分支，注入终点则在公共 LR 路径。不能据此宣称 LPI 延时完整覆盖。

此外，桌面 vmm_host_generic_irq_exec 片段在 hirq_enter 后存在找不到 IRQ 对象就提前返回的路径，而 hirq_exit 在后面；如果继续使用该历史追踪，需要另外核对上下文是否配对恢复。本文不修改此历史代码。

### 10.4 复用原统计的原则

能够复用的是语义相同的时间点或数据。不能仅因为两个调用位置接近、都位于中断相关文件、或字段叫 trap_stat，就把它们当作同一个指标。

调度器已经尽量复用原时间戳；VGIC 原 irq_cnt 可以继续用于注入活动；同步异常分类计数能否替代入口计数，需要另外满足完整覆盖、时间窗口、复位和并发一致性条件。

## 11. monitor_agent.c：打点数据怎样变成事件

### 11.1 主要数据结构

这里没有为每一次异常创建独立动态对象。主要结构均由静态数组持有。

| 结构 | 主要字段 | 用途 |
|---|---|---|
| struct latency | count、sum、max | 累计样本数、耗时总和、最大值 |
| struct event | seq、time、last、type、guest、vcpu、epoch、code、value、address、detail、config_seq、sustain_s | 一条事件 |
| struct data | ready、dispatch、ready_since、waiting | 单对象调度统计 |
| struct data | exits、count、previous、interval、valid | 正在累计的退出数及上一次采样结果 |
| struct data | windows、sustained、active | 风暴连续超限和去重状态 |
| struct data | memory | 该对象的内存摘要 |
| struct slot | lock、d | 单槽锁及其数据 |
| slots | MAX_VCPU_COUNT+1 个槽 | 各调度对象加一个 NULL 主体 |
| ring | 16 个事件 | 有限历史与后台日志待消费事件 |

exits 与 count 不是同一变量：exits 是采样前正在累加的退出次数；采样时复制到 count，再将 exits 清零。status 中显示的 exits 对应 count，是最近一次完成窗口的结果。

### 11.2 记录器的四个关键分支

调度等待：

~~~text
STATE READY：如尚未等待，ready_since = 传入时间，waiting = true
SELECTED：如 waiting 且时间有效，累计终点减起点；然后 waiting = false
~~~

dispatch：

~~~text
终点 >= 起点时，累计终点减起点
~~~

exit：

~~~text
exits 加一；last_exit = 本次原因
~~~

内存摘要：

~~~text
读取本次时间，更新 last
如果此前次数为 0，保存首次 time
value 加一
更新主体、epoch、code、address、detail
~~~

正常记录要求 initialized 且 enabled。生命周期 RESET/UNKNOWN 有专门处理，不等同于 stop 后还在持续采集业务事件。

### 11.3 内存摘要的“合并”并不是逐类型去重

假设同一 vCPU 在一次刷新前出现：

~~~text
10.10 秒：code=2，映射查询失败，地址 A
10.20 秒：code=4，权限错误，地址 B
10.30 秒：code=5，CCM 参数读取失败，地址 C
~~~

最终摘要可以是：

~~~text
time_ns = 10.10 秒
last_ns = 10.30 秒
value = 3
code = 5
address/detail = 最后一次 CCM 参数读取失败的信息
~~~

它不能被解释成“地址 C 读取失败三次”。不同 code、不同地址也可能聚合。不同 vCPU 独立存槽，NULL 主体的多种调用共用同一个额外槽。

memory_flush() 发现 value 非零就把摘要送入事件环，然后把 value 清零；后续新摘要重新建立首末时间。采样、槽生命周期清理等路径会调用它。

内存异常没有应用 exit_limit 或 sustain_s 门限。只要监控开启且命中打点，就更新摘要，之后发布；也没有跨多个采样周期保持 active 的内存告警去重状态。持续内存错误可能持续产生摘要。

### 11.4 exit 风暴如何判定

默认每秒采样一次；默认 exit_limit=50000/s、sustain_s=5，实际配置可修改。

每个有效 Guest 槽按真实间隔判断：

~~~text
high = 本窗口次数 > floor(exit_limit × interval_ns / 1,000,000,000)
~~~

使用严格大于，因此恰好等于阈值不算超限。不能只比较“本窗口次数 > exit_limit”，因为实际间隔可能略大于或小于一秒。

未告警且本窗口超限时，windows 加一，sustained 累加真实窗口时长。两项都满足才生成事件：

~~~text
windows >= sustain_s
并且
sustained >= sustain_s × 1秒
~~~

这里 windows 的门限沿用一秒采样设计。持续时间是根据已观测窗口推断的连续超限，不代表逐条退出间隔都已检查。采样误差或窗口偏短可能使触发需要多一个窗口。

事件 value 保存触发窗口的归一化速率：

~~~text
floor(count × 1,000,000,000 / interval_ns)
~~~

它不是整段五秒的平均值或最大值。风暴事件的 time_ns 是达到判定条件时的采样时间，不是第一条异常退出的时间；当前 time_ns 与 last_ns 相同。

### 11.5 去重、恢复与再次触发

~~~mermaid
flowchart TD
    A["尚未处于已告警状态"] --> B{"有效窗口是否超限？"}
    B -- 否 --> C["清空连续窗口与持续时间"]
    B -- 是 --> D["累积窗口数和实际时长"]
    D --> E{"两个持续条件都满足？"}
    E -- 否 --> A
    E -- 是 --> F["发出一次 type=1 事件，active=true"]
    F --> G{"后续有效窗口"}
    G -- 仍超限 --> H["保持 active，不重复发事件"]
    H --> G
    G -- 不超限 --> I["active=false，恢复可告警状态"]
    I --> A
~~~

去重主体是单个 Guest vCPU 的连续超限过程，不是某一个 code。多个 vCPU 同时超限仍会各产生事件。last_exit 改变不意味着新一轮风暴。

有效低速窗口会清除 active。无效采样窗口只清空连续窗口和持续时间，不清除已经告警的 active，避免因采样缺口制造“恢复后重新告警”。

修改配置时丢弃跨新旧配置的混合窗口，但保留 active；修改阈值和查询本身不会要求立即重复提醒。需要在新配置下观察到有效低速窗口，才重新具备下一轮触发条件。

这些动作只有事件记录和日志，不新增 vCPU 重置、屏蔽中断、限流或停止 Guest 的风暴处置。

### 11.6 采样间隔、跳过和有效性

内部 tick 在 Hypervisor 定时器回调中调用 vmm_monitor_sample()，不是由优先级 3 的日志线程每秒读取一次。

sample 对每个槽使用 trylock。某槽繁忙时跳过，增加全局 skipped，避免在这个采样位置长时间等锁；该槽退出次数会继续累计，直到以后成功采样。

默认有效间隔为 750～1250ms。比如一秒采样被跳过，下次成功可能得到约两秒的间隔，于是 valid=0。无效窗口不会用来延续风暴累计，但仍可能显示次数。

skipped 是全局槽跳过次数，不能单独证明某个目标 vCPU 始终未采样。status 逐槽读取，也不是所有 vCPU 同一时刻的原子快照。

### 11.7 事件环与日志消费

emit() 为事件分配递增 seq，写入 16 项固定环。超过容量时旧记录会被覆盖；尚未被日志消费就被覆盖的事件会使 lost 增加。已经消费过的历史记录也可能被覆盖，但不一定增加 lost。

drain() 每次最多消费 8 条，在复制事件并释放事件锁后调用：

~~~c
vmm_lwarning("monitor", "%s", line);
~~~

JSON 格式化使用局部缓冲区，日志后端按产品实现存储并回显到控制台。这里没有新增第二条串口提示。

事件入环后，可由 monitor events 查询，也可由后台 drain 消费。查询不推进日志消费 cursor，也不把已查询事件删除，所以重复执行 events 会看到仍保留的历史。

如果产品日志后端截断长行，需要核对其实际缓冲区和存储结果。看到测试 EVENT 摘要完整，不等于 warning JSON 已完整落盘；日志仍需人工验证。

### 11.8 高优先级采集和确定性的实际含义

打点在原 Hypervisor 调度或异常路径执行，周期判定在 Hypervisor 定时器上下文执行；后台工作线程只负责日志输出。这使高优先级任务的调度观察不依赖日志线程先抢占它。

但关中断、锁竞争、定时器延迟、日志后端阻塞仍可能影响数据时效。代码用 skipped 和 valid 暴露部分质量问题，不能由“运行在 Hypervisor”推出任意负载下绝对准点或完全无丢失。

运行期间的新增采集数据使用静态存储，并不自动证明 ROM ≤5KB、CPU <0.5% 已达标。这两项需要用最终产品编译结果和目标板负载测量验收。

## 12. 启动、命令与开关怎样影响打点

### 12.1 vmm_main.c 的初始化接入

system_init_work() 在 IOMMU 初始化后、模块初始化前调用：

~~~c
ret = vmm_monitor_init();
if (!ret)
    ret = vmm_monitor_cmd_init();
if (ret)
    vmm_printf("monitor_agent unavailable (error %d)\n", ret);
~~~

失败输出 unavailable，随后继续原模块初始化，不因可选 monitor 初始化失败直接阻止 Guest 启动。

这不是事件打点，而是所有生产接口的初始化接入。命令仍通过产品原有命令管理和认证路径，没有绕过 auth/mterm。

### 12.2 vmm_monitor_init()

初始化槽锁；记下初始化所在核 sampler_cpu。内部执行器模式下建立工作项、定时器和名为 monitor 的工作队列，日志线程优先级使用 CONFIG_MONITOR_PRIORITY，默认 3，并绑定到 sampler_cpu。

定时器从约一秒后开始运行；初始化完成后才发布 initialized。只有 CONFIG_MONITOR_START_ENABLED 开启才自动 start，否则等运行时命令。

CONFIG_MONITOR_EXTERNAL_EXECUTOR 模式不创建内部队列/定时器；需要平台按约定从 HV 定时上下文串行调用 sample，并在适当工作线程串行 drain。仅编译这个选项不会自动提供外部执行器。

### 12.3 start 与 stop

| 操作 | 实际效果 |
|---|---|
| start，原来关闭 | epoch 加一，允许新事件采集；各槽下次接触时按新 epoch 懒清理 |
| start，原来已开启 | 保持当前采集，不再次清零 |
| stop | 关闭正常新事件记录；保留已有槽数据和历史事件 |
| stop 后查询 status/events | 仍可查询保留数据 |

stop 不销毁定时器和工作队列。stop 之前积累的内存摘要仍可被刷新、日志仍可完成消费；已经进入执行的采样也可能完成一次。因此不能要求 stop 返回的一瞬间所有输出绝对停止。

验证 start/stop 应观察 enabled、epoch，以及稳定后新退出计数/样本是否继续增长。不要把“status 还能打印”当作 stop 失败。重新 start 后应按新 epoch 判断数据，历史事件环也可能保留旧 epoch 事件。

### 12.4 status、events、config 各是什么

status 是统计视图：最新完成采样窗口的退出数据、累计延迟以及查询时的等待年龄；不是 vcpu list 的当前 Running/Paused 状态快照。

events 是有限事件历史，不包含所有调度样本。当前没有调度阈值告警，只有正常调度活动时 events 为空是可能且正常的。

config 查询输出简短文本；修改成功输出 OK: key=value，不再把配置 JSON 自动打印出来。

当前可修改参数为：

| 命令键 | 范围 | 默认 | 含义 |
|---|---|---:|---|
| exit_limit | 1～1000000000 | 50000 | 单 Guest vCPU 退出速率门限，次/秒 |
| sustain_s | 1～60 | 5 | 连续超限时长要求 |
| window_min_ms | 1～1000 | 750 | 有效采样间隔下限 |
| window_max_ms | 1000～10000 | 1250 | 有效采样间隔上限 |

这四个参数不包含采样周期。window_min/max 是质量判定范围，不是控制 tick 周期。

当前周期固定约一秒。VMM_MONITOR_NS 同时用于秒/纳秒换算，不能单纯改小它来改采样频率，否则速率和持续时间的单位也会改变。

### 12.5 输出通道的实装范围

当前已接入命令查询和产品日志接口。可通过命令字符设备输出 JSON，但本文核对的生产文件没有独立实现完整的 virtio-serial 导出器或共享内存诊断协议。

如果产品已有字符设备或日志后端把数据送往诊断 VM，那属于产品接入，需要单独确认。存在 vmm_shmem 或 CCM 打点不等于已经实现 monitor 的共享内存上报。

## 13. JSON 按什么顺序解析

### 13.1 先判断 status 还是 event

status 的对象行包含 kind、ready、dispatch、interval_ns 等；event 行包含 seq、type、code、value、address、detail 等。schema=3 表示字段格式版本，不表示事件严重程度。

解析数字时使用能完整保留 64 位整数的工具。某些 JavaScript JSON 处理方式会把大整数转换成浮点数，导致负错误码的无符号表示、长时间戳或打包 detail 丢精度；Python 的整数解析可完整保留这些值。

### 13.2 status 的重要字段

| 字段 | 正确含义 |
|---|---|
| enabled | 当前是否启用正常采集 |
| epoch | 一次运行采集周期的标识，不是墙上日期 |
| sampler_cpu | 初始化/内部采样所在核 |
| events | 事件序号 head，不能当作当前环中有效条数 |
| lost | 未消费就被覆盖的事件数 |
| skipped | 周期采样尝试取槽锁失败的累计次数 |
| errors | 内部定时器重启或工作调度等错误计数，不是 Guest 内存错误总量 |
| kind | guest、host、idle |
| time_ns | 此对象最近更新的采样边界时间 |
| interval_ns | 此对象该窗口的实际长度 |
| valid | 该退出采样间隔是否满足有效范围，不保证所有指标和硬件整体正常 |
| exits | 最近完成窗口的次数，不一定恰好等于每秒速率 |
| ready_age_ns | 当前已观察到且未结束的等待年龄；关闭采集时输出 0 |
| ready / dispatch | 当前 epoch/槽生命周期内累计的 count、mean、max |

如需估计速率，用 exits × 1e9 / interval_ns，同时检查 valid。窗口跨两三秒时，不能把 exits 原值当成每秒次数；旧 time_ns 也说明它不是查询瞬间的全部实时状态。

### 13.3 type 决定 code 的命名空间

| type | 事件类型 | code 的解释 |
|---:|---|---|
| 1 | exit 风暴 | 触发窗口最后退出原因，通常是 ARM EC 或软件标记 256 |
| 3 | 内存/CCM 类摘要 | 下表定义的监控代码 1～8 |

当前实现没有把 type=2 定义成一个已输出的调度超限事件。

例如 type=1、code=1 表示该风暴窗口最后原因对应 WFI/WFE；type=3、code=1 则是共享内存接口边界拒绝。不能脱离 type 直接解释 code。

### 13.4 内存类字段完整对照

| code | 名称 | address | detail | 能下的直接结论 |
|---:|---|---|---|---|
| 1 | SHMEM_BOUNDS | 共享对象内偏移 | 本次长度 | 原 shmem 边界分支拒绝 |
| 2 | MAP_REJECT | 原路径传入的 IPA | 原 rc 的 u64 表示 | 基本页映射查询失败 |
| 3 | ACCESS_DENIED | 命令待写宿主物理地址 | 高32位写标志，低32位宽度 | 命令原 Guest 内存保护规则拒绝 |
| 4 | PERMISSION | FAR_EL2 | ISS | 命中已接入的硬件权限错误分类 |
| 5 | CCM_READ_FAILED | 参数结构 GPA | 期望结构长度 | CCM 参数读取未完成 |
| 6 | CCM_REGISTER_FAILED | 参数中的缓冲区 GPA | 最终有符号 ret 的 u64 表示 | CCM 注册流程最终失败 |
| 7 | CCM_ELEMENT_REJECTED | 0，未保存地址 | 高32位 ele_size，低32位 max_len | 原元素长度分支拒绝 |
| 8 | HOST_RANGE_REJECT | 命令待访问宿主物理地址 | 高32位读/写，低32位宽度 | 命令原范围/分类失败 |

对于 code=8，当前读打点高32位为0，写打点高32位为1。code=3 当前只有写路径。

code=4 没有独立的指令/数据子类型，detail 不是完整 ESR；code=5 没有实际短读字节数；code=7 没有 sbuf 身份。不能从未记录的字段反推出这些信息。

### 13.5 两个字段组合示例

下面只展示解释样例，不是本次新增的目标板运行证据。

~~~json
{"schema":3,"seq":20,"time_ns":97029389940,"last_ns":97029389940,"type":3,"guest":4294967295,"vcpu":38,"epoch":1,"code":3,"value":1,"address":536870912,"detail":4294967297,"config_seq":0,"sustain_s":0}
~~~

解释：主体为 Hypervisor 的 vCPU/线程 38；有一次内存类摘要，最后错误是命令禁止写 Guest 内存。被拒绝的宿主物理地址为 0x20000000，写入宽度为 1 字节。不能把 guest=~0U 理解成被保护 Guest 的编号。

~~~json
{"schema":3,"seq":11,"time_ns":89026424620,"last_ns":89026424620,"type":1,"guest":0,"vcpu":70,"epoch":1,"code":256,"value":2876,"address":0,"detail":1,"config_seq":5,"sustain_s":5}
~~~

解释：Guest 0 的 vCPU 70 达到一次风暴判定。触发窗口速率为 2876/s，配置门限为 1/s，持续条件为 5s，配置版本5。最后退出原因是 IRQ 软件标记256，但这不证明该窗口所有退出都是 IRQ。address=0 在这里不是访问空地址，而是风暴事件没有保存地址。

### 13.6 解析打包值及错误码

~~~python
def decode_memory_event(event):
    if event["type"] != 3:
        return {"kind": "not_memory"}
    code = event["code"]
    detail = event["detail"]
    if code in (3, 8):
        return {"write": bool(detail >> 32),
                "width_bytes": detail & 0xffffffff}
    if code == 7:
        return {"element_bytes": detail >> 32,
                "provided_bytes": detail & 0xffffffff}
    if code in (2, 6):
        signed_error = detail if detail < (1 << 63) else detail - (1 << 64)
        return {"error": signed_error}
    if code == 4:
        return {"iss": detail, "fsc": detail & 0x3f,
                "access_kind": "not_recorded_separately"}
    return {"detail": detail}
~~~

这段只示范字段解码，不执行内存访问，不替代事件主体、时间窗口、地址有效性及产品策略的分析。

## 14. 现有测试对这些打点证明了什么

本文目的仍是解释打点；这里给出测试与打点的对应，避免把算法白盒通过误当成所有硬件路径已经验证。

| 用例 | 实际验证内容 | 不能据此直接证明 |
|---|---|---|
| monitor_scheduler | 隔离实例的 READY 起止、重复通知、取消等待、dispatch 累计、主体分类 | 产品每条调度路径都已正确合入，真实硬件端到端调度时延 |
| monitor_storm | 精确阈值、连续窗口、恢复、去重、无效窗口、配置变化等状态机 | 目标板真实异常入口已经执行 |
| monitor_storm_runtime | 调低真实配置，观察已有 Guest 的真实退出流经过生产采样、触发、去重、恢复、再次触发 | 指定异常类别必然构成真实负载风暴，所有 vCPU/FIQ 路径均覆盖 |
| monitor_memory | 通用 shmem 原实现的隔离副本：合法边界、拒绝、摘要、关闭采集、原回绕行为 | 真实 Guest 触发页表权限异常，CCM 每条路径覆盖 |
| monitor_host_range | 经生产命令原检查触发范围拒绝并观察事件 | 任意 Hypervisor 指针访问都有检测 |
| monitor_host_guest_guard | 经命令原规则拒绝写 Guest 所属地址，并观察事件；不实际写入 | Guest 跨域访问、硬件权限异常已验证 |
| monitor_host_shmem | 实际共享对象接口的越界拒绝和生产事件链路 | Guest 直接访问共享页的所有逻辑越界都能检测 |
| monitor_output | 隔离实例的结构化输出、摘要、事件环及消费行为 | 产品日志一定完整落盘 |
| monitor_lifecycle | 开关、epoch、复位等隔离生命周期行为 | 任意认证/终端负载下没有调度问题 |
| monitor_config | 参数范围、修改与输出等隔离行为 | 所有调度、内存异常均有可配阈值 |

真实风暴测试不是调用测试 API 给生产 exits 人工加数。它选择已有 Guest vCPU，使用真实退出流，临时提高门限观察安静阶段，再降低门限触发、去重、恢复和再次触发，最后恢复原配置。

最新稳定性调整使用很低的测试门限 1/s，目的是让已有 Guest 的自然退出更容易连续超限。这降低了负载波动导致测试中断的概率，但不是从原理上保证 Guest 永远持续退出；若被测 Guest 停止、速率降到门限以内或窗口质量不满足条件，测试仍可能不能完成预期证据链。

单独放在函数内的权限/MAP_REJECT 打点，以及私有 CCM code=5/6/7 的真实产品触发，需要相应路径确实执行后再验收。现有十项测试全通过，不等于这些未触发路径也已经在目标板覆盖。

日志文件内容、JSON 是否截断、持久化、ROM、CPU 开销和目标板采样时效，仍是独立验收项。

## 15. 手工核对产品合入时的定位表

### 15.1 按行为核对，不按行号覆盖

| 文件 | 需要核对的内容 |
|---|---|
| 产品 vmm_scheduler.c | 状态提交和重新入队均通知；首次、不同目标、同目标重选均结束等待；dispatch 只在外层统一计一次 |
| cpu_interrupts.c | do_sync 在 EL2 自身分支之后；do_irq 使用保存的 pstate；检查产品向量是否真的调用 FIQ 函数 |
| cpu_vcpu_excep.c | 基本页 map 失败打点；两个权限分类打点；权限地址使用 FAR 的语义 |
| cpu_hcall.c | 参数短读与最终注册失败两个分支；不把调用者 guest 当成 target_vm |
| vmm_u_ioreq.c | sbuf_put 原长度拒绝分支；打包 detail；正确包含 monitor 头文件 |
| vmm_shmem.c | read/write/set 的原范围拒绝处；NULL 主体；address 为偏移 |
| cmd_memory.c | 读范围失败、写分类失败、原 Guest 写保护三个分支；不在 guard 中执行物理访问 |
| monitor_agent.c | 主体识别、epoch、内存聚合、实际间隔、有效窗口、风暴去重、事件环、日志调用 |
| vmm_main.c / cmd_monitor.c | 可选初始化、命令注册、start/stop/config 的实际语义 |
| 产品 VGIC / vmm_host_irq.c | 原统计保留；历史注入延时接口不误当作当前 exit 统计，也不与当前头文件混用 |

### 15.2 本次说明纠正和明确的事项

1. do_hyp_fiq 在当前参考向量中没有调用路径；以前泛称 IRQ/FIQ 都已覆盖的表述应以本次说明为准。
2. VGIC trap_stat.irq_cnt 记录 LR 写入/更新，不是 Guest IRQ exit，也不是 Guest 完成中断处理。
3. dispatch 是产品 t1/t2 的调度代码区间，和 READY 等待不能简单相加。
4. code=2 是映射查询失败；code=5/6 是 CCM 流程失败，不能一律解释成已证明的越权。
5. code=4 的 address 是 FAR 语义，权限记录没有独立保存 EC/PC。
6. 内存摘要保留最后错误明细，value 不是对该最后 code/address 的逐类型计数。
7. sbuf_put 的满队列分支优先；shmem 原加法范围条件存在回绕边界。这些原行为没有因记录版而修复。
8. 当前输出使用命令和日志，不从共享内存/CCM 打点反推完整诊断 VM 导出协议已经存在。

## 附录 A. 源码定位与本次核对记录

以下索引由本次实际读取的文件生成。路径用于回看已交付参考代码；源码中的函数与条件分支才是产品手工合入的定位依据。

| 序号 | 内容与文件 | 行数 | SHA-256 |
|---:|---|---:|---|
| 1 | [产品调度器：vmm_scheduler.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_scheduler_history_适配_20261022/core/vmm_scheduler.c>) | 1851 | accd975347050b958acd52233b471c32de4d5db25f46a9203e9f80261ebd7516 |
| 2 | [ARM64 异常入口：cpu_interrupts.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_interrupts.c>) | 252 | 443ef291fa46591cc4395cf3e28a0378349d6df6e7da2170f54e81320f246792 |
| 3 | [ARM64 异常向量：cpu_entry.S](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_entry.S>) | 647 | 1943a6d42d7e9a29ed1887ba8bfd76b95dc6247e4a7ccd764cfd7bbe1f7183c8 |
| 4 | [ARM64 abort 处理：cpu_vcpu_excep.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_vcpu_excep.c>) | 201 | e3f11f2d26771b8cbf265478ab51b669ec2bb286c7dcb6ca438284453f41d90f |
| 5 | [ARM64 异常常量：cpu_defines.h](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/include/cpu_defines.h>) | 1030 | 2e9d88a2627fe4d77553fc18eb727387af76f9a4551b1afd956165c072c5c261 |
| 6 | [私有 HVC 实现：cpu_hcall.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_observer_from_20261023_v4_20261025/full_files/private_hypervisor/arch/arm/cpu/arm64/cpu_hcall.c>) | 1164 | f1462d08904ec52b658bf1224be5a5542d7f6109f9a2cf37d6023e3599e3f14f |
| 7 | [私有 CCM 缓冲实现：vmm_u_ioreq.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_observer_from_20261023_v4_20261025/full_files/private_hypervisor/core/vmm_u_ioreq.c>) | 457 | 5b640eeb26ee67b6f8781dcf507058a19567f3ab3937b5869af516521318374f |
| 8 | [通用共享内存实现：vmm_shmem.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/vmm_shmem.c>) | 245 | 5f97c11fcfaaf4bd943d1c9d746565627a0eaa895bcbbcfc3172d0f11cb482f8 |
| 9 | [产品内存命令：cmd_memory.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_runtime_storm_v4_20261026/observer_base/full_files/private_hypervisor/commands/cmd_memory.c>) | 900 | 6b121aad3624e64d315f4f113d731cbc925c6e6a70165783057dc0f9e2a3a361 |
| 10 | [Guest 映射查询：vmm_guest_aspace.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/vmm_guest_aspace.c>) | 1652 | 25ac396b9f4f48ce31712cf7631a97579b610f35c0a42dbc7a8629a59f222009 |
| 11 | [Monitor 公共接口：vmm_monitor.h](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/include/vmm_monitor.h>) | 100 | b4c4a76ebd6555d39a5ac72884b8d6bd4ab17b93f3e16412714bae79becaad18 |
| 12 | [Monitor 记录与事件处理：monitor_agent.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c>) | 470 | 9f7f3703f209515054467d5b56a6a2de14d07495a9a50ee743cfb1d92e4720c2 |
| 13 | [Monitor 编译配置：openconf.cfg](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/openconf.cfg>) | 44 | 35e59d3d9c1e6468fd43e8be07b6c959816f5715e5799b9201edae18af57bd9c |
| 14 | [Monitor 命令：cmd_monitor.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/commands/cmd_monitor.c>) | 56 | ef1856ebb50738468f81ded512225374caeaec4b3c04c6833000be8b8d3301aa |
| 15 | [系统初始化接入：vmm_main.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/vmm_main.c>) | 881 | adc077a4456c274cb956b3cb53a7992add7615decdbf49df7bb113d18f261cff |
| 16 | [产品 VGIC，含历史接口：vgic.c.txt](<C:/Users/win/Desktop/vgic.c.txt>) | 1782 | c45b65457945d9646f65c63db9037f7697d3f9426bf08926d9c8f1a5e8986e88 |
| 17 | [产品物理中断处理，含历史接口：vmm_host_irq.c.txt](<C:/Users/win/Desktop/vmm_host_irq.c.txt>) | 1126 | b8cdce4328c9403e92c4fb375c226589614d19952240b410ed9e2dc8cdd1825d |
| 18 | [调度隔离白盒：scheduler.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/libs/wboxtest/monitor/scheduler.c>) | 47 | 47aeeb2060f052a8d733f52df12fae715f6a6ed7e002733b8cca9a2cd2acd604 |
| 19 | [共享内存隔离白盒：memory.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/libs/wboxtest/monitor/memory.c>) | 109 | e605e1caf9d627420ebbad2dd7dc36259fa3eba9c7760b0755577daecb74c4a8 |
| 20 | [风暴隔离白盒：storm.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/libs/wboxtest/monitor/storm.c>) | 66 | 89ead6e9c1bf024661b8c125d01406cd6611ca600e3d34157b47eaaa969a5daf |
| 21 | [真实内存拒绝测试：memory_runtime.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/libs/wboxtest/monitor/memory_runtime.c>) | 368 | f916a043653a7b690a547b788adb76dbb8e9cd30092af66de237ebc4f9a115f2 |
| 22 | [真实退出风暴测试：storm_runtime.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/libs/wboxtest/monitor/storm_runtime.c>) | 304 | 5ec4acd241adfd19ed15bbc67e945b165349a8ef251d380fa0327198f1c52b86 |

## 附录 B. 生产打点逐行清单

这里仅列当前记录版的生产调用，使用产品调度器版本，排除测试注入、宏定义和早期 IRQ 延时接口。条件编译分支的源码调用单独列出，不表示同一次运行会全部执行。

| 编号 | 文件与参考行 | 所属函数 | 调用 | 执行说明 |
|---|---|---|---|---|
| P01 | [vmm_scheduler.c:398](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_scheduler_history_适配_20261022/core/vmm_scheduler.c:398>) | __vmm_scheduler_next1() | vmm_monitor_selected | 当前生产接入 |
| P02 | [vmm_scheduler.c:480](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_scheduler_history_适配_20261022/core/vmm_scheduler.c:480>) | __vmm_scheduler_next2() | vmm_monitor_state | 当前生产接入 |
| P03 | [vmm_scheduler.c:513](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_scheduler_history_适配_20261022/core/vmm_scheduler.c:513>) | __vmm_scheduler_next2() | vmm_monitor_selected | 当前生产接入 |
| P04 | [vmm_scheduler.c:519](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_scheduler_history_适配_20261022/core/vmm_scheduler.c:519>) | __vmm_scheduler_next2() | vmm_monitor_selected | 同对象重选，history 编译分支二选一 |
| P05 | [vmm_scheduler.c:523](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_scheduler_history_适配_20261022/core/vmm_scheduler.c:523>) | __vmm_scheduler_next2() | vmm_monitor_selected | 同对象重选，history 编译分支二选一 |
| P06 | [vmm_scheduler.c:653](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_scheduler_history_适配_20261022/core/vmm_scheduler.c:653>) | vmm_scheduler_switch() | vmm_monitor_dispatch | 当前生产接入 |
| P07 | [vmm_scheduler.c:1232](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_scheduler_history_适配_20261022/core/vmm_scheduler.c:1232>) | vmm_scheduler_state_change() | vmm_monitor_state | 当前生产接入 |
| P08 | [cpu_interrupts.c:101](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_interrupts.c:101>) | do_sync() | vmm_monitor_exit | 当前生产接入 |
| P09 | [cpu_interrupts.c:224](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_interrupts.c:224>) | do_irq() | vmm_monitor_exit | 当前生产接入 |
| P10 | [cpu_interrupts.c:235](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_interrupts.c:235>) | do_hyp_fiq() | vmm_monitor_exit | 当前参考向量未调用，不能算作已生效覆盖 |
| P11 | [cpu_vcpu_excep.c:57](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_vcpu_excep.c:57>) | cpu_vcpu_stage2_map() | vmm_monitor_mem_fault | 当前生产接入 |
| P12 | [cpu_vcpu_excep.c:130](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_vcpu_excep.c:130>) | cpu_vcpu_inst_abort() | vmm_monitor_mem_fault | 当前生产接入 |
| P13 | [cpu_vcpu_excep.c:156](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_vcpu_excep.c:156>) | cpu_vcpu_data_abort() | vmm_monitor_mem_fault | 当前生产接入 |
| P14 | [cpu_hcall.c:847](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_observer_from_20261023_v4_20261025/full_files/private_hypervisor/arch/arm/cpu/arm64/cpu_hcall.c:847>) | dispatch_hcall() | vmm_monitor_mem_fault | 当前生产接入 |
| P15 | [cpu_hcall.c:860](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_observer_from_20261023_v4_20261025/full_files/private_hypervisor/arch/arm/cpu/arm64/cpu_hcall.c:860>) | dispatch_hcall() | vmm_monitor_mem_fault | 当前生产接入 |
| P16 | [vmm_u_ioreq.c:256](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_observer_from_20261023_v4_20261025/full_files/private_hypervisor/core/vmm_u_ioreq.c:256>) | sbuf_put() | vmm_monitor_mem_fault | 当前生产接入 |
| P17 | [vmm_shmem.c:47](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/vmm_shmem.c:47>) | vmm_shmem_read() | vmm_monitor_mem_fault | 当前生产接入 |
| P18 | [vmm_shmem.c:60](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/vmm_shmem.c:60>) | vmm_shmem_write() | vmm_monitor_mem_fault | 当前生产接入 |
| P19 | [vmm_shmem.c:73](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/vmm_shmem.c:73>) | vmm_shmem_set() | vmm_monitor_mem_fault | 当前生产接入 |
| P20 | [cmd_memory.c:305](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_runtime_storm_v4_20261026/observer_base/full_files/private_hypervisor/commands/cmd_memory.c:305>) | check_read_memory() | vmm_monitor_mem_fault | 当前生产接入 |
| P21 | [cmd_memory.c:336](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_runtime_storm_v4_20261026/observer_base/full_files/private_hypervisor/commands/cmd_memory.c:336>) | check_write_memory() | vmm_monitor_mem_fault | 当前生产接入 |
| P22 | [cmd_memory.c:344](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_runtime_storm_v4_20261026/observer_base/full_files/private_hypervisor/commands/cmd_memory.c:344>) | check_write_memory() | vmm_monitor_mem_fault | 当前生产接入 |

本次只整理说明文档，没有重新执行目标板、QEMU、交叉编译或日志落盘测试。文档验证检查源码调用覆盖、定位链接、Markdown 结构和样例字段解码，不把这些文档检查当成产品功能测试。

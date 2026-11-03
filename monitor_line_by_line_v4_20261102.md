# hos Monitor v4 源码逐行讲解

日期：2026-11-02。文档版本：v1；源码交付版本：v4；JSON 协议版本：schema=3。

本文按“原始代码片段 + 每一行的作用”讲解当前已交付 monitor，实现阅读时不需要来回翻以前的概要设计。
**这是代码解释文档，不是本轮代码修改包。** 引用代码直接取自核对后的源文件，源文件未被修改；带 Lxxxx 的代码框仅用于阅读，不能连同行号粘贴编译。

## 1. 阅读范围与版本依据

完整逐行覆盖以下五个 monitor 自有文件：

- `core/include/vmm_monitor.h`：100 行。
- `core/monitor/monitor_agent.c`：470 行。
- `commands/cmd_monitor.c`：56 行。
- `core/monitor/openconf.cfg`：44 行。
- `core/monitor/objects.mk`：1 行。

此外，逐行解释启动/构建接入和产品调度器、ARM64 异常、shmem、CCM、内存命令中的 monitor 修改点，
并保留必要上下文。原文件其他与 monitor 无关的实现没有整文件复述。
生产文件内的 `CONFIG_WBOXTEST_MONITOR` 只读辅助接口也逐行解释，避免你阅读文件时遇到未讲的尾部；
本篇不展开 `libs/wboxtest/monitor` 内的各个测试用例或开发机脚本。

基线沿用 2026-10-28 详细设计核对过的最终生产组合：`work/monitor-runtime-storm/tree` 的 monitor 核心、
头文件、命令和上游接入；产品 scheduler 使用 2026-10-22 的新版 history 复用适配；
CCM 使用 `monitor_observer_from_20261023_v4_20261025` 的记录版；产品内存命令使用后续已交付适配。
运行风暴用例初始化/低门限修正不改变本篇所解释的生产核心。

`D:\code\xvisor-master` 有较早安装状态，不能单独代表最终交付组合；本篇也不能证明你未提供的完整
产品树与这里逐字相同。请用函数名、代码片段及末尾 SHA-256 对照。此前偶现的窗口不新鲜和日志截断，
没有在本轮文档任务里被暗中修改。

### 1.1 先建立一条阅读主线

```text
原调度/异常/内存检查
  → vmm_monitor_* 宏
  → vmm_monitor_record：按对象更新静态槽
  → tick → vmm_monitor_sample：约每秒切窗、汇总 fault、判风暴
  → emit：放进16项静态事件环
  → report → vmm_monitor_drain → print_event → vmm_lwarning

monitor start/stop → vmm_monitor_enable
monitor config 键 值 → vmm_monitor_configure
monitor status/events/config → vmm_monitor_dump
```

即时调度/退出打点在原路径上发生；timer 做统计判断；名为 monitor 的工作线程输出日志。
因此“日志线程优先级3”不等于“只能观察优先级≤3的对象”，但关 IRQ、锁竞争和队列拥塞仍影响时效。

### 1.2 阅读顺序

1. 第2章头文件：先看公开编号和宏如何传参。
2. 第3章核心：数据结构 → record → enable/configure → sample → event/log/dump → timer/init。
3. 第4章命令：从终端输入如何到达核心接口。
4. 第5章编译和启动：何时创建执行器，哪些部分可裁剪。
5. 第6章打点接入：数据从哪一行进入 monitor，复用了哪些产品时间点。
6. 第7章对照例子与实际边界；第8章索引与源码身份。

行号是物理源码行号；多条语句写在同一行时，解释会逐项展开。空行、单独括号和条件编译结束也列出，
但不赋予它们不存在的业务行为。纳秒时间来自 `vmm_timer_timestamp()`，不是日历时间。

## 2. vmm_monitor.h：接口、编号与编译边界

源码：[查看参考文件](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/include/vmm_monitor.h>). 本节行号针对该文件，SHA-256 见附录。

<a id="header-1"></a>

### 基础定义、配置键与视图（L1–L16）

```c
L0001: /* SPDX-License-Identifier: GPL-2.0-or-later */
L0002: #ifndef __VMM_MONITOR_H__
L0003: #define __VMM_MONITOR_H__
L0004: #include <vmm_types.h>
L0005: #include <vmm_error.h>
L0006: #define VMM_MONITOR_NS 1000000000ULL
L0007: #define VMM_MONITOR_EVENTS 16
L0008: /* Indexes for the runtime configuration API; values are decimal integers. */
L0009: enum vmm_monitor_config_key {
L0010: 	VMM_MONITOR_EXIT_LIMIT, VMM_MONITOR_SUSTAIN_S,
L0011: 	VMM_MONITOR_WINDOW_MIN_MS, VMM_MONITOR_WINDOW_MAX_MS,
L0012: 	VMM_MONITOR_CONFIG_KEYS
L0013: };
L0014: enum vmm_monitor_view {
L0015: 	VMM_MONITOR_STATUS, VMM_MONITOR_EVENTS_VIEW, VMM_MONITOR_CONFIG_VIEW
L0016: };
```

| 原行号 | 逐行解释 |
|---|---|
| L1 | GPL 许可声明，不影响接口行为。 |
| L2 | 头文件保护开始，只有尚未定义 __VMM_MONITOR_H__ 才处理内容。 |
| L3 | 定义保护宏，防重复包含导致枚举/结构重定义。 |
| L4 | 引入 u32/u64/bool/physical_addr_t 等基础类型。 |
| L5 | 引入 VMM_OK 和 EINVALID/ENOTAVAIL 等错误码。 |
| L6 | 一秒对应 10^9 ns；ULL 保证64位常量，既做换算又作固定采样周期。 |
| L7 | 固定事件环容量16，不是可同时监控的 vCPU 数。 |
| L8 | 配置枚举是数组下标；命令值只接受十进制整数。 |
| L9 | 定义四个运行配置键的编号。 |
| L10 | EXIT_LIMIT=0，SUSTAIN_S=1，分别对应每秒速率和持续秒数。 |
| L11 | WINDOW_MIN_MS=2，WINDOW_MAX_MS=3，分别约束一次实际采样窗口的时长。 |
| L12 | CONFIG_KEYS=4，用于数组长度和遍历终点，不是有效配置键。 |
| L13 | 结束前面的结构、枚举或数组定义；分号完成声明。 |
| L14 | 定义命令查询视图编号。 |
| L15 | STATUS=0，EVENTS_VIEW=1，CONFIG_VIEW=2；用于 dump 分支。 |
| L16 | 结束前面的结构、枚举或数组定义；分号完成声明。 |

<a id="header-17"></a>

### 主体声明、内存 code 和 hook（L17–L31）

```c
L0017: struct vmm_vcpu;
L0018: struct vmm_chardev;
L0019: enum vmm_monitor_fault {
L0020: 	VMM_MONITOR_SHMEM_BOUNDS = 1,
L0021: 	VMM_MONITOR_MAP_REJECT,
L0022: 	VMM_MONITOR_ACCESS_DENIED,
L0023: 	VMM_MONITOR_PERMISSION,
L0024: 	/* Existing CCM failure outcomes; these do not assert a policy violation. */
L0025: 	VMM_MONITOR_CCM_READ_FAILED = 5,
L0026: 	VMM_MONITOR_CCM_REGISTER_FAILED,
L0027: 	VMM_MONITOR_CCM_ELEMENT_REJECTED,
L0028: 	/* Existing mem command address classification/range rejection. */
L0029: 	VMM_MONITOR_HOST_RANGE_REJECT = 8,
L0030: };
L0031: enum vmm_monitor_hook { MON_STATE, MON_SELECTED, MON_DISPATCH, MON_EXIT, MON_FAULT };
```

| 原行号 | 逐行解释 |
|---|---|
| L17 | vCPU 类型前置声明，头文件只使用其指针，避免强制包含完整管理器定义。 |
| L18 | 字符设备类型前置声明，用于定向 shell 输出。 |
| L19 | 定义 type=3 内存事件的 code 值。 |
| L20 | code=1：原共享内存读/写/置值接口的对象范围检查失败。 |
| L21 | code=2：Guest 地址映射请求返回失败；不自动等同于恶意越权。 |
| L22 | code=3：已有访问策略拒绝，例如内存命令禁止修改 Guest 地址。 |
| L23 | code=4：已接入 abort 路径观察到 permission fault。 |
| L24 | 注释强调 CCM 的失败结果记录不能全部归类为策略违规。 |
| L25 | code=5：读取 Guest 中 CCM/sbuf 参数失败或长度不足。 |
| L26 | code=6：现有 CCM/sbuf 注册流程返回失败。 |
| L27 | code=7：sbuf_put 的元素长度不满足原有条件，被拒绝。 |
| L28 | 下面记录产品内存命令自己的地址分类/范围拒绝结果。 |
| L29 | code=8：host 内存命令范围/分类失败，不表示捕获了所有 EL2 指针越界。 |
| L30 | 结束前面的结构、枚举或数组定义；分号完成声明。 |
| L31 | hook 内部编号0..4：状态、选中、dispatch、exit、内存基值。内存真正 hook=MON_FAULT+code。 |

<a id="header-32"></a>

### 生产 API、包装宏与关闭时空桩（L32–L61）

```c
L0032: #ifdef CONFIG_CMD_MONITOR
L0033: int vmm_monitor_cmd_init(void);
L0034: #else
L0035: static inline int vmm_monitor_cmd_init(void) { return VMM_OK; }
L0036: #endif
L0037: static inline bool vmm_monitor_range_valid(u64 size, u64 offset, u64 length)
L0038: {
L0039: 	return offset <= size && length <= size - offset;
L0040: }
L0041: #ifdef CONFIG_MONITOR_AGENT
L0042: int vmm_monitor_init(void);
L0043: int vmm_monitor_enable(bool on);
L0044: void vmm_monitor_record(struct vmm_vcpu *, u32 hook, u64 a, u64 b);
L0045: void vmm_monitor_sample(u64 now);
L0046: void vmm_monitor_drain(void);
L0047: int vmm_monitor_dump(struct vmm_chardev *, u32 view);
L0048: int vmm_monitor_configure(u32 key, u32 value);
L0049: #define vmm_monitor_state(v,s,t) vmm_monitor_record(v, MON_STATE, s, t)
L0050: #define vmm_monitor_selected(v,t) vmm_monitor_record(v, MON_SELECTED, t, 0)
L0051: #define vmm_monitor_dispatch(v,a,b) vmm_monitor_record(v, MON_DISPATCH, a, b)
L0052: #define vmm_monitor_exit(v,r) vmm_monitor_record(v, MON_EXIT, r, 0)
L0053: #define vmm_monitor_mem_fault(v,k,a,d) vmm_monitor_record(v, MON_FAULT + (k), a, d)
L0054: #else
L0055: static inline int vmm_monitor_init(void) { return VMM_OK; }
L0056: #define vmm_monitor_state(...) do { } while (0)
L0057: #define vmm_monitor_selected(...) do { } while (0)
L0058: #define vmm_monitor_dispatch(...) do { } while (0)
L0059: #define vmm_monitor_exit(...) do { } while (0)
L0060: #define vmm_monitor_mem_fault(...) do { } while (0)
L0061: #endif
```

| 原行号 | 逐行解释 |
|---|---|
| L32 | 编译 monitor 命令时声明真实命令初始化函数。 |
| L33 | 由 cmd_monitor.c 提供该实现，启动流程负责调用。 |
| L34 | 未编译命令时选择空桩。 |
| L35 | 空桩直接成功，使公共启动路径不用再写一层条件编译；不注册任何命令。 |
| L36 | 结束条件编译：`#ifdef CONFIG_CMD_MONITOR`。 |
| L37 | 一个与功能开关无关的范围判断纯函数；size是对象大小，offset是偏移，length是请求长度。 |
| L38 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L39 | 先检查 offset<=size，再比较 length<=size-offset，短路且避免 offset+length 回绕。该 helper 存在不代表所有旧 shmem 判断已经换用它。 |
| L40 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L41 | 核心开关开启时，暴露真实运行接口和打点宏。 |
| L42 | 模块初始化，预期启动时调用一次。 |
| L43 | 开启/关闭普通采集；不是清除历史命令。 |
| L44 | 通用记录入口；不同 hook 的 a/b 语义见下方包装宏。 |
| L45 | 周期采样入口，调用者负责提供纳秒时间和单一串行执行环境。 |
| L46 | 日志排出入口，应在可执行日志输出的工作线程中串行调用。 |
| L47 | 查询指定视图，输出到调用者的字符设备。 |
| L48 | 修改一项配置，具体范围在核心 configure 的 bounds 表中。 |
| L49 | 状态宏将 s 放进 a、时间戳 t 放进 b；每个参数在展开式中只出现一次。 |
| L50 | 选中宏把选中时间放进 a，b=0。 |
| L51 | dispatch 宏把开始/结束时间分别传到 a/b。 |
| L52 | exit 宏把原因 r 放进 a，b=0；不传 PC 或退出耗时。 |
| L53 | 内存宏以 MON_FAULT+k 区别类别，a 为地址/偏移，d 为长度/错误码/组合细节。 |
| L54 | 编译关闭核心时选择空实现。 |
| L55 | init 空桩返回成功，不创建队列/定时器。 |
| L56 | 状态打点为空宏；可变参数完全不求值，传入时间戳函数不会因宏本身而执行。 |
| L57 | 选中打点为空宏，同样不计算参数表达式。 |
| L58 | dispatch 为空宏；调用者本来就有的 t1/t2/history 统计是否保留由调用者自己的代码决定。 |
| L59 | exit 为空宏，不增加计数。 |
| L60 | 内存记录为空宏，不改变原拒绝分支返回值。关闭时没有给 enable/dump/configure 定义空桩，直接调用者须受编译依赖约束。 |
| L61 | 结束条件编译：`#ifdef CONFIG_MONITOR_AGENT`。 |

<a id="header-62"></a>

### 嵌入头文件的只读测试观察接口（L62–L100）

```c
L0062: 
L0063: #ifdef CONFIG_WBOXTEST_MONITOR
L0064: /* White-box test interfaces; omitted from production builds. */
L0065: /* Test-only read access. No reset, injection, sampler or drain entry points. */
L0066: struct vmm_monitor_test_latency { u64 count, sum, max; };
L0067: struct vmm_monitor_test_state {
L0068: 	u32 epoch, enabled, config_seq, config[VMM_MONITOR_CONFIG_KEYS];
L0069: 	u32 skipped, errors;
L0070: 	u64 head, lost;
L0071: };
L0072: struct vmm_monitor_test_slot {
L0073: 	u32 epoch, guest, kind, config_seq;
L0074: 	bool present, waiting, valid, active;
L0075: 	u64 ready_since, previous, interval, exits;
L0076: 	struct vmm_monitor_test_latency ready, dispatch;
L0077: };
L0078: struct vmm_monitor_test_event {
L0079: 	u64 seq, time_ns, last_ns, value, address, detail;
L0080: 	u32 type, guest, vcpu, epoch, code, config_seq, sustain_s;
L0081: 	bool log_returned;
L0082: 	u32 log_calls;
L0083: };
L0084: int vmm_monitor_test_sample_serial(u64 *out);
L0085: /* Successful memory-flush passes for one actor; ~0U selects NULL/shmem.
L0086:  * Monotonic across start/stop and slot resets; the caller checks epoch too. */
L0087: int vmm_monitor_test_sample_actor(u32 actor, u64 *out);
L0088: int vmm_monitor_test_state(struct vmm_monitor_test_state *out);
L0089: int vmm_monitor_test_slot(u32 id, struct vmm_monitor_test_slot *out);
L0090: int vmm_monitor_test_event(u64 seq, struct vmm_monitor_test_event *out);
L0091: 
L0092: enum vmm_monitor_host_kind {
L0093:     VMM_MONITOR_HOST_RAM, VMM_MONITOR_HOST_DEVICE, VMM_MONITOR_HOST_GUEST
L0094: };
L0095: /* These adapters run existing cmd_memory checks only; they never access PA. */
L0096: int vmm_monitor_host_probe(physical_addr_t addr, u32 width, u32 *kind);
L0097: int vmm_monitor_host_guard(struct vmm_chardev *out, physical_addr_t addr,
L0098:                            u32 width, bool write);
L0099: #endif /* CONFIG_WBOXTEST_MONITOR */
L0100: #endif
```

| 原行号 | 逐行解释 |
|---|---|
| L62 | 空行，分隔声明/逻辑段，不产生指令。 |
| L63 | 只有一个 WBOXTEST_MONITOR 开关控制下方测试观察接口。 |
| L64 | 注释说明这些额外类型/入口在普通生产构建中省略。 |
| L65 | 测试观察接口提供读取，不提供重置、注入、强制采样或强制 drain；常规生产接口声明仍在上方。 |
| L66 | 对外测试延迟结构保留原始 count/sum/max，测试可核对累计逻辑。 |
| L67 | 模块全局测试快照结构。 |
| L68 | epoch、enabled原始代号、配置版本及四个配置值。 |
| L69 | 全局 skipped/errors 计数，不属于某个目标槽。 |
| L70 | head 为累计发布序号，lost 为未消费事件覆盖数。 |
| L71 | 结束前面的结构、枚举或数组定义；分号完成声明。 |
| L72 | 一个普通 vCPU 统计槽的测试快照结构。 |
| L73 | 身份与已采纳的配置版本。 |
| L74 | 存在/等待/窗口有效/风暴激活四个标记。 |
| L75 | READY起点、采样边界、窗口长度、最近窗口退出数，单位见字段名/核心赋值。 |
| L76 | 两组累计延迟的测试副本。 |
| L77 | 结束前面的结构、枚举或数组定义；分号完成声明。 |
| L78 | 对外测试事件结构，加了日志调用回执字段。 |
| L79 | 六个64位事件字段，与核心 event 对应但时间名明确带 ns。 |
| L80 | 类别与配置证据的32位字段。 |
| L81 | log_returned 表示该 seq 的日志函数调用返回，不是存储 flush 成功。 |
| L82 | log_calls 用于检测同一 seq 是否调用日志多次。 |
| L83 | 结束前面的结构、枚举或数组定义；分号完成声明。 |
| L84 | 读取全局完整扫描进度。 |
| L85 | 逐 actor 的成功 flush 进度查询，~0U 指匿名/shmem 槽。 |
| L86 | 此进度不随 start/stop/data reset 清零，使用者须同时核对 epoch，不能只看计数增量。 |
| L87 | 获取指定 actor 进度。 |
| L88 | 获取全局状态快照。 |
| L89 | 获取指定普通槽快照。 |
| L90 | 获取仍在环中的指定 seq 事件及回执。 |
| L91 | 空行，分隔声明/逻辑段，不产生指令。 |
| L92 | host 内存测试适配器的地址分类枚举。 |
| L93 | RAM=0、DEVICE=1、GUEST=2；这里只标已有检查得出的地址类别。 |
| L94 | 结束前面的结构、枚举或数组定义；分号完成声明。 |
| L95 | 注释说明下面两个适配器只调用已有策略检查，不直接对物理地址进行读写。 |
| L96 | probe 输出地址类别；定义在产品 cmd_memory.c，不在 monitor_agent.c。 |
| L97 | guard 接受输出设备和待检查物理地址。 |
| L98 | width 是访问宽度，write 选择写策略或读策略；它不是实际写数据函数。 |
| L99 | 结束白盒测试接口条件编译。 |
| L100 | 结束整个头文件保护。 |

## 3. monitor_agent.c：完整核心实现

源码：[查看参考文件](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c>). 本节行号针对该文件，SHA-256 见附录。

<a id="core-1"></a>

### 依赖和格式化宏（L1–L16）

```c
L0001: /* SPDX-License-Identifier: GPL-2.0-or-later */
L0002: #include <vmm_monitor.h>
L0003: #include <vmm_manager.h>
L0004: #include <vmm_scheduler.h>
L0005: #include <vmm_timer.h>
L0006: #include <vmm_smp.h>
L0007: #include <vmm_stdio.h>
L0008: #include <vmm_modules.h>
L0009: #include <arch_barrier.h>
L0010: #include <libs/stringlib.h>
L0011: #include <libs/mathlib.h>
L0012: #ifndef CONFIG_MONITOR_EXTERNAL_EXECUTOR
L0013: #include <vmm_threads.h>
L0014: #include <vmm_workqueue.h>
L0015: #endif
L0016: #define U(x) ((unsigned long long)(x))
```

| 原行号 | 逐行解释 |
|---|---|
| L1 | 标明 GPL-2.0-or-later 许可证；不参与运行。 |
| L2 | 引入 monitor 的常量、枚举、接口和打点宏，后面的 hook/config/view 编号均来自该头文件。 |
| L3 | 引入 vCPU/Guest 数据结构，供读取 id、is_normal、guest 等成员及状态常量。 |
| L4 | 引入调度器接口，主要用无锁的 idle 对象查询识别 idle 槽。 |
| L5 | 引入纳秒时间戳、定时器对象和启动接口。 |
| L6 | 引入当前物理 CPU 编号及相关 CPU 接口。 |
| L7 | 引入 JSON 格式化、命令输出和 vmm_lwarning 日志接口。 |
| L8 | 引入 __init 等模块相关定义和 VMM_EXPORT_SYMBOL 符号导出机制。 |
| L9 | 引入 arch_wmb 写屏障，初始化完成发布前使用。 |
| L10 | 引入 memset、memcpy 等操作静态对象和快照的函数。 |
| L11 | 引入 udiv64，避免把 64 位纳秒/计数除法写成平台不支持的形式。 |
| L12 | 只有未选择外部执行器时，才编译内部线程/工作队列依赖。 |
| L13 | 内部模式需要设置日志工作线程亲和性；不是为每个监控 vCPU 创建线程。 |
| L14 | 内部模式使用工作队列提交日志任务，避免在采样定时器里打印。 |
| L15 | 结束条件编译：`#ifndef CONFIG_MONITOR_EXTERNAL_EXECUTOR`。 |
| L16 | 将参数转成 unsigned long long，与 %llu 匹配；它不改变 ns/s 单位。 |

<a id="core-17"></a>

### 四类数据结构（L17–L30）

理解 exits/count、epoch/config_seq 两组区别，是读懂后面代码的关键。

```c
L0017: struct latency { u64 count, sum, max; };
L0018: struct event {
L0019: 	u64 seq, time, last, value, address, detail;
L0020: 	u32 type, guest, vcpu, epoch, code, config_seq, sustain_s;
L0021: };
L0022: enum object_kind { OBJECT_GUEST, OBJECT_HOST, OBJECT_IDLE };
L0023: struct data {
L0024: 	struct latency ready, dispatch;
L0025: 	u64 ready_since, previous, exits, interval, count, sustained;
L0026: 	u32 epoch, guest, last_exit, windows, config_seq, kind;
L0027: 	bool present, waiting, active, valid;
L0028: 	struct event memory;
L0029: };
L0030: struct slot { vmm_spinlock_t lock; struct data d; };
```

| 原行号 | 逐行解释 |
|---|---|
| L17 | 一组延迟统计：count 是已完成样本次数，sum 是纳秒总和，max 是最大单次纳秒值。没有分位数桶或 P99。 |
| L18 | 定义一条发布到事件环中的内部事件结构。 |
| L19 | seq 为事件序号；time/last 为首次/最近时间；value 为事件数值；address/detail 的单位与意义由 type/code 决定。 |
| L20 | type 是事件大类；guest/vcpu 是主体；epoch 是启停代号；code 是子类/最后退出原因；config_seq/sustain_s 主要给风暴保存判定配置。 |
| L21 | 结束前面的结构、枚举或数组定义；分号完成声明。 |
| L22 | kind 的内部编号依次是 guest=0、host=1、idle=2；它和 vCPU 的调度 State 不是同一枚举。 |
| L23 | 定义一个调度对象的全部监控数据；不是 vmm_vcpu 本体，也不修改调度策略。 |
| L24 | 分别保存 READY 等待和 dispatch 路径耗时的累计统计；采样时不会每秒清零这两组数据。 |
| L25 | ready_since 为本次 READY 起点；previous 为采样边界；exits 为正在积累的退出数；interval 为上个窗口时长；count 为上个窗口退出数；sustained 为连续高窗口累计 ns。 |
| L26 | epoch 识别采集轮次；guest 是归属；last_exit 是最近退出原因；windows 是连续高窗口数；config_seq 是该槽已采用的配置版本；kind 是对象类别。 |
| L27 | present 表示槽可展示；waiting 表示尚未结束的 READY 等待；active 表示此轮风暴已告警；valid 仅表示最近采样窗口长度合规。 |
| L28 | 每槽只有一份待发布内存摘要，不是每个 fault 一条独立队列；不同 code 可合并到同一摘要中。 |
| L29 | 结束前面的结构、枚举或数组定义；分号完成声明。 |
| L30 | 把锁和 data 放在一个 slot 中；同一对象的数据由同一把锁保护，不同对象可独立更新。 |

<a id="core-31"></a>

### 静态存储、配置和执行器对象（L31–L55）

```c
L0031: static struct slot slots[CONFIG_MAX_VCPU_COUNT + 1];
L0032: static DEFINE_SPINLOCK(event_lock);
L0033: static struct event ring[VMM_MONITOR_EVENTS];
L0034: #ifdef CONFIG_WBOXTEST_MONITOR
L0035: /* Receipt means the logging call returned, not that storage was flushed. */
L0036: static u64 test_logged[VMM_MONITOR_EVENTS];
L0037: static u32 test_log_calls[VMM_MONITOR_EVENTS];
L0038: static u64 test_sample_serial;
L0039: /* Each counter is protected by the corresponding slot lock. Test builds only. */
L0040: static u64 test_sample_actor[CONFIG_MAX_VCPU_COUNT + 1];
L0041: #endif
L0042: static u64 head, cursor = 1, lost;
L0043: static u32 epoch, sampler_cpu;
L0044: /* Protected by event_lock. Copy the entire configuration before taking slots. */
L0045: static struct monitor_config {
L0046: 	u32 value[VMM_MONITOR_CONFIG_KEYS], seq;
L0047: } config = {{CONFIG_MONITOR_EXIT_RATE, CONFIG_MONITOR_STORM_SECONDS, 750, 1250}, 1};
L0048: static atomic_t enabled = {0}, initialized = {0}, skipped = {0}, errors = {0};
L0049: #ifndef CONFIG_MONITOR_EXTERNAL_EXECUTOR
L0050: static struct vmm_workqueue *queue;
L0051: static struct vmm_work work;
L0052: static struct vmm_timer_event timer;
L0053: static u64 deadline;
L0054: #endif
L0055: /* Lock order: slot -> event. No reader holds event_lock while taking a slot. */
```

| 原行号 | 逐行解释 |
|---|---|
| L31 | 静态分配普通 vCPU ID 槽外再加一个槽；最后一个专门接收 v==NULL 的无主体内存记录。 |
| L32 | 全局事件锁保护事件环、head/cursor/lost、epoch 更新和配置；它与每槽的锁分工不同。 |
| L33 | 静态事件环，容量来自 VMM_MONITOR_EVENTS=16；不为每条告警动态分配内存。 |
| L34 | 下方额外计数器只在白盒测试开关打开时存在。 |
| L35 | 日志回执只证明调用日志函数已经返回，不证明文件或存储介质完成刷盘。 |
| L36 | 每个环下标记录最近完成日志调用的完整事件 seq，防止环下标复用后误认回执。 |
| L37 | 记录同一个完整 seq 的日志调用次数，用于检查重复打印。 |
| L38 | 记录 sample 执行完整一轮的次数，不表示每个槽都成功采样。 |
| L39 | 逐主体进度由对应 slot 锁保护，且仅用于测试构建。 |
| L40 | 每个普通主体及匿名槽各有一个成功进入 flush 阶段的计数器；与 data 分开，重置 data 不会清掉它。 |
| L41 | 结束条件编译：`#ifdef CONFIG_WBOXTEST_MONITOR`。 |
| L42 | head 从 0 开始计已发布事件；cursor 从 1 开始指向下一条待日志消费的序号；lost 记录尚未消费就被覆盖的事件数。 |
| L43 | epoch 初始 0，每次从关闭到开启递增；sampler_cpu 在初始化时记录所在物理核。 |
| L44 | 配置先在 event_lock 下复制，释放后才拿 slot 锁；避免 event→slot 的反向嵌套。 |
| L45 | 定义唯一的静态配置对象 config。 |
| L46 | value 的四个元素按配置枚举排列；seq 是配置实际发生变化的版本号，不是事件序号。 |
| L47 | 默认依次为编译门限、编译持续秒数、750 ms、1250 ms；配置版本从 1 开始。 |
| L48 | enabled 存 0 或当前非零 epoch，并非简单布尔；initialized 为就绪标志；skipped 是采样抢锁失败次数；errors 是执行器错误计数。 |
| L49 | 以下内部执行器对象在外部模式下完全不编译。 |
| L50 | 指向初始化时创建的日志工作队列；创建过程可分配内存，采集热路径不因此动态分配。 |
| L51 | 一个可复用的日志任务对象，后续每次 tick 提交同一任务。 |
| L52 | 一个可复用的定时器事件对象，回调为 tick。 |
| L53 | 保存按 1 秒网格推进的下次绝对 deadline，避免简单“处理完再等 1 秒”积累漂移。 |
| L54 | 结束条件编译：`#ifndef CONFIG_MONITOR_EXTERNAL_EXECUTOR`。 |
| L55 | 锁顺序约定为 slot→event；事件查询必须先释放 event_lock，才允许获取 slot 锁。 |

<a id="core-56"></a>

### emit：发布事件与处理覆盖（L56–L70）

调用时可已持有一个 slot 锁，所以只允许继续拿 event_lock，不能反向拿另一个 slot。

```c
L0056: static bool emit(struct event *e)
L0057: {
L0058: 	irq_flags_t f;
L0059: 	vmm_spin_lock_irqsave_lite(&event_lock, f);
L0060: 	/* A concurrently published configuration invalidates an in-flight verdict. */
L0061: 	if (e->type == 1 && e->config_seq != config.seq) {
L0062: 		vmm_spin_unlock_irqrestore_lite(&event_lock, f);
L0063: 		return FALSE;
L0064: 	}
L0065: 	e->seq = ++head;
L0066: 	if (head - cursor >= VMM_MONITOR_EVENTS) { cursor++; lost++; }
L0067: 	ring[(head - 1) % VMM_MONITOR_EVENTS] = *e;
L0068: 	vmm_spin_unlock_irqrestore_lite(&event_lock, f);
L0069: 	return TRUE;
L0070: }
```

| 原行号 | 逐行解释 |
|---|---|
| L56 | emit 将完整事件发布到环中；返回是否接受，不负责格式化或落盘。 |
| L57 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L58 | 保存调用前的本地 IRQ 状态，结束时恢复，而不是无条件开中断。 |
| L59 | 关本地 IRQ 并获取 event_lock；防本核中断重入和其他核同时改环。 |
| L60 | 注释解释下面的并发配置版本检查：旧配置下算出的风暴不能冒充新配置告警。 |
| L61 | 只对 type=1 风暴检查配置版本；若采样快照已过期，进入拒绝分支。内存摘要不走此检查。 |
| L62 | 拒绝前必须先解锁并恢复 IRQ 状态。 |
| L63 | 返回 FALSE，使调用者不要把该风暴标成 active；以后按新配置重新判定。 |
| L64 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L65 | 先递增 head，再给事件赋 seq；第一条序号是 1。没有处理 u64 序号耗尽的专门逻辑。 |
| L66 | 新事件超过未消费容量时丢掉最老待消费项：推进 cursor 并增加 lost。已经打过日志的历史被覆盖不增加 lost。 |
| L67 | 把序号映射到 0..15 的环下标，并复制整条事件；调用者随后可继续复用自己的结构。 |
| L68 | 发布完成后释放事件锁并恢复 IRQ。 |
| L69 | 返回 TRUE，表示已进入事件环；尚不能据此声称日志已落盘。 |
| L70 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="core-71"></a>

### memory_flush 与 add：两个小型统计工具（L71–L79）

```c
L0071: static __attribute__((noinline)) void memory_flush(struct data *d)
L0072: {
L0073: 	if (d->memory.value) { emit(&d->memory); d->memory.value = 0; }
L0074: }
L0075: static void add(struct latency *s, u64 ns)
L0076: {
L0077: 	s->count++; s->sum += ns;
L0078: 	if (ns > s->max) s->max = ns;
L0079: }
```

| 原行号 | 逐行解释 |
|---|---|
| L71 | memory_flush 把单槽待发布内存摘要送入环；noinline 限制编译器内联，不代表异步执行。 |
| L72 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L73 | value 非零才发布；发布后只清待计数 value，其余字段留待下次记录覆盖。type=3 不会被 emit 的配置版本检查拒绝。 |
| L74 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L75 | add 接收一条已计算好的耗时 ns，更新指定 latency 对象；由外层 slot 锁保证互斥。 |
| L76 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L77 | 每个完成样本使 count 加一、sum 加 ns；这里没有饱和计数或溢出保护。 |
| L78 | 仅当新样本更大时更新 max，因此输出最大值是当前槽 epoch/reset 生命周期内的累计最大值。 |
| L79 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="core-80"></a>

### record 前半段：过滤主体和更新生命周期（L80–L115）

```c
L0080: /* Scheduler hooks cover both normal and orphan vCPUs. Exit hooks remain
L0081:  * Guest-only. NULL identifies a host shmem bounds failure without an actor. */
L0082: void vmm_monitor_record(struct vmm_vcpu *v, u32 hook, u64 a, u64 b)
L0083: {
L0084: 	struct slot *s;
L0085: 	struct data *d;
L0086: 	irq_flags_t f;
L0087: 	u32 run;
L0088: 	bool reset = hook == MON_STATE &&
L0089: 		(a == VMM_VCPU_STATE_RESET || a == VMM_VCPU_STATE_UNKNOWN);
L0090: 	if (!arch_atomic_read(&initialized) ||
L0091: 	    (!arch_atomic_read(&enabled) && !reset) ||
L0092: 	    (v && (v->id >= CONFIG_MAX_VCPU_COUNT || (v->is_normal && !v->guest))) ||
L0093: 	    (hook == MON_EXIT && (!v || !v->is_normal)) ||
L0094: 	    (!v && hook <= MON_FAULT)) return;
L0095: 	s = &slots[v ? v->id : CONFIG_MAX_VCPU_COUNT]; d = &s->d;
L0096: 	vmm_spin_lock_irqsave_lite(&s->lock, f);
L0097: 	run = arch_atomic_read(&enabled);
L0098: 	if (!run && !reset) goto done;
L0099: 	if (reset || d->epoch != run) {
L0100: 		memory_flush(d);
L0101: 		memset(d, 0, sizeof(*d));
L0102: 		d->epoch = run;
L0103: 		d->previous = vmm_timer_timestamp();
L0104: 	}
L0105: 	d->present = !(reset && a == VMM_VCPU_STATE_UNKNOWN);
L0106: 	d->guest = v && v->is_normal ? v->guest->id : ~0U;
L0107: 	if (v && v->is_normal) d->kind = OBJECT_GUEST;
L0108: 	else {
L0109: 		/* The idle pointer is installed after orphan creation. Recognize it
L0110: 		 * on a local hook; retain that identity across remote state changes.
L0111: 		 * This getter takes no scheduler lock (the caller may hold it). */
L0112: 		if (d->kind != OBJECT_IDLE) d->kind = OBJECT_HOST;
L0113: 		if (v && v == vmm_scheduler_idle_vcpu(vmm_smp_processor_id()))
L0114: 			d->kind = OBJECT_IDLE;
L0115: 	}
```

| 原行号 | 逐行解释 |
|---|---|
| L80 | 注释说明调度打点覆盖 normal 与 orphan vCPU，不限于 Guest。 |
| L81 | 退出打点仍只统计 Guest；无明确调用者的 shmem fault 以 NULL 进入匿名槽。 |
| L82 | 所有打点的统一入口；v 指主体，hook 决定 a/b 的解释，不是所有调用都把 a/b 当时间戳。 |
| L83 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L84 | s 指向本次要更新的静态槽。 |
| L85 | d 指向该槽内部 data，避免反复展开 s->d。 |
| L86 | 保存该槽加锁时的 IRQ 状态。 |
| L87 | run 用来保存加锁后读到的启用 epoch。 |
| L88 | 只有状态打点才可能作为生命周期 reset；内存/退出编号不能触发此规则。 |
| L89 | RESET 和 UNKNOWN 两种状态需清理旧监控生命周期；即使 stop 后也允许这类清理。 |
| L90 | 初始化未成功时直接拒绝所有打点，避免触碰未准备好的锁/执行器。 |
| L91 | 关闭时普通打点被跳过，但 reset/UNKNOWN 清理仍可进入。 |
| L92 | 拒绝超出静态槽范围的 ID；normal vCPU 没有 guest 指针也拒绝，防空指针和错误归属。 |
| L93 | MON_EXIT 只允许非 NULL 的 normal vCPU；host/idle 不产生 Guest exit 流。 |
| L94 | 无主体时只允许大于 MON_FAULT 的内存 hook；空指针的调度/退出/裸 MON_FAULT 被拒绝。 |
| L95 | 有主体按 v->id 取槽，否则取额外匿名槽；d 是同一槽的数据地址。 |
| L96 | 获取该槽的 IRQ-safe 锁；调用位置可能已处于调度或异常上下文，不能换成睡眠锁。 |
| L97 | 锁内再次读 enabled，避免仅依赖加锁前已经过时的状态。 |
| L98 | 如果等锁期间被 stop，普通记录走 done 解锁返回；reset 例外继续处理。 |
| L99 | 对象 reset 或槽属于旧 epoch 时，惰性清空这个槽；不是 start 时同时锁住所有对象。 |
| L100 | 先发布旧槽尚未提交的内存摘要，防清空时丢掉已经记录的故障。 |
| L101 | 清空累计延迟、等待标记、风暴状态和内存摘要等整个 data；锁本身不在 data 内，不被清掉。 |
| L102 | 把槽绑定到锁内读到的 run；停止时处理 reset 可把槽 epoch 设为 0。 |
| L103 | 新统计生命周期的初始采样边界取当前时间，因此首个窗口可能不足一秒、valid 为 0。 |
| L104 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L105 | UNKNOWN 使 present 为假；RESET 不必隐藏槽。present 不能等同于 Guest 当前正在运行。 |
| L106 | normal 对象记录其 Guest ID；host/idle/匿名主体用 ~0U，即 4294967295，表示不适用。 |
| L107 | normal 对象直接归类为 Guest，不用名称字符串猜测。 |
| L108 | 非 normal 对象进入 host/idle 分类路径，NULL 匿名槽也走这里。 |
| L109 | idle 指针可能在 orphan 对象创建之后才安装，创建时未必能立即识别。 |
| L110 | 本核后续打点识别成 idle 后，即使远端状态更新也保留该身份。 |
| L111 | 此查询不额外拿调度器锁，避免与调用者已持有的调度锁冲突；锁属性依据参考 getter 实现。 |
| L112 | 已经是 idle 则保留；否则先默认归入 host。 |
| L113 | 只比较当前物理核的 idle 指针和本次 v；不是扫描所有核，也不是按优先级识别 idle。 |
| L114 | 指针命中后将 kind 改为 idle。 |
| L115 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="core-116"></a>

### record 后半段：状态、延迟、exit 与内存摘要（L116–L146）

```c
L0116: 	switch (hook) {
L0117: 	case MON_STATE:
L0118: 		if (a == VMM_VCPU_STATE_READY) {
L0119: 			if (!d->waiting) d->ready_since = b;
L0120: 			d->waiting = TRUE;
L0121: 		} else d->waiting = FALSE;
L0122: 		break;
L0123: 	case MON_SELECTED:
L0124: 		if (d->waiting && a >= d->ready_since) add(&d->ready, a - d->ready_since);
L0125: 		d->waiting = FALSE;
L0126: 		break;
L0127: 	case MON_DISPATCH:
L0128: 		if (b >= a) add(&d->dispatch, b - a);
L0129: 		break;
L0130: 	case MON_EXIT:
L0131: 		d->exits++; d->last_exit = a;
L0132: 		break;
L0133: 	default:
L0134: 		d->memory.last = vmm_timer_timestamp();
L0135: 		if (!d->memory.value) d->memory.time = d->memory.last;
L0136: 		d->memory.value++;
L0137: 		d->memory.type = 3;
L0138: 		d->memory.guest = d->guest;
L0139: 		d->memory.vcpu = v ? v->id : ~0U;
L0140: 		d->memory.epoch = run;
L0141: 		d->memory.code = hook - MON_FAULT;
L0142: 		d->memory.address = a; d->memory.detail = b;
L0143: 	}
L0144: done:
L0145: 	vmm_spin_unlock_irqrestore_lite(&s->lock, f);
L0146: }
```

| 原行号 | 逐行解释 |
|---|---|
| L116 | 根据 hook 分配 a/b 语义；各分支在同一 slot 锁内完成。 |
| L117 | 状态变化分支：a 是新状态，b 是调度器提供的状态时间戳。 |
| L118 | 只有 READY 状态开启/延续就绪等待。 |
| L119 | 首次进入等待时保存 b；重复 READY 不覆盖起点，避免缩短本次真实等待。 |
| L120 | 标记当前存在未结束的 READY 区间。 |
| L121 | 非 READY 状态清等待标记；不自动把它记为成功选中样本。 |
| L122 | 结束 MON_STATE 分支，不继续执行 SELECTED 等分支。 |
| L123 | 选中分支：a 是调度器选中该对象的时间。 |
| L124 | 只有确实在等且时间未倒退才累计 a-ready_since；缺少 READY 起点不会伪造样本。 |
| L125 | 无论本次是否可计数，选中后都关闭等待区间，防重复 selected 二次统计。 |
| L126 | 结束 SELECTED 分支。 |
| L127 | dispatch 分支：a/b 分别为调度路径起止时间。 |
| L128 | b>=a 时累计 b-a；负向时间序列被跳过。这个值不是 Guest 从选中到第一条指令的完整恢复延迟。 |
| L129 | 结束 DISPATCH 分支。 |
| L130 | 退出分支：a 是 exit 原因编号。 |
| L131 | 正在积累的退出计数加一；更新 last_exit。这里只存最近原因，不保存每种原因的直方图。 |
| L132 | 结束 EXIT 分支。 |
| L133 | 其余 hook 按内存事件解释；接口假定调用者使用合法宏，未对任意未知 hook 做完整白名单检查。 |
| L134 | 内存摘要最近发生时间取记录入口的当前纳秒时间，不是采样时刻。 |
| L135 | 本批第一条 fault 同时设首次时间；后续只更新 last。 |
| L136 | 当前槽、本批内存记录数量加一，不论各条 code/address 是否相同。 |
| L137 | 固定事件 type=3，表示内存类摘要。 |
| L138 | 摘要归属继承槽 guest；NULL/host 为不适用值。 |
| L139 | 保存实际 vCPU ID；NULL 事件用 ~0U，而不是额外数组槽的下标作为外部 ID。 |
| L140 | 保存记录发生时的 run，以便与启停生命周期关联。 |
| L141 | 内存宏传入 MON_FAULT+k，这里减去基值恢复对外 code=k。 |
| L142 | 覆盖为本批最后一条 fault 的地址与 detail；因此 value>1 时不能据此还原每条故障。 |
| L143 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L144 | 统一退出标签，锁内的早退都经过这里。 |
| L145 | 释放 slot 锁并恢复进入此锁前的 IRQ 状态；不在此打印日志。 |
| L146 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="core-147"></a>

### enable：start/stop 为什么不等于清空历史（L147–L160）

```c
L0147: int vmm_monitor_enable(bool on)
L0148: {
L0149: 	irq_flags_t f;
L0150: 	if (!arch_atomic_read(&initialized)) return VMM_ENOTAVAIL;
L0151: 	vmm_spin_lock_irqsave_lite(&event_lock, f);
L0152: 	if (!on) arch_atomic_write(&enabled, 0);
L0153: 	else if (!arch_atomic_read(&enabled)) {
L0154: 		/* Lazy epoch reset avoids locking all vCPUs with IRQs disabled. */
L0155: 		if (!++epoch) ++epoch;
L0156: 		arch_atomic_write(&enabled, epoch);
L0157: 	}
L0158: 	vmm_spin_unlock_irqrestore_lite(&event_lock, f);
L0159: 	return VMM_OK;
L0160: }
```

| 原行号 | 逐行解释 |
|---|---|
| L147 | 运行时开关接口；on=true 开启，false 停止新普通记录。 |
| L148 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L149 | 保存开关操作的 IRQ 状态。 |
| L150 | 未初始化成功不能 start/stop，返回 ENOTAVAIL。 |
| L151 | 序列化 epoch 和 enabled 的控制变化，与配置/事件共用全局锁。 |
| L152 | stop 只把 enabled 写 0；没有清环、清槽、销毁队列或停止 timer。 |
| L153 | 已开启时再次 start 不进入此分支，因此不增加 epoch，也不重置现有统计。 |
| L154 | 注释说明选择按槽惰性切代，以缩短控制命令的关 IRQ 区间。 |
| L155 | 新 epoch 自增；32 位回绕到 0 时再跳过 0，使 0 专门表示关闭。长时间回绕不提供全局唯一 boot ID。 |
| L156 | enabled 写入非零 epoch，记录入口据此识别新采集轮次。 |
| L157 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L158 | 释放控制锁；不等待其他 CPU 上已进入的打点/采样全部退出，因此不是全局同步屏障。 |
| L159 | 返回控制修改成功；不证明已经产生了新的一秒采样窗口。 |
| L160 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="core-161"></a>

### configure：范围检查与配置版本（L161–L179）

```c
L0161: /* Preserve an active episode across configuration changes. A valid low-rate
L0162:  * window rearms it; neither a query nor changing limits repeats its alert. */
L0163: int vmm_monitor_configure(u32 key, u32 value)
L0164: {
L0165: 	static const u32 bounds[VMM_MONITOR_CONFIG_KEYS][2] = {
L0166: 		{1, 1000000000}, {1, 60}, {1, 1000}, {1000, 10000}
L0167: 	};
L0168: 	irq_flags_t f;
L0169: 	if (!arch_atomic_read(&initialized)) return VMM_ENOTAVAIL;
L0170: 	if (key >= VMM_MONITOR_CONFIG_KEYS ||
L0171: 		value < bounds[key][0] || value > bounds[key][1]) return VMM_EINVALID;
L0172: 	vmm_spin_lock_irqsave_lite(&event_lock, f);
L0173: 	if (config.value[key] != value) {
L0174: 		config.value[key] = value;
L0175: 		if (!++config.seq) ++config.seq;
L0176: 	}
L0177: 	vmm_spin_unlock_irqrestore_lite(&event_lock, f);
L0178: 	return VMM_OK;
L0179: }
```

| 原行号 | 逐行解释 |
|---|---|
| L161 | 修改配置时保留 active，防同一轮未恢复风暴只因改门限重复告警。 |
| L162 | 必须观察到一个 valid 的低速窗口才重新武装；status 查询不会修改此状态。 |
| L163 | 修改一个运行配置项，key 为枚举下标，value 为无符号整数。 |
| L164 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L165 | 静态只读上下限表，每行分别对应四个 key。 |
| L166 | exit_limit=1..10^9/s；sustain_s=1..60；window_min_ms=1..1000；window_max_ms=1000..10000。1249 不能作为 min，即使它小于 max。 |
| L167 | 结束前面的结构、枚举或数组定义；分号完成声明。 |
| L168 | 保存配置锁的 IRQ 状态。 |
| L169 | 未初始化时不接受运行配置修改。 |
| L170 | 先检查 key；C 的 &#124;&#124; 短路保证无效 key 不继续索引 bounds。 |
| L171 | 检查该 key 的上下限，越界返回 EINVALID；两个窗口参数的范围已保证 min<=max，但不是采样周期配置。 |
| L172 | 获取配置锁，保证值和 seq 作为一组发布。 |
| L173 | 只有数值真的不同才改变配置版本；写相同值不会重新建立观察窗口。 |
| L174 | 更新所选 value，其余三个值不变。 |
| L175 | 配置版本加一，回绕跳过 0；槽到下一次成功采样才认领新版本。 |
| L176 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L177 | 释放配置锁，不在此逐槽重置 active 或延迟统计。 |
| L178 | 返回成功；命令层随后打印简短 OK，配置接口本身不打印 JSON。 |
| L179 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="core-180"></a>

### sample 第一段：快照、抢锁、配置切换（L180–L210）

```c
L0180: /* Called only by one periodic executor. Never print or sleep here. */
L0181: void vmm_monitor_sample(u64 now)
L0182: {
L0183: 	u32 i, run = arch_atomic_read(&enabled);
L0184: 	irq_flags_t f;
L0185: 	struct data *d;
L0186: 	struct event e;
L0187: 	struct monitor_config cfg;
L0188: 	bool high;
L0189: 	vmm_spin_lock_irqsave_lite(&event_lock, f); cfg = config;
L0190: 	vmm_spin_unlock_irqrestore_lite(&event_lock, f);
L0191: 	for (i = 0; i <= CONFIG_MAX_VCPU_COUNT; i++) {
L0192: 		if (!vmm_spin_trylock_irqsave(&slots[i].lock, f)) {
L0193: 			arch_atomic_inc(&skipped); continue;
L0194: 		}
L0195: 		d = &slots[i].d;
L0196: 		/* Faults captured before stop/reset must still reach the event ring. */
L0197: 		memory_flush(d);
L0198: #ifdef CONFIG_WBOXTEST_MONITOR
L0199: 		/* A global pass may skip this slot; only successful flushes count. */
L0200: 		test_sample_actor[i]++;
L0201: #endif
L0202: 		if (!run || d->epoch != run || !d->present) goto next;
L0203: 		if (!d->config_seq && cfg.seq == 1) d->config_seq = cfg.seq;
L0204: 		if (d->config_seq != cfg.seq) {
L0205: 			/* Discard the window straddling the update; keep latency/history. */
L0206: 			d->config_seq = cfg.seq; d->previous = now;
L0207: 			d->interval = d->count = d->exits = d->sustained = 0;
L0208: 			d->windows = 0; d->valid = FALSE;
L0209: 			goto next;
L0210: 		}
```

| 原行号 | 逐行解释 |
|---|---|
| L180 | sample 的调用约束：只允许一个串行周期执行者；函数内不打印、不睡眠。 |
| L181 | 按传入的 now 切窗、发布内存摘要并判定风暴；不是逐个读取 Guest CPU 使用率。 |
| L182 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L183 | 在本次扫描开始时读取一次 run。扫描中另一个核 stop 后，本轮已开始的判定可能收尾。 |
| L184 | 保存 trylock / event_lock 操作的 IRQ 状态。 |
| L185 | 当前遍历槽的数据指针。 |
| L186 | 栈上的待发布风暴事件；告警分支会填满所有对外成员，seq 由 emit 分配。 |
| L187 | 本轮一致的配置快照；不能把每个字段都在不同时间无锁读取。 |
| L188 | high 表示该有效窗口的退出速率是否严格高于门限。 |
| L189 | 在事件锁内把 config 整体复制到 cfg。 |
| L190 | 先释放 event_lock，后面才拿 slot，遵守锁顺序。 |
| L191 | 扫描所有普通槽，并包含末尾匿名槽；时间开销随 CONFIG_MAX_VCPU_COUNT 增长。 |
| L192 | 对每槽尝试加 IRQ-safe 锁而不等待；忙槽跳过，避免采样上下文长时间自旋。 |
| L193 | 抢锁失败累计 skipped 并处理下一槽；这是全局次数，不能直接归罪到某个目标 vCPU。 |
| L194 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L195 | 把当前槽 data 赋给 d。 |
| L196 | 已经采到的内存异常在 stop/reset 后仍需要发布。 |
| L197 | 先提交待处理内存摘要，再检查运行开关；所以 stop 后仍可能看到之前 fault 的新事件/日志。 |
| L198 | 下面的逐目标进度记录仅测试构建存在。 |
| L199 | 一次全局扫描可能跳过该槽，只有本槽实际拿到锁并经过 flush 才计进度。 |
| L200 | 增加本槽采样进度；即使没有待发布 memory 或当前 stop，也会加一。 |
| L201 | 结束条件编译：`#ifdef CONFIG_WBOXTEST_MONITOR`。 |
| L202 | 未开启、槽还属于旧 epoch、槽不存在时，不再切 exit 窗口；仍经过 next 解锁。 |
| L203 | 初始配置 seq=1 的新槽直接采用配置，允许第一次正常切窗；不是每个新配置都跳过版本切换。 |
| L204 | 检测槽还没应用本轮配置快照。 |
| L205 | 丢弃横跨配置变化的 exit 窗口，避免把旧门限计数套到新门限；保留 ready/dispatch 和 active。 |
| L206 | 槽采纳 cfg.seq，将 now 设为新窗口起点。 |
| L207 | 清最近窗口时长、最近退出数、待采退出数、连续高时长；链式赋值让四者都为 0。 |
| L208 | 清连续窗口数并置 valid=false；本轮只建立新基线，不判告警。 |
| L209 | 跳到统一解锁，等下一次采样再算新配置的有效窗口。 |
| L210 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="core-211"></a>

### sample 第二段：有效窗口、超限、去重和恢复（L211–L246）

```c
L0211: 		d->interval = now >= d->previous ? now - d->previous : 0;
L0212: 		d->previous = now;
L0213: 		d->count = d->exits; d->exits = 0;
L0214: 		d->valid = d->interval >= (u64)cfg.value[VMM_MONITOR_WINDOW_MIN_MS] * 1000000 &&
L0215: 			d->interval <= (u64)cfg.value[VMM_MONITOR_WINDOW_MAX_MS] * 1000000;
L0216: 		if (!d->valid) { d->sustained = 0; d->windows = 0; goto next; }
L0217: 		/* Host/idle scheduling is observable, but is not a Guest exit stream. */
L0218: 		if (d->kind != OBJECT_GUEST) goto next;
L0219: 		high = d->count > udiv64((u64)cfg.value[VMM_MONITOR_EXIT_LIMIT] * d->interval, VMM_MONITOR_NS);
L0220: 		if (!high) {
L0221: 			d->windows = 0; d->sustained = 0; d->active = FALSE;
L0222: 			goto next;
L0223: 		}
L0224: 		if (d->active) goto next;
L0225: 		d->windows++; d->sustained += d->interval;
L0226: 		if (d->windows >= cfg.value[VMM_MONITOR_SUSTAIN_S] &&
L0227: 			d->sustained >= cfg.value[VMM_MONITOR_SUSTAIN_S] * VMM_MONITOR_NS) {
L0228: 			e.address = 0;
L0229: 			e.type = 1;
L0230: 			e.time = e.last = now;
L0231: 			e.guest = d->guest; e.vcpu = i; e.epoch = run;
L0232: 			e.value = udiv64(d->count * VMM_MONITOR_NS, d->interval);
L0233: 			e.detail = cfg.value[VMM_MONITOR_EXIT_LIMIT]; e.code = d->last_exit;
L0234: 			e.config_seq = cfg.seq; e.sustain_s = cfg.value[VMM_MONITOR_SUSTAIN_S];
L0235: 			d->active = emit(&e);
L0236: 		}
L0237: next:
L0238: 		vmm_spin_unlock_irqrestore(&slots[i].lock, f);
L0239: 	}
L0240: #ifdef CONFIG_WBOXTEST_MONITOR
L0241: 	/* Test-only completion fence: observers never force a sampling pass. */
L0242: 	vmm_spin_lock_irqsave_lite(&event_lock, f);
L0243: 	test_sample_serial++;
L0244: 	vmm_spin_unlock_irqrestore_lite(&event_lock, f);
L0245: #endif
L0246: }
```

| 原行号 | 逐行解释 |
|---|---|
| L211 | 计算当前窗口时长；若 now 比 previous 小，用 0 使窗口后续被判无效，避免无符号减法回绕。 |
| L212 | previous 推进到当前采样时间，用于下一次差分及 status.time_ns。 |
| L213 | 取走本窗口累计 exits 到 count，再清 exits 开始下一窗口；槽锁保证同槽打点不会穿插丢计数。 |
| L214 | 下限从 ms 转 ns 后作包含边界的 >= 比较。 |
| L215 | 上限同样转 ns 后作 <= 比较；valid 只检查时长，不检查业务正确性、调度耗时大小或事件是否落盘。 |
| L216 | 无效窗口清持续时间和连续窗口数，但没有清 active；不能因为缺采样就断言风暴已经恢复。 |
| L217 | host/idle 可以有调度统计和窗口时间，但不作为 Guest exit 风暴对象。 |
| L218 | 非 Guest 槽到此结束本轮判定；不会拿 host 的 exits=0 生成 Guest 风暴。 |
| L219 | 将速率门限按实际窗口换成允许次数 floor(limit*interval/10^9)，count 严格大于它才 high；不是固定比较 count>limit。 |
| L220 | 有效窗口未超限进入恢复/安静分支。 |
| L221 | 清连续累计并解除 active；包括“恰好等于门限”的有效窗口。没有单独发布恢复事件。 |
| L222 | 当前窗口已经处理，跳到解锁。 |
| L223 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L224 | 已告警且仍高则直接结束；只抑制当前 vCPU 同一轮风暴，不抑制其他 vCPU 告警，也不做时间间隔重复提醒。 |
| L225 | 未告警的高窗口累计一次窗口数，并加上实际 interval 纳秒。 |
| L226 | 必须至少达到 sustain_s 个有效高窗口；默认一秒执行，因此以该数限制窗口数。 |
| L227 | 同时实际累计高时长达到 sustain_s 秒，避免几个偏短窗口过早触发。5 个 999.9 ms 窗口仍不足 5 秒。 |
| L228 | 风暴没有此处可用的故障内存地址，address 固定 0；没有在此采 PC。 |
| L229 | type=1 表示 exit 风暴。 |
| L230 | time/last 都设为判定成立的采样时间；不是第一条超限 exit 的精确发生时刻。 |
| L231 | 记录槽 Guest ID、vCPU ID 和本轮采集 epoch。 |
| L232 | value 为当前触发窗口的整数每秒速率 floor(count*10^9/interval)，不是连续五秒总量。 |
| L233 | detail 保存触发时门限；code 保存最后一次 exit 原因，不能据此推断这五秒全由该原因造成。 |
| L234 | 将配置版本和持续秒数随事件固定下来，之后修改 config 不会改旧事件。 |
| L235 | 只有 emit 接受事件才 active=true；配置刚发生并发变化导致拒绝时仍保持可重新判定。 |
| L236 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L237 | 本槽所有早结束路径汇合到 next 标签。 |
| L238 | 对应 trylock 的非 lite 解锁并恢复 IRQ；锁宏配对不能随便换成另一套。 |
| L239 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L240 | 整轮进度接口只用于测试构建。 |
| L241 | 完成计数用来观察 sample 已走完一轮，不由测试强行调用 sample 制造进度。 |
| L242 | 用事件锁保护全局 sample_serial。 |
| L243 | 整轮结束次数加一，即使某些 slot 被 skipped 也加。 |
| L244 | 释放事件锁，采样结束。 |
| L245 | 结束条件编译：`#ifdef CONFIG_WBOXTEST_MONITOR`。 |
| L246 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="core-247"></a>

### print_event：结构化 JSON 和日志去向（L247–L261）

```c
L0247: static __attribute__((noinline)) void print_event(struct vmm_chardev *c,
L0248:                                                  const struct event *e, bool log)
L0249: {
L0250: 	/* Fixed stack storage; the maximum encoded record fits in 384 bytes. */
L0251: 	char line[384];
L0252: 	vmm_snprintf(line, sizeof(line), "{\"schema\":3,\"seq\":%llu,\"time_ns\":%llu,\"last_ns\":%llu,"
L0253: 		"\"type\":%u,\"guest\":%u,\"vcpu\":%u,\"epoch\":%u,\"code\":%u,"
L0254: 		"\"value\":%llu,\"address\":%llu,\"detail\":%llu,"
L0255: 		"\"config_seq\":%u,\"sustain_s\":%u}\n",
L0256: 		U(e->seq), U(e->time), U(e->last), e->type, e->guest, e->vcpu,
L0257: 		e->epoch, e->code, U(e->value), U(e->address), U(e->detail),
L0258: 		e->config_seq, e->sustain_s);
L0259: 	if (log) vmm_lwarning("monitor", "%s", line);
L0260: 	else vmm_cprintf(c, "%s", line);
L0261: }
```

| 原行号 | 逐行解释 |
|---|---|
| L247 | 统一格式化事件函数，noinline 防重复内联；c 是命令字符设备。 |
| L248 | e 是已复制出的事件；log 决定走日志后端还是指定命令输出设备。 |
| L249 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L250 | 注释说明使用固定栈空间；这只能约束本层格式化缓存，不能约束后端日志行长。 |
| L251 | 栈上 384 字节缓冲区，不使用堆；最大字段编码会在本次文档校验中核对。 |
| L252 | 有界 snprintf 开始 JSON，schema=3；seq/time_ns/last_ns 以无符号十进制输出。 |
| L253 | 继续拼接事件类别、Guest/vCPU/epoch、code；C 会把相邻字符串字面量在编译时连接。 |
| L254 | value/address/detail 用 64 位十进制，地址没有自动格式化为十六进制。 |
| L255 | 输出配置证据，结束 JSON 并换行；每条对象独立一行，整个流不是一个 JSON 数组。 |
| L256 | 按格式顺序传入 seq/time/last/type/guest/vcpu；U 转换对应 %llu。 |
| L257 | 传入 epoch/code/value/address/detail，类型与格式一一对应。 |
| L258 | 传入 config_seq/sustain_s，完成这一次格式化。 |
| L259 | 日志模式把完整 line 交给 vmm_lwarning，前缀 monitor；你产品后端会同时落日志与串口回显，代码没有独立的“只落盘”开关。 |
| L260 | 命令模式用 vmm_cprintf 输出同一行，不调用日志函数，也不改变日志 cursor。 |
| L261 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="core-262"></a>

### event_get：按序号取仍在环内的事件（L262–L271）

```c
L0262: static bool event_get(u64 seq, struct event *e)
L0263: {
L0264: 	irq_flags_t f;
L0265: 	bool found;
L0266: 	vmm_spin_lock_irqsave_lite(&event_lock, f);
L0267: 	found = seq && seq <= head && head - seq < VMM_MONITOR_EVENTS;
L0268: 	if (found) *e = ring[(seq - 1) % VMM_MONITOR_EVENTS];
L0269: 	vmm_spin_unlock_irqrestore_lite(&event_lock, f);
L0270: 	return found;
L0271: }
```

| 原行号 | 逐行解释 |
|---|---|
| L262 | 按完整事件序号读取环内快照；返回事件是否仍可获取。 |
| L263 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L264 | 保存事件锁的 IRQ 状态。 |
| L265 | found 保存查询有效性。 |
| L266 | 锁内检查 head 和复制 ring，避免两步间槽被覆盖。 |
| L267 | seq 非零、不能来自未来、距 head 小于环容量才可取；不要求它尚未打日志。 |
| L268 | 复制到调用者对象；不返回锁外可能被覆盖的环内指针。 |
| L269 | 释放锁后，调用者可安全格式化副本。 |
| L270 | 返回 found；事件已覆盖时调用者可跳过，不凭旧序号输出错条目。 |
| L271 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="core-272"></a>

### drain：每批最多8条日志（L272–L293）

```c
L0272: void vmm_monitor_drain(void)
L0273: {
L0274: 	struct event e;
L0275: 	u32 n;
L0276: 	irq_flags_t f;
L0277: 	/* One worker; a bounded batch prevents an endless log loop. */
L0278: 	for (n = 0; n < 8; n++) {
L0279: 		vmm_spin_lock_irqsave_lite(&event_lock, f);
L0280: 		if (cursor > head) { vmm_spin_unlock_irqrestore_lite(&event_lock, f); break; }
L0281: 		e = ring[(cursor++ - 1) % VMM_MONITOR_EVENTS];
L0282: 		vmm_spin_unlock_irqrestore_lite(&event_lock, f);
L0283: 		print_event(NULL, &e, TRUE);
L0284: #ifdef CONFIG_WBOXTEST_MONITOR
L0285: 		vmm_spin_lock_irqsave_lite(&event_lock, f);
L0286: 		if (test_logged[(e.seq - 1) % VMM_MONITOR_EVENTS] != e.seq)
L0287: 			test_log_calls[(e.seq - 1) % VMM_MONITOR_EVENTS] = 0;
L0288: 		test_logged[(e.seq - 1) % VMM_MONITOR_EVENTS] = e.seq;
L0289: 		test_log_calls[(e.seq - 1) % VMM_MONITOR_EVENTS]++;
L0290: 		vmm_spin_unlock_irqrestore_lite(&event_lock, f);
L0291: #endif
L0292: 	}
L0293: }
```

| 原行号 | 逐行解释 |
|---|---|
| L272 | 后台日志消费者；接口要求单一串行执行者，不在采样 IRQ 中执行。 |
| L273 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L274 | 栈上事件副本，保证打印期间不用持有事件锁。 |
| L275 | 单批循环计数 n。 |
| L276 | 保存锁操作的 IRQ 状态。 |
| L277 | 每次处理有上限，避免新事件持续涌入使日志线程陷入无界循环。 |
| L278 | 一次 drain 最多处理 8 条，不等于事件环只有 8 条。 |
| L279 | 短暂锁住队列游标和环。 |
| L280 | cursor 已超过 head 表示没有待日志事件；先解锁再退出循环。 |
| L281 | 取当前 cursor 事件副本并递增 cursor；先消费、后调用日志，本身没有失败重试/落盘确认协议。 |
| L282 | 释放事件锁，耗时日志输出在锁外执行。 |
| L283 | log=true，传 NULL 字符设备，由 print_event 走 vmm_lwarning。 |
| L284 | 测试构建才维护日志回执。 |
| L285 | 重新拿事件锁，避免回执读写竞争。 |
| L286 | 同一个物理环下标可能对应另一个 seq，必须先识别是否已换代。 |
| L287 | 换代后把该下标的调用次数清 0，不能继承旧事件次数。 |
| L288 | 写下本次真正调用完成的事件序号。 |
| L289 | 增加该完整事件的日志调用次数，测试可发现重复 drain/打印。 |
| L290 | 释放事件锁；到这里仍只代表日志函数返回。 |
| L291 | 结束条件编译：`#ifdef CONFIG_WBOXTEST_MONITOR`。 |
| L292 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L293 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="core-294"></a>

### dump 前半段：events 与 config 视图（L294–L318）

```c
L0294: int vmm_monitor_dump(struct vmm_chardev *c, u32 view)
L0295: {
L0296: 	static const char * const kinds[] = { "guest", "host", "idle" };
L0297: 	u32 i, current;
L0298: 	u64 end, drops, seq, now;
L0299: 	irq_flags_t f;
L0300: 	struct event e;
L0301: 	struct data d;
L0302: 	struct monitor_config cfg;
L0303: 	if (view > VMM_MONITOR_CONFIG_VIEW) return VMM_EINVALID;
L0304: 	if (!arch_atomic_read(&initialized)) return VMM_ENOTAVAIL;
L0305: 	vmm_spin_lock_irqsave_lite(&event_lock, f);
L0306: 	end = head; drops = lost; current = epoch; cfg = config;
L0307: 	vmm_spin_unlock_irqrestore_lite(&event_lock, f);
L0308: 	if (view == VMM_MONITOR_EVENTS_VIEW) {
L0309: 		for (seq = end >= VMM_MONITOR_EVENTS ? end - VMM_MONITOR_EVENTS + 1 : 1; seq <= end; seq++)
L0310: 			if (event_get(seq, &e)) print_event(c, &e, FALSE);
L0311: 		return VMM_OK;
L0312: 	}
L0313: 	if (view == VMM_MONITOR_CONFIG_VIEW) {
L0314: 		vmm_cprintf(c, "exit_limit=%u/s sustain_s=%us window_min_ms=%u window_max_ms=%u\n",
L0315: 			cfg.value[VMM_MONITOR_EXIT_LIMIT], cfg.value[VMM_MONITOR_SUSTAIN_S],
L0316: 			cfg.value[VMM_MONITOR_WINDOW_MIN_MS], cfg.value[VMM_MONITOR_WINDOW_MAX_MS]);
L0317: 		return VMM_OK;
L0318: 	}
```

| 原行号 | 逐行解释 |
|---|---|
| L294 | 三种只读视图的统一入口；不会主动调用 sample/record 让数据更新。 |
| L295 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L296 | 字符串下标对应 OBJECT_GUEST/HOST/IDLE；kind 是内部生成的合法枚举。 |
| L297 | i 遍历普通槽，current 保存本次全局 epoch 快照。 |
| L298 | end 为 head 快照，drops 为 lost 快照，seq 遍历事件，now 用于 READY 当前年龄。 |
| L299 | 保存 IRQ 锁状态。 |
| L300 | 命令输出一条事件所需副本。 |
| L301 | 输出一个槽的数据副本，防止拿着 slot 锁慢速打印。 |
| L302 | 保存查询开始时的配置快照。 |
| L303 | 拒绝未定义视图编号。 |
| L304 | 模块未初始化成功则不能查询。 |
| L305 | 拿事件锁读取全局控制数据。 |
| L306 | 固定这次查询使用的 head/lost/epoch/config 快照，后续不一直持锁。 |
| L307 | 释放事件锁；后续每槽独立取快照，所以整份 status 不是全系统同一瞬间的原子快照。 |
| L308 | events 视图进入事件环历史遍历。 |
| L309 | 起点为仍可能存在的最近最多 16 条，终点为开始查询时的 end；包含已输出日志的事件。 |
| L310 | 逐条调用 event_get，仍存在才打印；查询期间被覆盖的条目会跳过。 |
| L311 | events 查询完成返回成功，不推进日志 cursor、不清空 ring。 |
| L312 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L313 | config 视图只打印四个配置值。 |
| L314 | 使用简短文本输出单位和参数名称，不输出配置 JSON。 |
| L315 | 先取退出速率、持续秒数。 |
| L316 | 再取窗口时长上下限，二者都是 ms。 |
| L317 | 配置查询完成，不改变 config_seq 或风暴 active。 |
| L318 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="core-319"></a>

### dump 后半段：模块和对象 status（L319–L341）

```c
L0319: 	vmm_cprintf(c, "{\"schema\":3,\"enabled\":%u,\"epoch\":%u,\"sampler_cpu\":%u,"
L0320: 		"\"events\":%llu,\"lost\":%llu,\"skipped\":%u,\"errors\":%u,"
L0321: 		"\"exit_limit\":%u,\"sustain_s\":%u,\"window_min_ms\":%u,"
L0322: 		"\"window_max_ms\":%u,\"config_seq\":%u}\n", !!arch_atomic_read(&enabled), current,
L0323: 		sampler_cpu, U(end), U(drops), (u32)arch_atomic_read(&skipped),
L0324: 		(u32)arch_atomic_read(&errors), cfg.value[VMM_MONITOR_EXIT_LIMIT],
L0325: 		cfg.value[VMM_MONITOR_SUSTAIN_S], cfg.value[VMM_MONITOR_WINDOW_MIN_MS],
L0326: 		cfg.value[VMM_MONITOR_WINDOW_MAX_MS], cfg.seq);
L0327: 	for (i = 0; i < CONFIG_MAX_VCPU_COUNT; i++) {
L0328: 		vmm_spin_lock_irqsave_lite(&slots[i].lock, f); d = slots[i].d;
L0329: 		vmm_spin_unlock_irqrestore_lite(&slots[i].lock, f);
L0330: 		if (!d.present || d.epoch != current) continue;
L0331: 		now = vmm_timer_timestamp();
L0332: 		vmm_cprintf(c, "{\"schema\":3,\"kind\":\"%s\",\"guest\":%u,\"vcpu\":%u,\"epoch\":%u,"
L0333: 			"\"time_ns\":%llu,\"interval_ns\":%llu,\"valid\":%u,\"exits\":%llu,\"ready_age_ns\":%llu,"
L0334: 			"\"ready\":[%llu,%llu,%llu],\"dispatch\":[%llu,%llu,%llu]}\n",
L0335: 			kinds[d.kind], d.guest, i, d.epoch, U(d.previous), U(d.interval), d.valid, U(d.count),
L0336: 			U(d.waiting && arch_atomic_read(&enabled) == d.epoch && now >= d.ready_since ? now - d.ready_since : 0),
L0337: 			U(d.ready.count), U(d.ready.count ? udiv64(d.ready.sum, d.ready.count) : 0), U(d.ready.max),
L0338: 			U(d.dispatch.count), U(d.dispatch.count ? udiv64(d.dispatch.sum, d.dispatch.count) : 0), U(d.dispatch.max));
L0339: 	}
L0340: 	return VMM_OK;
L0341: }
```

| 原行号 | 逐行解释 |
|---|---|
| L319 | status 首行 JSON 输出模块级开关、采集 epoch、初始化物理核。 |
| L320 | events 为累计发布序号 head，不是当前环内条数；lost/skipped/errors 分别反映未消费覆盖、抢锁跳过、执行器失败。 |
| L321 | 把当前门限和窗口下限加入 status 首行。 |
| L322 | 加入窗口上限和配置版本；!!enabled 转成 0/1 对外显示，内部仍保存 epoch。 |
| L323 | 填 sampler_cpu、head/lost 快照及读取时刻的 skipped；它们不保证来自完全相同的时间点。 |
| L324 | 读取 errors 并填速率门限。 |
| L325 | 填持续秒数和窗口下限。 |
| L326 | 填窗口上限和配置版本，结束模块级记录。 |
| L327 | 仅遍历真实 ID 槽；匿名 fault 槽不作为 vCPU status 行输出。 |
| L328 | 在每槽锁内复制完整 data。 |
| L329 | 释放 slot 锁后再过滤/打印，避免串口速度拖长临界区。 |
| L330 | 仅显示 present 且属于本次 current epoch 的槽；stop 不改变 epoch，因此仍可显示停前快照。 |
| L331 | 查询时另取当前时间，专门计算尚未结束的 READY 年龄。 |
| L332 | 每个对象输出 kind/guest/vcpu/epoch；不输出管理器的完整 State 或优先级。 |
| L333 | time_ns/interval/valid/exits 是最近成功切窗保存的数据；ready_age 是查询时补算的值。 |
| L334 | ready 和 dispatch 都是 [累计次数,累计均值ns,累计最大值ns]，不是 [min,p99,max]。 |
| L335 | time_ns 使用 previous；exits 使用 count，不是此刻正在累积、尚未切窗的 exits。 |
| L336 | 仅 waiting、当前仍在相同 enabled epoch 且时间未倒退时计算 now-ready_since；stop 后此字段显示 0。 |
| L337 | READY mean=sum/count，count=0 时给 0 防除零；不把 sum 输出为均值。 |
| L338 | dispatch 同样按累计 count/sum/max 输出，至此结束此对象 JSON 行。 |
| L339 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L340 | 返回查询成功，不表示有足够新窗口或所有槽 valid。 |
| L341 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="core-342"></a>

### report 与 tick：内部执行器（L342–L361）

```c
L0342: #ifndef CONFIG_MONITOR_EXTERNAL_EXECUTOR
L0343: static void report(struct vmm_work *unused) { vmm_monitor_drain(); }
L0344: static void tick(struct vmm_timer_event *ev)
L0345: {
L0346: 	u64 now = vmm_timer_timestamp();
L0347: 	irq_flags_t f;
L0348: 	bool pending;
L0349: 	int rc;
L0350: 	vmm_monitor_sample(now);
L0351: 	vmm_spin_lock_irqsave_lite(&event_lock, f); pending = cursor <= head;
L0352: 	vmm_spin_unlock_irqrestore_lite(&event_lock, f);
L0353: 	if (pending) {
L0354: 		rc = vmm_workqueue_schedule_work(queue, &work);
L0355: 		if (rc && rc != VMM_EALREADY) arch_atomic_inc(&errors);
L0356: 	}
L0357: 	now = vmm_timer_timestamp();
L0358: 	deadline += (udiv64(now >= deadline ? now - deadline : 0, VMM_MONITOR_NS) + 1) * VMM_MONITOR_NS;
L0359: 	if (vmm_timer_event_start(ev, deadline - now)) arch_atomic_inc(&errors);
L0360: }
L0361: #endif
```

| 原行号 | 逐行解释 |
|---|---|
| L342 | 以下 tick/report 只用于内部执行器模式。 |
| L343 | report 是工作队列回调，仅调用 drain；unused 是接口要求但本函数不使用的任务参数。 |
| L344 | tick 是定时器回调，ev 是本次到期的 timer 对象。 |
| L345 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L346 | 一次采样使用同一个 now 作为各槽切窗时间，避免遍历先后造成不同的判定时间戳。 |
| L347 | 保存事件锁的 IRQ 状态。 |
| L348 | pending 表示有没有尚未交给日志函数的事件。 |
| L349 | rc 接收提交工作任务的返回码。 |
| L350 | 在定时上下文做采样判定，日志线程优先级不会决定此处什么时候开始打调度点。 |
| L351 | 锁内检查 cursor<=head，判断是否应唤醒日志工作队列。 |
| L352 | 检查完成立即解锁。 |
| L353 | 没有待日志时不提交工作，避免无意义唤醒。 |
| L354 | 提交同一 work 对象；任务函数 report 将在日志线程上下文执行。 |
| L355 | EALREADY 表示已经排队，不作为错误；其他非零返回累计 errors。 |
| L356 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L357 | 完成当前采样/投递后重新取时间，用来安排下一次截止点。 |
| L358 | 将 deadline 按整秒推进到 now 之后：延迟过多个周期时跳过过去的点，不补跑一长串历史采样；非“周期可配置”。 |
| L359 | 以 deadline-now 的相对间隔重启 timer；失败只增加 errors，本函数没有另设自动重试执行器。 |
| L360 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L361 | 结束条件编译：`#ifndef CONFIG_MONITOR_EXTERNAL_EXECUTOR`。 |

<a id="core-362"></a>

### init 与导出符号（L362–L393）

```c
L0362: int __init vmm_monitor_init(void)
L0363: {
L0364: 	u32 i;
L0365: #ifndef CONFIG_MONITOR_EXTERNAL_EXECUTOR
L0366: 	int rc;
L0367: #endif
L0368: 	for (i = 0; i <= CONFIG_MAX_VCPU_COUNT; i++) INIT_SPIN_LOCK(&slots[i].lock);
L0369: 	sampler_cpu = vmm_smp_processor_id();
L0370: #ifndef CONFIG_MONITOR_EXTERNAL_EXECUTOR
L0371: 	INIT_WORK(&work, report);
L0372: 	INIT_TIMER_EVENT(&timer, tick, NULL);
L0373: 	queue = vmm_workqueue_create("monitor", CONFIG_MONITOR_PRIORITY);
L0374: 	if (!queue) return VMM_ENOMEM;
L0375: 	rc = vmm_threads_set_affinity(vmm_workqueue_get_thread(queue), vmm_cpumask_of(sampler_cpu));
L0376: 	if (!rc) {
L0377: 		deadline = vmm_timer_timestamp() + VMM_MONITOR_NS;
L0378: 		rc = vmm_timer_event_start(&timer, VMM_MONITOR_NS);
L0379: 	}
L0380: 	if (rc) { vmm_workqueue_destroy(queue); return rc; }
L0381: #endif
L0382: 	arch_wmb();
L0383: 	arch_atomic_write(&initialized, 1);
L0384: #ifdef CONFIG_MONITOR_START_ENABLED
L0385: 	vmm_monitor_enable(TRUE);
L0386: #endif
L0387: 	return VMM_OK;
L0388: }
L0389: VMM_EXPORT_SYMBOL(vmm_monitor_record);
L0390: VMM_EXPORT_SYMBOL(vmm_monitor_enable);
L0391: VMM_EXPORT_SYMBOL(vmm_monitor_dump);
L0392: VMM_EXPORT_SYMBOL(vmm_monitor_configure);
L0393: 
```

| 原行号 | 逐行解释 |
|---|---|
| L362 | 初始化入口带 __init，预期由启动流程调用一次；没有重复初始化保护或对应退出函数。 |
| L363 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L364 | 循环变量，用来初始化每个 slot 的锁。 |
| L365 | 外部执行器没有下面的内部创建返回码变量。 |
| L366 | rc 保存 affinity/timer_start 的失败码。 |
| L367 | 结束条件编译：`#ifndef CONFIG_MONITOR_EXTERNAL_EXECUTOR`。 |
| L368 | 包括匿名槽在内初始化全部 slot 锁；静态 data/事件环初值由静态存储零初始化提供。 |
| L369 | 记录执行初始化的物理核；内部 timer 从该核启动，日志线程随后也绑定该核。 |
| L370 | 只有内部模式才创建任务与队列。 |
| L371 | 初始化静态 work 对象并绑定 report 回调。 |
| L372 | 初始化 timer 对象并绑定 tick，私有参数为 NULL。 |
| L373 | 创建名字 monitor、优先级 CONFIG_MONITOR_PRIORITY 的日志队列；底层创建线程时可分配内存。 |
| L374 | 队列创建失败直接 ENOMEM；initialized 仍为 0，打点快速退出。 |
| L375 | 将日志线程亲和性设置为仅 sampler_cpu；这不是调整 auth/mterm/Guest 的亲和性或优先级。 |
| L376 | affinity 成功才继续启动 timer。 |
| L377 | 首个绝对截止点=当前时间+1秒。 |
| L378 | 申请约1秒后的第一次 timer 回调；不是 start 命令调用时才创建 timer。 |
| L379 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L380 | affinity 或 timer_start 任一失败，销毁刚创建的队列并返回原错误码。 |
| L381 | 结束条件编译：`#ifndef CONFIG_MONITOR_EXTERNAL_EXECUTOR`。 |
| L382 | 发布 initialized 前先做写屏障，让之前初始化写入按架构屏障约束先完成；不是采集周期屏障。 |
| L383 | 置 initialized=1，从此记录/控制/查询接口可用。 |
| L384 | 编译选择开机采集时才执行下面的自动 start。 |
| L385 | 复用 enable(TRUE) 分配第一个非零 epoch；默认未选择时保持 enabled=0。 |
| L386 | 结束条件编译：`#ifdef CONFIG_MONITOR_START_ENABLED`。 |
| L387 | 返回初始化成功；不等于已经采到任何调度或风暴数据。 |
| L388 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L389 | 导出通用记录函数，供需要符号解析的其他模块引用。 |
| L390 | 导出运行开关接口。 |
| L391 | 导出查询接口。 |
| L392 | 导出运行配置接口；sample/drain 虽在头文件有声明，本文件未用同类宏导出，外部执行器通常须与核心静态链接或按平台导出方式接入。 |
| L393 | 空行，分隔声明/逻辑段，不产生指令。 |

<a id="core-394"></a>

### 测试观察接口：读取全局状态（L394–L409）

这是已有核心文件中的条件编译代码；本篇解释接口语义，不展开测试用例。

```c
L0394: #ifdef CONFIG_WBOXTEST_MONITOR
L0395: /* Read-only access for wboxtest; compiled out with the test option. */
L0396: int vmm_monitor_test_state(struct vmm_monitor_test_state *out)
L0397: {
L0398: 	irq_flags_t f;
L0399: 	if (!out) return VMM_EINVALID;
L0400: 	if (!arch_atomic_read(&initialized)) return VMM_ENOTAVAIL;
L0401: 	vmm_spin_lock_irqsave_lite(&event_lock, f);
L0402: 	out->epoch=epoch; out->enabled=arch_atomic_read(&enabled);
L0403: 	out->config_seq=config.seq;
L0404: 	memcpy(out->config,config.value,sizeof(out->config));
L0405: 	out->head=head; out->lost=lost;
L0406: 	out->skipped=arch_atomic_read(&skipped); out->errors=arch_atomic_read(&errors);
L0407: 	vmm_spin_unlock_irqrestore_lite(&event_lock, f);
L0408: 	return VMM_OK;
L0409: }
```

| 原行号 | 逐行解释 |
|---|---|
| L394 | 以下只读 API 由 CONFIG_WBOXTEST_MONITOR 控制；关闭测试不会带入它们。 |
| L395 | 这些 API 用来读取真实 monitor 内部状态，不负责注入 fault、强行采样或清空生产数据。 |
| L396 | 获取模块控制状态，out 必须由调用者提供可写存储。 |
| L397 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L398 | 保存锁操作的 IRQ 状态。 |
| L399 | out=NULL 返回 EINVALID，不允许写空指针。 |
| L400 | 模块未就绪返回 ENOTAVAIL。 |
| L401 | 获取事件锁，使配置、epoch、环计数等成组复制。 |
| L402 | 输出全局 epoch 和 enabled 原始值；这里 enabled 可以是 epoch=2/3等，不限于 status JSON 的0/1。 |
| L403 | 输出当前配置版本。 |
| L404 | 拷贝四个配置值，长度使用目标数组大小。 |
| L405 | 输出累计事件序号和未消费覆盖数。 |
| L406 | 输出当前全局 skipped/errors 原子值；并非某个特定 vCPU 的错误数。 |
| L407 | 释放事件锁。 |
| L408 | 状态复制成功返回 VMM_OK。 |
| L409 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="core-410"></a>

### 测试观察接口：读取指定槽（L410–L426）

```c
L0410: int vmm_monitor_test_slot(u32 id, struct vmm_monitor_test_slot *out)
L0411: {
L0412: 	irq_flags_t f;
L0413: 	struct data *d;
L0414: 	if (!out || id >= CONFIG_MAX_VCPU_COUNT) return VMM_EINVALID;
L0415: 	if (!arch_atomic_read(&initialized)) return VMM_ENOTAVAIL;
L0416: 	vmm_spin_lock_irqsave_lite(&slots[id].lock, f); d=&slots[id].d;
L0417: 	out->epoch=d->epoch; out->guest=d->guest; out->kind=d->kind;
L0418: 	out->config_seq=d->config_seq; out->present=d->present;
L0419: 	out->waiting=d->waiting; out->valid=d->valid; out->active=d->active;
L0420: 	out->ready_since=d->ready_since; out->previous=d->previous;
L0421: 	out->interval=d->interval; out->exits=d->count;
L0422: 	out->ready=(struct vmm_monitor_test_latency){d->ready.count,d->ready.sum,d->ready.max};
L0423: 	out->dispatch=(struct vmm_monitor_test_latency){d->dispatch.count,d->dispatch.sum,d->dispatch.max};
L0424: 	vmm_spin_unlock_irqrestore_lite(&slots[id].lock, f);
L0425: 	return VMM_OK;
L0426: }
```

| 原行号 | 逐行解释 |
|---|---|
| L410 | 读取指定普通 vCPU 槽的快照；不直接访问调度器状态机。 |
| L411 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L412 | 保存 IRQ 状态。 |
| L413 | 指向被查询槽内部数据，仅锁内使用。 |
| L414 | 拒绝空输出或 ID 越界；不允许用额外匿名槽下标调用此接口。 |
| L415 | 未初始化不能查询。 |
| L416 | 锁住该槽并取得数据指针。 |
| L417 | 输出采集轮次、Guest 归属和对象类别。 |
| L418 | 输出本槽已采用配置版本及 present；它可能尚未跟上全局配置版本。 |
| L419 | 输出等待标记、窗口有效性与风暴 active，便于观察触发/去重/恢复。 |
| L420 | 输出 READY 起点与采样边界时间。 |
| L421 | exits 对外取 d->count，即最近采样窗口数，不是正在累积的 d->exits。 |
| L422 | 构造 READY 的 count/sum/max 副本；测试可自己计算均值，接口不做除法。 |
| L423 | 同样复制 dispatch 的 count/sum/max。 |
| L424 | 释放 slot 锁。 |
| L425 | 返回读取成功；调用者还需核对 epoch/present/valid，不把成功返回等同于有新有效数据。 |
| L426 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="core-427"></a>

### 测试观察接口：读取事件和日志回执（L427–L446）

```c
L0427: int vmm_monitor_test_event(u64 seq, struct vmm_monitor_test_event *out)
L0428: {
L0429: 	irq_flags_t f;
L0430: 	struct event *e;
L0431: 	if (!out || !seq) return VMM_EINVALID;
L0432: 	if (!arch_atomic_read(&initialized)) return VMM_ENOTAVAIL;
L0433: 	vmm_spin_lock_irqsave_lite(&event_lock, f);
L0434: 	if (seq > head || head-seq >= VMM_MONITOR_EVENTS) {
L0435: 		vmm_spin_unlock_irqrestore_lite(&event_lock, f);
L0436: 		return VMM_ENOTAVAIL;
L0437: 	}
L0438: 	e=&ring[(seq-1)%VMM_MONITOR_EVENTS];
L0439: 	*out=(struct vmm_monitor_test_event){e->seq,e->time,e->last,e->value,e->address,e->detail,
L0440: 		e->type,e->guest,e->vcpu,e->epoch,e->code,e->config_seq,e->sustain_s,
L0441: 		test_logged[(seq-1)%VMM_MONITOR_EVENTS]==seq,
L0442: 		test_logged[(seq-1)%VMM_MONITOR_EVENTS]==seq ? test_log_calls[(seq-1)%VMM_MONITOR_EVENTS] : 0};
L0443: 	vmm_spin_unlock_irqrestore_lite(&event_lock, f);
L0444: 	return VMM_OK;
L0445: }
L0446: 
```

| 原行号 | 逐行解释 |
|---|---|
| L427 | 按完整 seq 获取事件及日志调用回执。 |
| L428 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L429 | 保存 IRQ 状态。 |
| L430 | 锁内临时指向事件环槽。 |
| L431 | out=NULL 或 seq=0 都无效。 |
| L432 | 未初始化不能查询事件。 |
| L433 | 一把事件锁同时保护环内容和回执数据。 |
| L434 | 未来序号或超出最近16条的序号不可获取。 |
| L435 | 失败路径先释放锁。 |
| L436 | 返回 ENOTAVAIL，调用者应识别“已覆盖/不存在”，不能拿未赋值的 out 当证据。 |
| L437 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L438 | 通过 seq-1 求余定位事件。 |
| L439 | 以复合字面量复制六个 u64 字段，顺序必须与测试结构声明一致。 |
| L440 | 复制类别、身份、epoch、code 和配置证据。 |
| L441 | 只有回执的完整 seq 相同，log_returned 才为真；环下标相同不够。 |
| L442 | 仅在 seq 匹配时返回调用次数，否则为0，防读到旧事件的日志次数。 |
| L443 | 复制完成后释放锁。 |
| L444 | 返回事件快照读取成功，不自动等待落盘。 |
| L445 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L446 | 空行，分隔声明/逻辑段，不产生指令。 |

<a id="core-447"></a>

### 测试观察接口：逐主体与全局采样进度（L447–L470）

```c
L0447: int vmm_monitor_test_sample_actor(u32 actor, u64 *out)
L0448: {
L0449: 	irq_flags_t f;
L0450: 	u32 id = actor == ~0U ? CONFIG_MAX_VCPU_COUNT : actor;
L0451: 	if (!out || (actor != ~0U && actor >= CONFIG_MAX_VCPU_COUNT))
L0452: 		return VMM_EINVALID;
L0453: 	if (!arch_atomic_read(&initialized)) return VMM_ENOTAVAIL;
L0454: 	vmm_spin_lock_irqsave_lite(&slots[id].lock, f);
L0455: 	*out = test_sample_actor[id];
L0456: 	vmm_spin_unlock_irqrestore_lite(&slots[id].lock, f);
L0457: 	return VMM_OK;
L0458: }
L0459: 
L0460: int vmm_monitor_test_sample_serial(u64 *out)
L0461: {
L0462: 	irq_flags_t f;
L0463: 	if (!out) return VMM_EINVALID;
L0464: 	if (!arch_atomic_read(&initialized)) return VMM_ENOTAVAIL;
L0465: 	vmm_spin_lock_irqsave_lite(&event_lock, f);
L0466: 	*out = test_sample_serial;
L0467: 	vmm_spin_unlock_irqrestore_lite(&event_lock, f);
L0468: 	return VMM_OK;
L0469: }
L0470: #endif
```

| 原行号 | 逐行解释 |
|---|---|
| L447 | 读取某个 actor 的成功采样/flush 进度，用于定位目标槽是否真的获得过采样机会。 |
| L448 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L449 | 保存 IRQ 状态。 |
| L450 | 外部约定 ~0U 代表匿名主体；映射到内部额外槽，普通 ID 保持不变。 |
| L451 | 拒绝空输出、非匿名且越界的 actor。 |
| L452 | 参数无效返回 EINVALID。 |
| L453 | 未初始化返回 ENOTAVAIL。 |
| L454 | 与 sample 更新同一个计数器时使用同一把 slot 锁。 |
| L455 | 返回该槽成功经过 flush 阶段的累计次数，不等于内存 fault 次数。 |
| L456 | 释放该槽锁。 |
| L457 | 返回读取成功；测试仍须结合 epoch 判断是否属于目标采集轮次。 |
| L458 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L459 | 空行，分隔声明/逻辑段，不产生指令。 |
| L460 | 读取 sample 完整走完一轮的全局序号。 |
| L461 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L462 | 保存 IRQ 状态。 |
| L463 | 空输出参数无效。 |
| L464 | 未初始化不可读。 |
| L465 | 获取与写 sample_serial 相同的事件锁。 |
| L466 | 复制完整轮次计数；不能以它替代目标槽进度判断。 |
| L467 | 释放事件锁。 |
| L468 | 返回成功。 |
| L469 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L470 | 结束条件编译：`#ifdef CONFIG_WBOXTEST_MONITOR`。 |

## 4. cmd_monitor.c：逐行解释命令入口

源码：[查看参考文件](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/commands/cmd_monitor.c>). 本节行号针对该文件，SHA-256 见附录。

<a id="cmd-1"></a>

### 头文件和用法（L1–L10）

```c
L0001: /* SPDX-License-Identifier: GPL-2.0-or-later */
L0002: #include <vmm_monitor.h>
L0003: #include <vmm_cmdmgr.h>
L0004: #include <vmm_stdio.h>
L0005: #include <libs/stringlib.h>
L0006: static void monitor_usage(struct vmm_chardev *cdev)
L0007: {
L0008: 	vmm_cprintf(cdev, "monitor start|stop|status|events|config\n"
L0009: 		"monitor config exit_limit|sustain_s|window_min_ms|window_max_ms <decimal>\n");
L0010: }
```

| 原行号 | 逐行解释 |
|---|---|
| L1 | GPL 许可标记。 |
| L2 | 引入 monitor 控制/查询接口与 key/view 编号。 |
| L3 | 引入命令结构和注册接口。 |
| L4 | 引入命令字符设备输出接口。 |
| L5 | 引入 strcmp/strcpy。 |
| L6 | 打印用法函数，cdev 是当前 shell 的输出设备。 |
| L7 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L8 | 打印五个子命令；竖线表示备选，并非同时执行。 |
| L9 | 打印配置写法；相邻字符串连接成一次输出，最后参数必须是十进制。 |
| L10 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="cmd-11"></a>

### 解析与分发（L11–L46）

```c
L0011: static int monitor_exec(struct vmm_chardev *cdev, int argc, char **argv)
L0012: {
L0013: 	static const char *const keys[] = {"exit_limit", "sustain_s", "window_min_ms", "window_max_ms"};
L0014: 	const char *p;
L0015: 	u32 key, value = 0, digit;
L0016: 	int rc;
L0017: 	if (argc == 2) {
L0018: 		if (!strcmp(argv[1], "start")) return vmm_monitor_enable(TRUE);
L0019: 		if (!strcmp(argv[1], "stop")) return vmm_monitor_enable(FALSE);
L0020: 		if (!strcmp(argv[1], "status")) return vmm_monitor_dump(cdev, VMM_MONITOR_STATUS);
L0021: 		if (!strcmp(argv[1], "events")) return vmm_monitor_dump(cdev, VMM_MONITOR_EVENTS_VIEW);
L0022: 		if (!strcmp(argv[1], "config")) return vmm_monitor_dump(cdev, VMM_MONITOR_CONFIG_VIEW);
L0023: 	}
L0024: 	if (argc == 4 && !strcmp(argv[1], "config")) {
L0025: 		for (key = 0; key < VMM_MONITOR_CONFIG_KEYS; key++) {
L0026: 			if (!strcmp(argv[2], keys[key])) break;
L0027: 		}
L0028: 		p = argv[3];
L0029: 		if (!*p) goto invalid;
L0030: 		for (; *p; p++) {
L0031: 			digit = (u32)(*p - '0');
L0032: 			if (digit > 9 || value > (~0U - digit) / 10) goto invalid;
L0033: 			value = value * 10 + digit;
L0034: 		}
L0035: 		rc = vmm_monitor_configure(key, value);
L0036: 		if (rc) {
L0037: 			vmm_cprintf(cdev, "monitor: config failed (%d)\n", rc);
L0038: 			return rc;
L0039: 		}
L0040: 		vmm_cprintf(cdev, "OK: %s=%u\n", keys[key], value);
L0041: 		return VMM_OK;
L0042: 	}
L0043: invalid:
L0044: 	monitor_usage(cdev);
L0045: 	return VMM_EINVALID;
L0046: }
```

| 原行号 | 逐行解释 |
|---|---|
| L11 | 命令分发入口，argc 包含 monitor 本身，argv 保存每个分词。 |
| L12 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L13 | key 名称数组必须与 vmm_monitor_config_key 的下标顺序一致；两级 const 防误改指针或字符串内容。 |
| L14 | p 用于逐字符扫描数值字符串。 |
| L15 | key 是配置下标，value 从0开始累积，digit 保存当前十进制数字。 |
| L16 | rc 保存配置调用的返回值。 |
| L17 | 两个词时按 monitor 子命令处理。 |
| L18 | strcmp 返回0表示相等，! 将其转真；start 调 enable(TRUE)，没有额外 JSON 输出。 |
| L19 | stop 调 enable(FALSE)，返回其结果，不删除历史。 |
| L20 | status 调用统计视图，不主动触发采样。 |
| L21 | events 调用历史事件视图，不消费日志游标。 |
| L22 | 无附加参数的 config 只查询文本配置。 |
| L23 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L24 | 四个词且第二词为 config，才进入配置修改。 |
| L25 | 在四个键中查找第三个词。 |
| L26 | 命中名称退出循环，保留对应下标。 |
| L27 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L28 | 第四个词作为数字输入；未找到键时 key=4，后续 configure 会拒绝。 |
| L29 | 空数值不能当作0，直接显示用法并返回无效参数。 |
| L30 | 逐字符解析到字符串末尾，不接受空格、符号、十六进制前缀等附加字符。 |
| L31 | 字符减 '0' 后转 u32；负号等字符也会落到大于9的非法范围。 |
| L32 | 拒绝非数字；乘10前检查 value<=(UINT_MAX-digit)/10，防止 u32 溢出。它只检查数值可表示，业务上限另查。 |
| L33 | 安全地累积一个十进制位。 |
| L34 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L35 | 调核心配置接口检查 key 和业务范围，然后发布新配置版本。 |
| L36 | 非0返回表示失败。 |
| L37 | 打印简短错误码，例如 window_min_ms=1249 返回 -5；不会自动输出整份 JSON。 |
| L38 | 将原错误传回命令框架，框架可能再打印统一 Error 行。 |
| L39 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L40 | 成功后仅输出 OK: 键=值；此处 key 安全，因为无效 key 不可能通过 configure。 |
| L41 | 返回命令成功。 |
| L42 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L43 | 参数/语法错误汇合到 invalid 标签。 |
| L44 | 打印用法帮助。 |
| L45 | 返回 EINVALID。 |
| L46 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="cmd-47"></a>

### 命令注册与认证边界（L47–L56）

```c
L0047: static struct vmm_cmd monitor_cmd;
L0048: /* Built-in command remains behind the platform's existing authentication. */
L0049: int __init vmm_monitor_cmd_init(void)
L0050: {
L0051: 	strcpy(monitor_cmd.name, "monitor");
L0052: 	strcpy(monitor_cmd.desc, "HV monitor");
L0053: 	monitor_cmd.usage = monitor_usage;
L0054: 	monitor_cmd.exec = monitor_exec;
L0055: 	return vmm_cmdmgr_register_cmd(&monitor_cmd);
L0056: }
```

| 原行号 | 逐行解释 |
|---|---|
| L47 | 静态命令描述对象，不随每次输入动态创建；其余成员静态零初始化。 |
| L48 | 命令注册复用现有平台入口，认证仍由重构后的 mterm/auth 框架保证；这里没有另写认证机制。 |
| L49 | 启动时注册命令的初始化函数。 |
| L50 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L51 | 设置固定命令名 monitor；依赖命令结构 name 数组容量足够。 |
| L52 | 设置简短描述 HV monitor。 |
| L53 | 指向上方用法回调。 |
| L54 | 指向命令执行回调。 |
| L55 | 注册到命令管理器并返回原结果；注册失败由启动接入处报告。 |
| L56 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

## 5. 编译配置、对象构建和启动接入

源码：[查看参考文件](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/openconf.cfg>). 本节行号针对该文件，SHA-256 见附录。

<a id="config-1"></a>

### 核心、开机采集和日志优先级（L1–L21）

```text
L0001: menu "Monitor Agent"
L0002: config CONFIG_MONITOR_AGENT
L0003: 	bool "Lightweight hypervisor monitor"
L0004: 	depends on CONFIG_ARM64
L0005: 	default n
L0006: 	help
L0007: 	  vCPU READY/dispatch timing, rejected memory access and exit storms.
L0008: 	  Fixed storage, timer IRQ sampling, background structured logs and shell.
L0009: config CONFIG_MONITOR_START_ENABLED
L0010: 	bool "Collect from boot"
L0011: 	depends on CONFIG_MONITOR_AGENT
L0012: 	default n
L0013: config CONFIG_MONITOR_PRIORITY
L0014: 	int "Background logger priority"
L0015: 	depends on CONFIG_MONITOR_AGENT
L0016: 	default 3
L0017: 	range 0 7
L0018: 	help
L0019: 	  This priority controls background logging only. Scheduler hooks also
L0020: 	  record higher-priority host threads; sampling runs in the timer IRQ.
L0021: 
```

| 原行号 | 逐行解释 |
|---|---|
| L1 | 在配置界面打开 Monitor Agent 菜单。 |
| L2 | 定义核心总开关 CONFIG_MONITOR_AGENT。 |
| L3 | 布尔选项，用户界面名称为 Lightweight hypervisor monitor。 |
| L4 | 依赖 ARM64；当前接入不声明支持其他架构。 |
| L5 | 默认不编译核心，量产可按需关闭。 |
| L6 | 开始下面两行帮助文本。 |
| L7 | 帮助概述三类采集：READY/dispatch、拒绝内存访问、exit 风暴。 |
| L8 | 帮助说明静态采集存储、timer IRQ 采样、后台日志与 shell；不是 ROM/CPU 指标的测量证书。 |
| L9 | 定义启动即采集开关。 |
| L10 | 布尔选项，界面显示 Collect from boot。 |
| L11 | 必须先启用核心。 |
| L12 | 默认不从开机采集，需要后续 monitor start。 |
| L13 | 定义内部日志工作线程优先级。 |
| L14 | 整数选项，仅描述后台 logger。 |
| L15 | 依赖核心开关。 |
| L16 | 默认优先级3，与当前产品避免提高 monitor 优先级的选择一致。 |
| L17 | 配置工具只允许0..7，不意味着任取7对认证或实时性都合适。 |
| L18 | 开始优先级帮助文本。 |
| L19 | 强调此优先级只控制后台日志，调度打点在原调度上下文执行。 |
| L20 | 高优先级对象也可被打点；采样在定时器 IRQ，但关 IRQ/锁竞争仍会影响时效。 |
| L21 | 空行，分隔声明/逻辑段，不产生指令。 |

<a id="config-22"></a>

### 默认门限与外部执行器（L22–L44）

```text
L0022: config CONFIG_MONITOR_EXIT_RATE
L0023: 	int "Default exit storm threshold per vCPU per second"
L0024: 	depends on CONFIG_MONITOR_AGENT
L0025: 	default 50000
L0026: 	range 1 1000000000
L0027: 	help
L0028: 	  Boot default; runtime: monitor config exit_limit <value>.
L0029: config CONFIG_MONITOR_STORM_SECONDS
L0030: 	int "Default consecutive storm duration (seconds)"
L0031: 	depends on CONFIG_MONITOR_AGENT
L0032: 	default 5
L0033: 	range 1 60
L0034: 	help
L0035: 	  Boot default; runtime: monitor config sustain_s <value>.
L0036: config CONFIG_MONITOR_EXTERNAL_EXECUTOR
L0037: 	bool "Use existing platform timer and logger"
L0038: 	depends on CONFIG_MONITOR_AGENT
L0039: 	default n
L0040: 	help
L0041: 	  Platform must serialize sample() calls from an HV IRQ once per second,
L0042: 	  and drain() calls in a sleepable worker. Internal mode starts its timer
L0043: 	  on the initialization CPU, normally the boot CPU. No extra sampler thread.
L0044: endmenu
```

| 原行号 | 逐行解释 |
|---|---|
| L22 | 定义启动默认 exit 门限。 |
| L23 | 整数，单位为每个 vCPU 每秒退出数，不是全系统总中断数。 |
| L24 | 依赖核心开关。 |
| L25 | 默认50000/s。 |
| L26 | 配置范围1..1000000000，与运行 bounds 对应。 |
| L27 | 开始退出门限帮助。 |
| L28 | 编译值只是启动默认；运行后可用 monitor config exit_limit 修改。 |
| L29 | 定义默认风暴持续时间。 |
| L30 | 整数，单位秒；核心还同时要求至少同数目的有效高窗口。 |
| L31 | 依赖核心开关。 |
| L32 | 默认5秒。 |
| L33 | 允许1..60秒，与运行 bounds 一致。 |
| L34 | 开始持续时间帮助。 |
| L35 | 运行时通过 sustain_s 修改，不需重新编译。 |
| L36 | 定义是否改由平台现有执行器驱动。 |
| L37 | 布尔，选择已有平台 timer/logger。 |
| L38 | 依赖核心开关。 |
| L39 | 默认不选，即启用 monitor 内建 timer 和日志队列。 |
| L40 | 开始外部执行器约束说明。 |
| L41 | 平台须保证 sample 在 HV IRQ 中约每秒一次且不并发执行。 |
| L42 | drain 要串行在允许日志输出的工作上下文运行；内部模式的 timer 起点由初始化核决定。 |
| L43 | 初始化核通常是启动核；没有新增专门的采样线程，名为 monitor 的线程负责日志。 |
| L44 | 结束配置菜单。 |

### 5.1 其他构建文件的位置

下列片段来自各自文件，并非 openconf.cfg 的连续内容。

<a id="objects-1"></a>

### core/monitor/objects.mk（L1–L1）

```text
L0001: core-objs-$(CONFIG_MONITOR_AGENT)+= monitor/monitor_agent.o
```

| 原行号 | 逐行解释 |
|---|---|
| L1 | 只有 CONFIG_MONITOR_AGENT=y 时，monitor/monitor_agent.o 进入核心对象列表。参考顶层 Makefile 第264行递归搜集 core 下的 objects.mk、第282行包含它们，所以 core/objects.mk 不需要再重复添加这一对象。 |

<a id="coreconfig-172"></a>

### core/openconf.cfg 入口（L172–L172）

```text
L0172: source "core/monitor/openconf.cfg"
```

| 原行号 | 逐行解释 |
|---|---|
| L172 | 把 monitor 子菜单接入已有核心配置；只是引入配置文件，不等于默认启用功能。 |

<a id="cmdconfig-143"></a>

### commands/openconf.cfg 命令开关（L143–L148）

```text
L0143: config CONFIG_CMD_MONITOR
L0144: 	bool "monitor"
L0145: 	depends on CONFIG_MONITOR_AGENT
L0146: 	default y
L0147: 	help
L0148: 	  vCPU timing, memory events, exit storms and runtime start/stop.
```

| 原行号 | 逐行解释 |
|---|---|
| L143 | 定义 CONFIG_CMD_MONITOR，和核心开关区分：可编译核心但不提供 shell 命令。 |
| L144 | 布尔选项在命令菜单中显示 monitor。 |
| L145 | 必须先启用核心，避免命令调用未提供的 enable/dump/configure。 |
| L146 | 满足依赖时默认选择命令；核心默认仍是关闭。 |
| L147 | 开始帮助说明。 |
| L148 | 概述可查询的时间统计、内存事件、风暴及运行启停。 |

<a id="cmdobjects-43"></a>

### commands/objects.mk 对象入口（L43–L43）

```text
L0043: commands-objs-$(CONFIG_CMD_MONITOR)+= cmd_monitor.o
```

| 原行号 | 逐行解释 |
|---|---|
| L43 | 只有命令开关启用时加入 cmd_monitor.o，不创建额外线程。 |

<a id="main-25"></a>

### vmm_main.c 引入头文件（L25–L25）

```c
L0025: #include <vmm_monitor.h>
```

| 原行号 | 逐行解释 |
|---|---|
| L25 | 启动流程可以无条件调用 monitor 初始化：关闭时由头文件空桩返回成功。 |

<a id="main-439"></a>

### vmm_main.c 启动流程接入（L439–L444）

```c
L0439: 	/* Optional monitor failure must not prevent Guest boot. */
L0440: 	ret = vmm_monitor_init();
L0441: 	if (!ret)
L0442: 		ret = vmm_monitor_cmd_init();
L0443: 	if (ret)
L0444: 		vmm_printf("monitor_agent unavailable (error %d)\n", ret);
```

| 原行号 | 逐行解释 |
|---|---|
| L439 | 注释声明 monitor 可选，初始化失败不应阻止 Guest 启动。 |
| L440 | 调核心 init；内部模式此时创建工作队列并安排1秒 timer。 |
| L441 | 仅核心初始化成功才继续命令注册。 |
| L442 | 注册 monitor shell 命令；命令关闭时该调用为空桩。 |
| L443 | 核心或命令初始化任一失败时只打印。 |
| L444 | 输出不可用错误码，没有 goto 主启动失败分支；之后原启动逻辑继续。 |

## 6. 原有文件中的打点与辅助接入

本章讲 monitor 的新增/调整行和必需的原上下文。没有把 scheduler、MMU 或 CCM 的全部原实现算成 monitor 新增代码。

### 产品 scheduler 的版本说明

使用含 SCHED_HISTORY 和 t1/t2 的产品版本：[源码](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_scheduler_history_适配_20261022/core/vmm_scheduler.c>). 本文没有用上游 scheduler 替代它。

<a id="sched-24"></a>

### scheduler 头文件（L24–L24）

```c
L0024: #include <vmm_monitor.h>
```

| 原行号 | 逐行解释 |
|---|---|
| L24 | 引入统一打点宏；CONFIG_MONITOR_AGENT 关闭时这些宏消失，原 scheduler 功能仍保留。 |

<a id="sched-397"></a>

### next1 首次选中（L397–L402）

```c
L0397:         tstamp = vmm_timer_timestamp();
L0398:         vmm_monitor_selected(next, tstamp);
L0399: #ifdef CONFIG_SCHED_HISTORY
L0400:         sched_in_tstamp = tstamp;
L0401: #endif
L0402:         arch_vcpu_switch(NULL, next, regs);
```

| 原行号 | 逐行解释 |
|---|---|
| L397 | 复用调度器已有的选中时间戳，不单独为 monitor 再读一次时钟。 |
| L398 | __vmm_scheduler_next1 首次选中 next 时结束其 READY 等待；此处还没 arch_vcpu_switch，不能称 Guest 已执行第一条指令。 |
| L399 | 原调度历史编译开关，和 monitor 总开关独立。 |
| L400 | 历史模块也采用同一个 tstamp；复用的是时间点，不是让 monitor 解析历史日志。 |
| L401 | 结束条件编译：`#ifdef CONFIG_SCHED_HISTORY`。 |
| L402 | 原上下文切换调用，作为 selected 打点位置的参照；monitor 不改变切换对象或寄存器。 |

<a id="sched-478"></a>

### current 回到 READY（L478–L481）

```c
L0478:                         vmm_scheduler_set_state_raw(current, VMM_VCPU_STATE_READY);
L0479:                         current->state_tstamp = tstamp;
L0480:                         vmm_monitor_state(current, VMM_VCPU_STATE_READY, tstamp);
L0481:                         rq_enqueue(schedp, current);
```

| 原行号 | 逐行解释 |
|---|---|
| L478 | 原调度器把 current 从 RUNNING 改回 READY。 |
| L479 | 原状态时间戳采用当前调度调用已有的 tstamp。 |
| L480 | 将同一次状态变化和同一个 tstamp 送给 monitor，开始 current 下一轮 READY 等待。 |
| L481 | 原 ready 队列入队；monitor 起点在其前，指标包含到真正选中的等待及邻近调度代码时间，不是独立测量队列数据结构内部耗时。 |

<a id="sched-502"></a>

### next2 选中验证、时间戳与同对象再选中（L502–L525）

```c
L0502:                 BUG_ON(vmm_scheduler_get_state(next, &next_state) != VMM_OK);
L0503:                 if (next_state != VMM_VCPU_STATE_READY) {
L0504:                         vmm_write_unlock_irqrestore_lite(&next->sched_lock, nf);
L0505:                         goto dequeue_again;
L0506:                 }
L0507:                 /*
L0508:                  * The old tstamp is fetched before we acquiring
L0509:                  * next->sched_lock, which means next->state_tstamp may be
L0510:                  * after tstamp. So we need to update tstamp at this point.
L0511:                  */
L0512:                 tstamp = vmm_timer_timestamp();
L0513:                 vmm_monitor_selected(next, tstamp);
L0514:                 arch_vcpu_switch(tcurrent, next, regs);
L0515:         }
L0516: #ifdef CONFIG_SCHED_HISTORY
L0517:         sched_out_tstamp = sched_in_tstamp = vmm_timer_timestamp();
L0518:         if (next == current) {
L0519:                 vmm_monitor_selected(next, sched_in_tstamp);
L0520:         }
L0521: #else
L0522:         if (next == current) {
L0523:                 vmm_monitor_selected(next, vmm_timer_timestamp());
L0524:         }
L0525: #endif
```

| 原行号 | 逐行解释 |
|---|---|
| L502 | 原代码读取 next 实际状态；可发生跨核状态变化，因此不能仅因 dequeue 成功就计 selected。 |
| L503 | 若 next 已非 READY，准备重新取队列对象。 |
| L504 | 释放 next 的调度锁和 IRQ 保存状态。 |
| L505 | 回到 dequeue_again；这条被放弃的对象不执行后面 monitor_selected。 |
| L506 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L507 | 原注释开始，解释为何下面必须刷新时间戳。 |
| L508 | 原先 tstamp 是获取 next 调度锁之前读的。 |
| L509 | next 的 state_tstamp 可能比那个旧 tstamp 更新。 |
| L510 | 因此在锁内刷新时间，避免 READY 时间出现反向差。 |
| L511 | 结束此原始注释。 |
| L512 | 复用原先就需要刷新的时钟值作为选中边界。 |
| L513 | next!=current 的真正选中路径记录 READY 等待终点。 |
| L514 | 随后才执行原 arch_vcpu_switch；selected 不包含这一步之后的完整 Guest 恢复开销。 |
| L515 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L516 | 调度历史开启时复用它原有的时间戳。 |
| L517 | 一次读时钟同时赋给 sched_out_tstamp 和 sched_in_tstamp，原历史功能继续使用。 |
| L518 | 同一对象被再次选中时，不会走前面的 next!=current 分支。 |
| L519 | 补上 same-vCPU 的 selected，复用历史时间戳，避免 READY 标记永远不结束。 |
| L520 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L521 | 未编译历史功能时的替代路径；与上面不会同时执行。 |
| L522 | 同样仅处理 next==current。 |
| L523 | 没有可复用的历史时间戳，才在这里取时间；monitor 宏关闭后该参数表达式也不求值。 |
| L524 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L525 | 结束条件编译：`#ifdef CONFIG_SCHED_HISTORY`。 |

<a id="sched-589"></a>

### switch 共享时间和 scheduled 标记（L589–L594）

```c
L0589: #if defined(CONFIG_CMD_LAT_CTX) || defined(CONFIG_MONITOR_AGENT)
L0590:         u64 t1=0, t2=0;
L0591: #endif
L0592: #ifdef CONFIG_MONITOR_AGENT
L0593:         bool scheduled = FALSE;
L0594: #endif
```

| 原行号 | 逐行解释 |
|---|---|
| L589 | 只要 trace 功能或 monitor 任一开启，就需要共享 t1/t2。 |
| L590 | 共享的调度路径开始/结束时间，初始化0；不是为两个模块各建一套。 |
| L591 | 结束条件编译：`#if defined(CONFIG_CMD_LAT_CTX) &#124;&#124; defined(CONFIG_MONITOR_AGENT)`。 |
| L592 | scheduled 标记只服务 monitor。 |
| L593 | 默认没有实际执行调度，避免仅延期/重启调度定时器也算 dispatch 样本。 |
| L594 | 结束条件编译：`#ifdef CONFIG_MONITOR_AGENT`。 |

<a id="sched-604"></a>

### switch 起点复用（L604–L610）

```c
L0604: #if defined(CONFIG_CMD_LAT_CTX) || defined(CONFIG_MONITOR_AGENT)
L0605:                         /* 点位1: shared by trace and monitor. */
L0606:                         t1 = vmm_timer_timestamp();
L0607: #endif
L0608: #ifdef CONFIG_MONITOR_AGENT
L0609:                         scheduled = TRUE;
L0610: #endif
```

| 原行号 | 逐行解释 |
|---|---|
| L604 | 实际允许切换并取得 current 调度锁后，trace/monitor 任一开启就取点位1。 |
| L605 | 注释明确这一个起点由两个消费者复用。 |
| L606 | t1 是调度选择路径开始；不包含此前等待 current->sched_lock 的时间。 |
| L607 | 结束条件编译：`#if defined(CONFIG_CMD_LAT_CTX) &#124;&#124; defined(CONFIG_MONITOR_AGENT)`。 |
| L608 | 下面标记只在 monitor 编译时存在。 |
| L609 | 标记本次确实要进入调度选取流程。 |
| L610 | 结束条件编译：`#ifdef CONFIG_MONITOR_AGENT`。 |

<a id="sched-629"></a>

### 首次调度起点（L629–L633）

```c
L0629: #ifdef CONFIG_MONITOR_AGENT
L0630:                 t1 = vmm_timer_timestamp();
L0631:                 scheduled = TRUE;
L0632: #endif
L0633:                 next = __vmm_scheduler_next1(schedp, regs);
```

| 原行号 | 逐行解释 |
|---|---|
| L629 | 没有 current 的第一次调度，需要为 monitor 单独设置入口状态。 |
| L630 | 首次选择路径也记录 t1，避免使用默认0作为起点。 |
| L631 | 首次调度也算一次真实的调度执行。 |
| L632 | 结束条件编译：`#ifdef CONFIG_MONITOR_AGENT`。 |
| L633 | 原 next1 选取首个对象，前面已经设好本轮统计起点。 |

<a id="sched-635"></a>

### switch 终点复用和 dispatch（L635–L655）

```c
L0635:         if (next) {
L0636:                 arch_vcpu_post_switch(next, regs);
L0637: #if defined(CONFIG_CMD_LAT_CTX) || defined(CONFIG_MONITOR_AGENT)
L0638:                 /* 点位2: capture once, before either consumer runs. */
L0639:                 t2 = vmm_timer_timestamp();
L0640: #endif
L0641: #ifdef CONFIG_CMD_LAT_CTX
L0642:                 if(current && next != current){
L0643:                         trace_ctx_switch(t2 - t1, current, next);
L0644:                 }
L0645: #endif
L0646:         }
L0647: #ifdef CONFIG_MONITOR_AGENT
L0648:         if (scheduled) {
L0649:                 /* NULL also denotes current selected again, not only deferral. */
L0650:                 if (!next) {
L0651:                         t2 = vmm_timer_timestamp();
L0652:                 }
L0653:                 vmm_monitor_dispatch(next ? next : current, t1, t2);
L0654:         }
L0655: #endif
```

| 原行号 | 逐行解释 |
|---|---|
| L635 | 原调度器确实返回一个 next 时进行切换后处理。 |
| L636 | 原 arch_vcpu_post_switch，dispatch 终点在其后，所以该段开销计入 dispatch。 |
| L637 | trace 或 monitor 启用时取共享终点。 |
| L638 | 先采 t2、再让任一消费者工作，避免一个消费者的处理时间直接推迟另一消费者的终点。 |
| L639 | 保存共同 t2；后面的 trace 输出本身不包括在 t2-t1 内。 |
| L640 | 结束条件编译：`#if defined(CONFIG_CMD_LAT_CTX) &#124;&#124; defined(CONFIG_MONITOR_AGENT)`。 |
| L641 | 原 trace 功能仍受自己的开关控制。 |
| L642 | trace 原规则仅记录存在 current 且发生对象变化的情况。 |
| L643 | 原 trace 接口记录 t2-t1 与 current/next 身份；monitor 不调用它或读取它的历史环。 |
| L644 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L645 | 结束条件编译：`#ifdef CONFIG_CMD_LAT_CTX`。 |
| L646 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L647 | monitor 自己的消费分支。 |
| L648 | 只有 scheduled=true 才提交 dispatch；如果只是禁止抢占而延后调度，此分支跳过。 |
| L649 | next 为空既可能表示原函数同对象再选中，也可能表示延后；因此还要结合 scheduled，而不能单凭 !next 判定。 |
| L650 | 实际执行调度但没有返回 next 时，需要补一个终点。 |
| L651 | 这里读取 t2，覆盖同对象再选中等路径。 |
| L652 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L653 | 有 next 归到 next，无 next 归到 current；记录 b-a。指标归属是实现选择，不表示时间全部由该 vCPU 自身造成。 |
| L654 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L655 | 结束条件编译：`#ifdef CONFIG_MONITOR_AGENT`。 |

<a id="sched-1232"></a>

### state_change 状态提交打点（L1232–L1235）

```c
L1232:                 vmm_monitor_state(vcpu, new_state, tstamp);
L1233:                 state_packed = VCPU_STATE_PACK(vhcpu, new_state);
L1234:                 vmm_scheduler_set_state_packed(vcpu, state_packed);
L1235:                 vcpu->state_tstamp = tstamp;
```

| 原行号 | 逐行解释 |
|---|---|
| L1232 | vmm_scheduler_state_change 确认能提交新状态后通知 monitor。READY 开始等待；其他状态取消等待；RESET/UNKNOWN 触发生命周期清理。 |
| L1233 | 原调度器打包物理核和状态，monitor 没有改此编码。 |
| L1234 | 原状态提交操作；打点在此之前，不是 monitor 接管状态变更。 |
| L1235 | 原状态时间戳更新；与传给 monitor 的同一 tstamp 对齐。 |

**这两项时间并不相同：** READY 是已观察到的 READY→selected；dispatch 是上述 t1→t2 的调度路径耗时。
dispatch 中还包含执行到的其他代码，包括该路径内 monitor_record 的开销；复用 t2 只避免后面的 trace 消费直接推迟终点。
同对象再选中时也可能有很短 READY 样本，count 大于 exit 数并不矛盾。关闭 history 不会关闭 monitor；
关闭 monitor 也不会替你关闭其他需求的 history/trace。

### ARM64 cpu_interrupts.c

参考：[源码](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_interrupts.c>).

<a id="irq-25"></a>

### 异常入口引入宏（L25–L25）

```c
L0025: #include <vmm_monitor.h>
```

| 原行号 | 逐行解释 |
|---|---|
| L25 | 引入退出记录宏；不会代替原异常处理和已有 trap_stat 计数。 |

<a id="irq-101"></a>

### do_sync 的总 exit 点（L101–L104）

```c
L0101: 	vmm_monitor_exit(vcpu, ec);
L0102: 	vmm_scheduler_irq_enter(regs, TRUE);
L0103: 
L0104: 	switch (ec) {
```

| 原行号 | 逐行解释 |
|---|---|
| L101 | do_sync 在排除处理器保存状态表明来自 EL2 的分支后，记录本次 Guest 同步退出。ec 从 ESR 的 EC 位提取；放在 switch 前使每次到达该点只记一次。 |
| L102 | 原调度器异常入口，标记本次为同步异常；它不是 monitor 风暴事件输出函数。 |
| L103 | 空行，分隔声明/逻辑段，不产生指令。 |
| L104 | 原 switch 按 ec 分发仿真/处理。各 case 的 trap_stat 可继续记录分类数量，monitor 只取总次数和最后原因。 |

<a id="irq-221"></a>

### IRQ/FIQ 的来源过滤（L221–L240）

```c
L0221: void do_irq(arch_regs_t *regs)
L0222: {
L0223: 	if ((regs->pstate & PSR_EL_MASK) != PSR_EL_2)
L0224: 		vmm_monitor_exit(vmm_scheduler_current_vcpu(), 0x100);
L0225: 	vmm_scheduler_irq_enter(regs, FALSE);
L0226: 
L0227: 	vmm_host_active_irq_exec(EXC_HYP_IRQ_SPx);
L0228: 
L0229: 	vmm_scheduler_irq_exit(regs);
L0230: }
L0231: 
L0232: void do_hyp_fiq(arch_regs_t *regs)
L0233: {
L0234: 	if ((regs->pstate & PSR_EL_MASK) != PSR_EL_2)
L0235: 		vmm_monitor_exit(vmm_scheduler_current_vcpu(), 0x100);
L0236: 	vmm_scheduler_irq_enter(regs, FALSE);
L0237: 
L0238: 	vmm_host_active_irq_exec(CPU_EXTERNAL_FIQ);
L0239: 
L0240: 	vmm_scheduler_irq_exit(regs);
```

| 原行号 | 逐行解释 |
|---|---|
| L221 | 物理 IRQ 的 C 入口，入参是被打断上下文的寄存器现场。 |
| L222 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L223 | 检查保存的 pstate 所属异常级别，而不是此刻执行 handler 的 EL；被打断的是 EL2 自身时不计 Guest exit。 |
| L224 | 将来自较低 EL 的 IRQ 计入当前 Guest vCPU，原因用人工保留值0x100=256；核心还会过滤非 normal 对象。 |
| L225 | 原调度器 IRQ 入口，FALSE 代表非同步异常路径。 |
| L226 | 空行，分隔声明/逻辑段，不产生指令。 |
| L227 | 原物理 IRQ 分发器继续执行；monitor 记录不屏蔽或注入中断。 |
| L228 | 空行，分隔声明/逻辑段，不产生指令。 |
| L229 | 原 IRQ 退出/调度收尾。 |
| L230 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L231 | 空行，分隔声明/逻辑段，不产生指令。 |
| L232 | 参考源码中的 FIQ C 处理函数；是否真正到达需核对产品向量表，不能仅凭函数存在声称全路径已覆盖。 |
| L233 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L234 | 同样从保存 pstate 过滤 EL2 自身被中断的情况。 |
| L235 | 本实现把该入口也记成0x100，因此不能用 code=256 区分 IRQ 与 FIQ，更不能读成物理 IRQ 编号256。 |
| L236 | 原 FIQ 路径进入调度器的非同步异常记账。 |
| L237 | 空行，分隔声明/逻辑段，不产生指令。 |
| L238 | 原 FIQ 分发继续使用 CPU_EXTERNAL_FIQ；不属于 monitor 新增策略。 |
| L239 | 空行，分隔声明/逻辑段，不产生指令。 |
| L240 | 原调度器中断退出处理。 |

参考 cpu_entry.S 的 EL2/较低EL IRQ 路径最终共用 do_irq；当前参考 C 文件没有独立 do_hyp_irq。
你产品若另分 do_hyp_irq，必须对照实际向量路由保留“一次来自 Guest 的异常只计一次”的条件，不能机械重复两个入口打点。
这里也不能证明 do_hyp_fiq 在产品上必然可达。此前 vgic 的 trap_stat 若记录的是虚拟 IRQ 注入/维护，统计边界与异常入口不同，
不能把一次注入直接替换成一次 exit。已有各 case 分类计数和本总计数可以并存，但不要在同一路径调用两次 monitor_exit。

### ARM64 cpu_vcpu_excep.c

参考：[源码](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_vcpu_excep.c>).

<a id="excep-25"></a>

### abort 文件引入宏（L25–L25）

```c
L0025: #include <vmm_monitor.h>
```

| 原行号 | 逐行解释 |
|---|---|
| L25 | 引入内存故障记录宏；这里只在已有异常分支观察结果。 |

<a id="excep-54"></a>

### stage2_map 原映射失败（L54–L61）

```c
L0054: 	rc = vmm_guest_physical_map(vcpu->guest, inaddr, size,
L0055: 				    &outaddr, &availsz, &reg_flags);
L0056: 	if (rc) {
L0057: 		vmm_monitor_mem_fault(vcpu, VMM_MONITOR_MAP_REJECT, fipa, rc);
L0058: 		vmm_printf("%s: IPA=0x%lx size=0x%lx map failed\n",
L0059: 			   __func__, inaddr, size);
L0060: 		return rc;
L0061: 	}
```

| 原行号 | 逐行解释 |
|---|---|
| L54 | cpu_vcpu_stage2_map 原代码尝试按 Guest 地址空间映射 inaddr，并请求最小页块大小。 |
| L55 | 返回主机地址、可用长度和区域属性；这些参数仍由原映射函数产生。 |
| L56 | 原映射函数非0返回才进入下面记录分支。 |
| L57 | code=2，address 使用原始故障 IPA fipa，detail 是 rc 转成u64后的值；负错误码会显示成很大的无符号整数，应按补码还原。 |
| L58 | 原错误打印保留；monitor 不阻止它输出。 |
| L59 | 原打印采用页对齐的 inaddr 和请求 size，可能与 monitor 保留的未对齐 fipa 不同。 |
| L60 | 原错误码照常返回；没有改成允许映射或重试。 |
| L61 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="excep-126"></a>

### 指令 permission fault（L126–L130）

```c
L0126: 	if ((iss & ISS_ABORT_FSC_MASK) >= FSC_PERM_FAULT_LEVEL0 &&
L0127: 	    (iss & ISS_ABORT_FSC_MASK) <= FSC_PERM_FAULT_LEVEL3)
L0128: 		/* HPFAR is not universally valid for permission faults. Record FAR
L0129: 		 * as a virtual address; ISS.FnV tells consumers when it is invalid. */
L0130: 		vmm_monitor_mem_fault(vcpu, VMM_MONITOR_PERMISSION, mrs(far_el2), iss);
```

| 原行号 | 逐行解释 |
|---|---|
| L126 | 指令 abort 提取 ISS 的 FSC，并检查权限故障范围下界。 |
| L127 | 连同上界判断是否属于 level0..3 的 permission fault。 |
| L128 | 注释提醒不能把这类 fault 的 HPFAR 一概作为有效物理故障地址。 |
| L129 | 此路径保留 FAR 的虚拟地址语义；消费者还须根据 ISS/FnV 判断地址有效性。 |
| L130 | code=4、address=FAR_EL2、detail=ISS；不同于 code=2 的 IPA，JSON 中相同 address 字段具有不同地址空间语义。 |

<a id="excep-152"></a>

### 数据 permission fault（L152–L156）

```c
L0152: 	if ((iss & ISS_ABORT_FSC_MASK) >= FSC_PERM_FAULT_LEVEL0 &&
L0153: 	    (iss & ISS_ABORT_FSC_MASK) <= FSC_PERM_FAULT_LEVEL3)
L0154: 		/* HPFAR is not universally valid for permission faults. Record FAR
L0155: 		 * as a virtual address; ISS.FnV tells consumers when it is invalid. */
L0156: 		vmm_monitor_mem_fault(vcpu, VMM_MONITOR_PERMISSION, mrs(far_el2), iss);
```

| 原行号 | 逐行解释 |
|---|---|
| L152 | 数据 abort 同样先从 ISS 判断 permission fault 下界。 |
| L153 | 补齐上界，只有匹配范围才执行下面记录。 |
| L154 | 数据 abort 权限异常也不统一依赖 HPFAR。 |
| L155 | 保存 FAR 与原始 ISS，解释地址时不能丢掉有效性信息。 |
| L156 | 数据权限异常记录 code=4；随后继续原 data-abort switch，monitor 不另行 halt/reset。 |

正常按需建立二阶段映射的 translation fault 不一定是内存违规；本点在映射函数失败时记录，而非每个 translation fault 都报错。
本参考代码之后的 availsz 不足等其他失败分支没有同一打点，所以不能宣称所有 MMU 失败均记录。
Guest EL1 自己处理的用户指针错误不一定到此；EL2 内任意野指针也不保证经过这些 Guest abort 处理函数。

### core/vmm_shmem.c

参考：[源码](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/vmm_shmem.c>).

<a id="shmem-25"></a>

### shmem 引入宏（L25–L25）

```c
L0025: #include <vmm_monitor.h>
```

| 原行号 | 逐行解释 |
|---|---|
| L25 | 引入内存事件宏；记录版不新增 Guest 授权表或修改原策略。 |

<a id="shmem-41"></a>

### read/write/set 的原拒绝分支（L41–L78）

```c
L0041: u32 vmm_shmem_read(struct vmm_shmem *shm, physical_addr_t off,
L0042: 		   void *dst, u32 len, bool cacheable)
L0043: {
L0044: 	if (!shm || !dst)
L0045: 		return 0;
L0046: 	if (shm->size < (off + len)) {
L0047: 		vmm_monitor_mem_fault(NULL, VMM_MONITOR_SHMEM_BOUNDS, off, len);
L0048: 		return 0;
L0049: 	}
L0050: 
L0051: 	return vmm_host_memory_read(shm->addr + off, dst, len, cacheable);
L0052: }
L0053: 
L0054: u32 vmm_shmem_write(struct vmm_shmem *shm, physical_addr_t off,
L0055: 		    void *src, u32 len, bool cacheable)
L0056: {
L0057: 	if (!shm || !src)
L0058: 		return 0;
L0059: 	if (shm->size < (off + len)) {
L0060: 		vmm_monitor_mem_fault(NULL, VMM_MONITOR_SHMEM_BOUNDS, off, len);
L0061: 		return 0;
L0062: 	}
L0063: 
L0064: 	return vmm_host_memory_write(shm->addr + off, src, len, cacheable);
L0065: }
L0066: 
L0067: u32 vmm_shmem_set(struct vmm_shmem *shm, physical_addr_t off,
L0068: 		  u8 byte, u32 len, bool cacheable)
L0069: {
L0070: 	if (!shm)
L0071: 		return 0;
L0072: 	if (shm->size < (off + len)) {
L0073: 		vmm_monitor_mem_fault(NULL, VMM_MONITOR_SHMEM_BOUNDS, off, len);
L0074: 		return 0;
L0075: 	}
L0076: 
L0077: 	return vmm_host_memory_set(shm->addr + off, byte, len, cacheable);
L0078: }
```

| 原行号 | 逐行解释 |
|---|---|
| L41 | 原共享对象读接口，off 是对象内偏移，不是绝对 HPA。 |
| L42 | dst 是目标地址，len 是字节数，cacheable 传给底层读函数。 |
| L43 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L44 | 空共享对象或空目标先被原接口拒绝。 |
| L45 | 返回读到0字节；这个空指针分支没有 monitor 打点。 |
| L46 | 原范围检查用 off+len；本轮只观察，未换成 range_valid，所以整数相加回绕的原风险仍在。 |
| L47 | code=1，address=off，detail=len；NULL 表示没有可靠 actor，不冒充当前 Guest。 |
| L48 | 按原行为返回0，不实际执行下面物理读。 |
| L49 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L50 | 空行，分隔声明/逻辑段，不产生指令。 |
| L51 | 原有效读路径照常执行；成功读不会发布内存 fault。 |
| L52 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L53 | 空行，分隔声明/逻辑段，不产生指令。 |
| L54 | 原共享对象写接口。 |
| L55 | src 是源缓冲区，len 为字节数；不在 monitor 中复制业务数据。 |
| L56 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L57 | 原空对象/源指针检查。 |
| L58 | 空参数返回0，未打监控点。 |
| L59 | 保留原 off+len 范围判断，存在与读路径相同的算术边界。 |
| L60 | 写越界也用 code=1、off/len；事件中没有额外“读/写”字段，单靠这条 JSON 不能区分 read/write/set。 |
| L61 | 原拒绝返回0。 |
| L62 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L63 | 空行，分隔声明/逻辑段，不产生指令。 |
| L64 | 有效时继续原底层物理写。 |
| L65 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L66 | 空行，分隔声明/逻辑段，不产生指令。 |
| L67 | 原共享对象填值接口。 |
| L68 | byte 是填充值，len 是字节数，cacheable 仍交原底层处理。 |
| L69 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L70 | 空共享对象被原函数拒绝。 |
| L71 | 返回0，不打点。 |
| L72 | 与读/写一致的原范围检查。 |
| L73 | 填值越界用同一个 code=1，归入无 actor 的匿名摘要槽。 |
| L74 | 拒绝返回0。 |
| L75 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L76 | 空行，分隔声明/逻辑段，不产生指令。 |
| L77 | 有效范围才交 vmm_host_memory_set；monitor 不改变原填值行为。 |
| L78 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

注意 `vmm_monitor_range_valid()` 是头文件里的安全算术辅助函数，但这里保留的原代码没有调用它。
“文档里介绍了安全辅助函数”不能替代“生产路径已经使用它”的证据。本次仅如实说明，不修改原策略或检查条件。

### 私有 cpu_hcall.c

参考：[源码](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_observer_from_20261023_v4_20261025/full_files/private_hypervisor/arch/arm/cpu/arm64/cpu_hcall.c>).

<a id="hcall-2"></a>

### CCM hypercall 引入宏（L2–L2）

```c
L0002: #include <vmm_monitor.h>
```

| 原行号 | 逐行解释 |
|---|---|
| L2 | 引入内存记录宏，和本文件的 HVC 分发入口是不同层次。 |

<a id="hcall-845"></a>

### hcall_set_sbuf 参数读取失败（L845–L850）

```c
L0845:         res = vmm_guest_memory_read(vcpu->guest, gpa_sbuf_param, &sp, sizeof(sp), TRUE);
L0846:         if (res != sizeof(sp)){
L0847:                 vmm_monitor_mem_fault(vcpu, VMM_MONITOR_CCM_READ_FAILED,
L0848:                                       gpa_sbuf_param, sizeof(sp));
L0849:                 return VMM_EIO;
L0850:         }
```

| 原行号 | 逐行解释 |
|---|---|
| L845 | hcall_set_sbuf 原代码从调用者 Guest 的 GPA 读取 sbuf_param 结构；res 是读到的字节数。 |
| L846 | 没读全该结构才进入已有失败分支。 |
| L847 | 以发起 hypercall 的 vcpu 作为主体，code=5；不是按 target_vm 归属记录。 |
| L848 | address 是描述符 gpa_sbuf_param，detail 是期望的 sizeof(sp)，不是实际读到的 res。 |
| L849 | 保留原 VMM_EIO 返回；不会因为记录故障而放行注册。 |
| L850 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="hcall-852"></a>

### hcall_set_sbuf 最终注册失败（L852–L862）

```c
L0852:         ret = vmm_guest_physical_map(vcpu->guest, sp.gpa, sizeof(sp), &hpa, &hpa_size, &reg_flags);
L0853:         if (hpa) {
L0854:                 hva = vmm_host_memmap(hpa, VMM_PAGE_SIZE, VMM_MEMORY_FLAGS_NORMAL);
L0855:                 ret = sbuf_setup_common(target_vm, sp.cpu_id, sp.sbuf_id, (u64*)hva, hpa);
L0856:         } else {
L0857:                 ret = VMM_EINVALID;
L0858:         }
L0859:     if (ret != VMM_OK)
L0860:         vmm_monitor_mem_fault(vcpu, VMM_MONITOR_CCM_REGISTER_FAILED,
L0861:                               sp.gpa, (u64)(s64)ret);
L0862:     return ret;
```

| 原行号 | 逐行解释 |
|---|---|
| L852 | 原代码尝试把 sp.gpa 映射成 hpa；本次并未额外验证所有描述符/共享区边界或权限。 |
| L853 | 原有分支仍按 hpa 判断；不能把这行当成 monitor 新增、完备的 ret/hpa 有效性校验。 |
| L854 | 原代码映射到 host VA，尺寸仍使用原来的 VMM_PAGE_SIZE。 |
| L855 | 原注册函数针对 target_vm 调用并返回 ret；monitor 不改变哪个 VM 可以注册的策略。 |
| L856 | 原无可用 hpa 的分支。 |
| L857 | 原错误设为 EINVALID。 |
| L858 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L859 | 最终 ret 非0时才新增失败记录。 |
| L860 | code=6，仍归到调用者 vcpu，而不是把注册目标当故障发起者。 |
| L861 | address 是共享区 sp.gpa；ret 先转 s64 再转 u64，完整保留负错误码的二进制表示。 |
| L862 | 原 ret 原样返回；成功路径不新增故障事件。 |

这两个打点是内存/CCM 失败观察点，不是另一处 exit 总计数。HVC 入口是否已计 exit 属于 cpu_interrupts 路径，
不能在这里再次增加总数。此版本没有新增“仅 serverVM 允许注册”的授权规则，也没有完整审计/加固该私有函数。

### 私有 vmm_u_ioreq.c

参考：[源码](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_observer_from_20261023_v4_20261025/full_files/private_hypervisor/core/vmm_u_ioreq.c>).

<a id="ioreq-2"></a>

### sbuf 文件引入宏（L2–L2）

```c
L0002: #include <vmm_monitor.h>
```

| 原行号 | 逐行解释 |
|---|---|
| L2 | 引入 vmm_monitor_mem_fault 宏与 CCM_ELEMENT_REJECTED 枚举，避免你之前遇到的未声明编译错误。 |

<a id="ioreq-255"></a>

### sbuf_put 元素长度拒绝（L255–L260）

```c
L0255:         } else {
L0256:                 vmm_monitor_mem_fault(NULL, VMM_MONITOR_CCM_ELEMENT_REJECTED,
L0257:                                       0, ((u64)ele_size << 32) | max_len);
L0258:                 ret = U32_MAX;
L0259:         }
L0260:         return ret;
```

| 原行号 | 逐行解释 |
|---|---|
| L255 | sbuf_put 原条件链的失败分支：前面的正常可写路径要求 ele_size<=max_len。缓冲区满且禁止覆盖的更早分支仍可直接返回0，不到这里。 |
| L256 | code=7，NULL 表示原接口没有可靠 vCPU 参数；不猜测 Guest 归属。 |
| L257 | address=0，detail 高32位保存 ele_size、低32位保存 max_len；可分别移位和掩码解析。 |
| L258 | 保留原失败返回 U32_MAX。监控只记录这个已有拒绝，不增加对 head/tail/size 的全面校验。 |
| L259 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L260 | 原函数返回，成功写入或队列满不因 monitor 改变行为。 |

### 私有 cmd_memory.c

参考：[源码](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_runtime_storm_v4_20261026/observer_base/full_files/private_hypervisor/commands/cmd_memory.c>).

<a id="memcmd-9"></a>

### 内存命令依赖（L9–L10）

```c
L0009: #include <vmm_monitor.h>
L0010: #include <vmm_scheduler.h>
```

| 原行号 | 逐行解释 |
|---|---|
| L9 | 引入内存记录与测试适配器声明。 |
| L10 | 引入 current_vcpu 查询，让 host 命令故障归到执行命令的线程对象。 |

<a id="memcmd-303"></a>

### 读范围失败（L303–L311）

```c
L0303:         if (rc) {
L0304:                 if (rc == VMM_ERANGE)
L0305:                         vmm_monitor_mem_fault(vmm_scheduler_current_vcpu(),
L0306:                                               VMM_MONITOR_HOST_RANGE_REJECT,
L0307:                                               addr, (u64)wsz);
L0308:                 return rc;
L0309:         }
L0310:         return VMM_OK;
L0311: }
```

| 原行号 | 逐行解释 |
|---|---|
| L303 | check_read_memory 的原检查返回非0，进入失败出口。 |
| L304 | 只有 ERANGE 这类范围拒绝被本读路径打点；其他 rc 仍返回但不记 code=8。 |
| L305 | 归到当前执行命令的 vCPU/host线程；不以地址所属 Guest 作为执行者。 |
| L306 | code=8，host 命令范围失败。 |
| L307 | address=物理地址 addr；detail=访问宽度 wsz。高32位为0表示读路径。 |
| L308 | 返回原检查错误，不做后续物理读。 |
| L309 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L310 | 原检查通过返回 VMM_OK，不代表已经读取内存。 |
| L311 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="memcmd-333"></a>

### 写分类与 Guest 区域拒绝（L333–L351）

```c
L0333:         rc = check_type_memory(cdev, addr, wsz, io);
L0334:         if (rc) {
L0335:                 vmm_cprintf(cdev, "Accessed an illegal address.\n");
L0336:                 vmm_monitor_mem_fault(vmm_scheduler_current_vcpu(),
L0337:                                       VMM_MONITOR_HOST_RANGE_REJECT,
L0338:                                       addr, (1ULL << 32) | (u64)wsz);
L0339:                 return rc;
L0340:         }
L0341:         if (!(*io)) {
L0342:                 if (!check_guest_addr_range(cdev, addr, wsz, (u32)1)) {
L0343:                         vmm_cprintf(cdev, "This address belongs to the guest and can't be modified.\n");
L0344:                         vmm_monitor_mem_fault(vmm_scheduler_current_vcpu(),
L0345:                                               VMM_MONITOR_ACCESS_DENIED,
L0346:                                               addr, (1ULL << 32) | (u64)wsz);
L0347:                         return VMM_EFAIL;
L0348:                 }
L0349:         }
L0350:         return VMM_OK;
L0351: }
```

| 原行号 | 逐行解释 |
|---|---|
| L333 | check_write_memory 先复用原地址类型检查，区分 RAM/设备或非法区域。 |
| L334 | 地址分类不成功进入已有拒绝分支。 |
| L335 | 保留原串口/命令错误提示，和稍后的 monitor 日志是不同输出。 |
| L336 | 记录当前命令执行者。 |
| L337 | code=8，表示该写请求未通过分类/范围检查。 |
| L338 | detail 高32位=1表示写，低32位=wsz；例如宽度1时为4294967297。address 是 HPA 语义的命令输入。 |
| L339 | 返回原错误，不执行写操作。 |
| L340 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L341 | 原规则只对非设备地址进一步判断 Guest 归属。 |
| L342 | check_guest_addr_range 返回0表示命中 Guest 区域；取反后进入“不能写 Guest”分支。 |
| L343 | 原提示保留。 |
| L344 | 记录当前 host 命令执行线程，不把 guest 字段改成目标地址的所有者。 |
| L345 | code=3，已有访问策略拒绝。 |
| L346 | 地址为被拒绝的物理地址，detail 同样高32位为写、低32位为宽度。 |
| L347 | 原函数仍返回 EFAIL，monitor 不授权写入。 |
| L348 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L349 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L350 | 所有原检查通过才返回 OK。 |
| L351 | 结束与之配对的代码块；本行本身不做额外状态修改。 |

<a id="memcmd-354"></a>

### 测试观察适配器：只执行检查（L354–L378）

```c
L0354: #ifdef CONFIG_WBOXTEST_MONITOR
L0355: /* Test adapter: same policy helpers, no physical mapping/read/write. */
L0356: int vmm_monitor_host_probe(physical_addr_t addr, u32 width, u32 *kind)
L0357: {
L0358:         bool io = FALSE;
L0359:         int rc;
L0360:         if (!kind || (width != 1 && width != 2 && width != 4) ||
L0361:             addr > ~(physical_addr_t)0 - width) return VMM_EINVALID;
L0362:         rc = check_type_memory(NULL, addr, width, &io);
L0363:         if (rc) return rc;
L0364:         *kind = io ? VMM_MONITOR_HOST_DEVICE : VMM_MONITOR_HOST_RAM;
L0365:         if (!io && !check_guest_addr_range(NULL, addr, width, 1))
L0366:                 *kind = VMM_MONITOR_HOST_GUEST;
L0367:         return VMM_OK;
L0368: }
L0369: int vmm_monitor_host_guard(struct vmm_chardev *out, physical_addr_t addr,
L0370:                            u32 width, bool write)
L0371: {
L0372:         bool io = FALSE;
L0373:         if ((width != 1 && width != 2 && width != 4) ||
L0374:             addr > ~(physical_addr_t)0 - width) return VMM_EINVALID;
L0375:         return write ? check_write_memory(out, addr, width, &io) :
L0376:                        check_read_memory(out, addr, width, FALSE);
L0377: }
L0378: #endif
```

| 原行号 | 逐行解释 |
|---|---|
| L354 | 下面仅白盒开关打开时编译，不是新增 shell 命令。 |
| L355 | 适配器只调用相同策略检查，不映射、不读写物理地址。 |
| L356 | probe 检查地址并返回分类，kind 为输出指针。 |
| L357 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L358 | 默认按非设备初始化，原分类函数可改写 io。 |
| L359 | 保存原检查返回码。 |
| L360 | kind 不可空；宽度只接受1/2/4字节。 |
| L361 | 额外防 addr+width 溢出；它属于测试适配器输入保护，不证明所有原命令路径都已有此保护。 |
| L362 | 不输出命令文字地调用原分类函数。 |
| L363 | 分类失败原样返回；这个探测函数不新增监控 fault。 |
| L364 | 把原分类结果转换为测试 HOST_DEVICE 或 HOST_RAM。 |
| L365 | 对 RAM 再查原 Guest 范围，若命中则准备改成 Guest 分类。 |
| L366 | 输出 HOST_GUEST，供测试挑选策略拒绝候选地址。 |
| L367 | 成功返回，但没有真的访问该物理地址。 |
| L368 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L369 | guard 选择原读/写权限路径；out 是测试用输出设备。 |
| L370 | width 为访问宽度，write 是操作方向。 |
| L371 | 进入上方函数或控制语句的代码块；实际行为由块内各行决定。 |
| L372 | 原分类辅助输出变量，初始不是设备。 |
| L373 | 仅接受1/2/4字节访问。 |
| L374 | 检查地址加宽度不会回绕，无效则直接拒绝。 |
| L375 | write 为真时调用真正的原 check_write_memory；会经过它的 monitor 拒绝记录。 |
| L376 | 读分支调用 check_read_memory，并明确按 RAM 检查；不会实际执行 read/write/memset。 |
| L377 | 结束与之配对的代码块；本行本身不做额外状态修改。 |
| L378 | 结束条件编译：`#ifdef CONFIG_WBOXTEST_MONITOR`。 |

## 7. 把各行连起来看：关键例子与边界

### 7.1 一次 READY 延迟怎么得到

假设状态点传入 READY、b=1000 ns，随后 selected 的 a=1600 ns：record 先设 waiting=true、ready_since=1000，
选中后 add(600)，再清 waiting。下一次重复 selected 因没有 waiting 不再加样本。
若第三次 READY 后对象转 PAUSED，则等待被取消，不把“没被选中”伪造为已完成延迟样本。

`ready=[100,20000,90000]` 表示累计100个完成样本、均值20 µs、最大90 µs。
它不是最近一秒100个样本，也不是“最小20 µs、P99 90 µs”。`dispatch` 三项排列相同，测量边界不同。
长时间未选中的对象可在 enabled 时用 ready_age_ns 观察当前等待年龄；它未必已经进入累计均值/max。

### 7.2 为什么 stop 后 status 仍有 JSON

enable(FALSE) 只清 enabled；全局 epoch、事件环和槽快照都保留。dump 使用全局 epoch 过滤槽，而不是要求 enabled=1，
所以能查询停止前历史。timer 仍调 sample，先把旧 memory 摘要入环，再跳过新的窗口计算；drain 还能输出旧事件。
ready_age 在 stop 后显示0，因为它是当前正在采集时的动态年龄，不继续把停止时间算进去。

start 再次从关闭进入开启会换新 epoch；各槽首次打点才清旧 data，查询新 epoch 时未认领的旧槽暂时不显示。
反复 start 而不中间 stop 不会清零。状态 RESET/UNKNOWN 可以在 stop 后清理旧对象。
本实现没有同步等待所有在途打点/采样的“停机屏障”，不能要求 stop 返回瞬间所有核严格不再完成任何记录。

### 7.3 四个配置的范围与作用

| 参数 | 允许范围 | 实际作用 |
|---|---|---|
| exit_limit | 1..1000000000 次/s | 每个 Guest vCPU 的退出速率门限，严格超过才算 high |
| sustain_s | 1..60 s | 同时限制有效高窗口数和实际高窗口持续时间 |
| window_min_ms | 1..1000 ms | 最近实际采样间隔允许的最短长度 |
| window_max_ms | 1000..10000 ms | 最近实际采样间隔允许的最长长度 |

所以 `window_min_ms 1249` 无效，不是因为它和1250的大小关系，而是 min 本身上限1000。
这四项都不改变固定1秒 timer 周期。配置真正变化后，槽下一次采样会丢弃跨配置的窗口，valid=0，再建立新基线。
它不会把已有 active 清掉，因此不能靠持续来回改门限让同一轮告警反复出现。

### 7.4 风暴触发、去重、恢复

limit=100/s、窗口恰好1秒时，101次属于 high，100次不属于。连续5个有效高窗口且累计至少5秒才告警。
若每个窗口都略短于1秒，5个窗口可能仍不足5秒，要继续等；不能只数串口上相隔多少次打印。

触发后 active=true；后续仍超限不会重复 emit。另一个 vCPU 有独立 active，可各自告警。
一个有效低速窗口清 active，未来再次持续高可再告警；无效窗口只清计数，不把风暴判成恢复。
sample 抢锁失败则该槽 previous 未推进，下次可能出现2秒或更长 interval，超过默认1250 ms时 valid=0。
这能解释部分现象，但仅凭全局 skipped 无法定位此前 quiet 阶段偶现失败的具体原因。

### 7.5 JSON 到底能说明什么

| type | code | address | detail | value |
|---|---|---|---|---|
| 1，exit风暴 | 触发窗口最后一次 exit 原因；256来自IRQ/FIQ人工编号 | 0，并非PC | 触发门限，次/s | 触发窗口的整数退出速率 |
| 3，shmem/code1 | 对象范围失败 | 对象内偏移 | 请求字节数 | 本槽该批累计fault条数 |
| 3，map/code2 | 映射函数失败 | Guest IPA | 返回错误码的u64表示 | 同上 |
| 3，access/code3 | 已有策略拒绝 | 本命令中为物理地址 | 高32位写标记、低32位宽度 | 同上 |
| 3，permission/code4 | 已接入的权限abort | FAR虚拟地址，需结合ISS有效性 | ISS | 同上 |
| 3，CCM/code5 | 描述符读取不足 | 描述符GPA | 期望结构字节数 | 同上 |
| 3，CCM/code6 | 注册流程失败 | sp.gpa | 原ret的有符号补码 | 同上 |
| 3，CCM/code7 | 元素长度拒绝 | 0 | 高32位ele_size、低32位max_len | 同上 |
| 3，host/code8 | 内存命令范围/分类拒绝 | 命令物理地址 | 高32位方向、低32位宽度 | 同上 |

type=3 的 value 可混合不同 code/地址，code/address/detail 只代表最后一条；不是逐条无损审计日志。
time_ns/last_ns 是该摘要首次/末次记录时间。type=1 的两者均为判定时间，代码没有存最初超限时刻。
guest/vcpu=4294967295 是“不适用/未知”，不代表第4294967295个虚拟机。
vCPU ID 是管理器ID，不是Guest内部cpu0..N。负ret恢复：若detail≥2^63，按 detail-2^64 解释为s64。

### 7.6 日志已返回、已显示和已存储是三件事

本层全部u64/u32取最大十进制值时，事件JSON加换行和末尾NUL共332字节，可放进384字节栈缓冲区。
但它不限制后端 vmm_lprintf 的缓存长度。你此前见到在 `"cod}`、`"detail"}` 等位置
截断的输出不是合法完整JSON；仅凭本层缓冲区大小无法宣称已解决。后台会提前推进 cursor，再调用日志函数，
没有拿到存储提交确认后再消费的机制。测试 log_returned 也不等于刷盘成功。

events 命令查看仍在16项环内的历史，不清环、不消费日志。lost只计未消费即覆盖，不反映后端截断或磁盘写失败。
status 的 errors 当前只在工作投递和timer重启失败时增加，不是所有内存/exit事件或日志错误总数。

### 7.7 不能由这些代码推导出的保证

- READY/dispatch 当前只做统计，没有延迟阈值告警，也没有P99或抖动直方图。
- monitor观察已有拒绝/异常路径，不改变静态内存划分，不自动创建新内存授权规则。
- 它不能发现所有Guest内部数组越界、未进入EL2的页故障、所有EL2自身野指针或所有未接入的CCM失败。
- 当前选项是命令查看与产品日志；没有独立实现 virtio-serial 或诊断VM共享内存导出协议。
- 采集结构静态；初始化队列/线程可分配。ROM≤5KB、CPU<0.5%仍须用最终产品构建与实测验收，不能从代码短就断言达标。
- 高优先级采集上下文不等于绝对实时：record可能拿slot锁，sample会跳过忙槽；timer失败和关中断都可能影响有效窗口。
- 本篇只解释当前源码，没有修复上述窗口/日志问题，也没有新增重置、限流或屏蔽策略。

## 8. 快速定位与源码身份

### 8.1 函数/片段导航

- [core/include/vmm_monitor.h · 基础定义、配置键与视图 · L1–L16](#header-1)
- [core/include/vmm_monitor.h · 主体声明、内存 code 和 hook · L17–L31](#header-17)
- [core/include/vmm_monitor.h · 生产 API、包装宏与关闭时空桩 · L32–L61](#header-32)
- [core/include/vmm_monitor.h · 嵌入头文件的只读测试观察接口 · L62–L100](#header-62)
- [core/monitor/monitor_agent.c · 依赖和格式化宏 · L1–L16](#core-1)
- [core/monitor/monitor_agent.c · 四类数据结构 · L17–L30](#core-17)
- [core/monitor/monitor_agent.c · 静态存储、配置和执行器对象 · L31–L55](#core-31)
- [core/monitor/monitor_agent.c · emit：发布事件与处理覆盖 · L56–L70](#core-56)
- [core/monitor/monitor_agent.c · memory_flush 与 add：两个小型统计工具 · L71–L79](#core-71)
- [core/monitor/monitor_agent.c · record 前半段：过滤主体和更新生命周期 · L80–L115](#core-80)
- [core/monitor/monitor_agent.c · record 后半段：状态、延迟、exit 与内存摘要 · L116–L146](#core-116)
- [core/monitor/monitor_agent.c · enable：start/stop 为什么不等于清空历史 · L147–L160](#core-147)
- [core/monitor/monitor_agent.c · configure：范围检查与配置版本 · L161–L179](#core-161)
- [core/monitor/monitor_agent.c · sample 第一段：快照、抢锁、配置切换 · L180–L210](#core-180)
- [core/monitor/monitor_agent.c · sample 第二段：有效窗口、超限、去重和恢复 · L211–L246](#core-211)
- [core/monitor/monitor_agent.c · print_event：结构化 JSON 和日志去向 · L247–L261](#core-247)
- [core/monitor/monitor_agent.c · event_get：按序号取仍在环内的事件 · L262–L271](#core-262)
- [core/monitor/monitor_agent.c · drain：每批最多8条日志 · L272–L293](#core-272)
- [core/monitor/monitor_agent.c · dump 前半段：events 与 config 视图 · L294–L318](#core-294)
- [core/monitor/monitor_agent.c · dump 后半段：模块和对象 status · L319–L341](#core-319)
- [core/monitor/monitor_agent.c · report 与 tick：内部执行器 · L342–L361](#core-342)
- [core/monitor/monitor_agent.c · init 与导出符号 · L362–L393](#core-362)
- [core/monitor/monitor_agent.c · 测试观察接口：读取全局状态 · L394–L409](#core-394)
- [core/monitor/monitor_agent.c · 测试观察接口：读取指定槽 · L410–L426](#core-410)
- [core/monitor/monitor_agent.c · 测试观察接口：读取事件和日志回执 · L427–L446](#core-427)
- [core/monitor/monitor_agent.c · 测试观察接口：逐主体与全局采样进度 · L447–L470](#core-447)
- [commands/cmd_monitor.c · 头文件和用法 · L1–L10](#cmd-1)
- [commands/cmd_monitor.c · 解析与分发 · L11–L46](#cmd-11)
- [commands/cmd_monitor.c · 命令注册与认证边界 · L47–L56](#cmd-47)
- [core/monitor/openconf.cfg · 核心、开机采集和日志优先级 · L1–L21](#config-1)
- [core/monitor/openconf.cfg · 默认门限与外部执行器 · L22–L44](#config-22)
- [core/monitor/objects.mk · core/monitor/objects.mk · L1–L1](#objects-1)
- [core/openconf.cfg · core/openconf.cfg 入口 · L172–L172](#coreconfig-172)
- [commands/openconf.cfg · commands/openconf.cfg 命令开关 · L143–L148](#cmdconfig-143)
- [commands/objects.mk · commands/objects.mk 对象入口 · L43–L43](#cmdobjects-43)
- [core/vmm_main.c · vmm_main.c 引入头文件 · L25–L25](#main-25)
- [core/vmm_main.c · vmm_main.c 启动流程接入 · L439–L444](#main-439)
- [产品 core/vmm_scheduler.c · scheduler 头文件 · L24–L24](#sched-24)
- [产品 core/vmm_scheduler.c · next1 首次选中 · L397–L402](#sched-397)
- [产品 core/vmm_scheduler.c · current 回到 READY · L478–L481](#sched-478)
- [产品 core/vmm_scheduler.c · next2 选中验证、时间戳与同对象再选中 · L502–L525](#sched-502)
- [产品 core/vmm_scheduler.c · switch 共享时间和 scheduled 标记 · L589–L594](#sched-589)
- [产品 core/vmm_scheduler.c · switch 起点复用 · L604–L610](#sched-604)
- [产品 core/vmm_scheduler.c · 首次调度起点 · L629–L633](#sched-629)
- [产品 core/vmm_scheduler.c · switch 终点复用和 dispatch · L635–L655](#sched-635)
- [产品 core/vmm_scheduler.c · state_change 状态提交打点 · L1232–L1235](#sched-1232)
- [arch/arm/cpu/arm64/cpu_interrupts.c · 异常入口引入宏 · L25–L25](#irq-25)
- [arch/arm/cpu/arm64/cpu_interrupts.c · do_sync 的总 exit 点 · L101–L104](#irq-101)
- [arch/arm/cpu/arm64/cpu_interrupts.c · IRQ/FIQ 的来源过滤 · L221–L240](#irq-221)
- [arch/arm/cpu/arm64/cpu_vcpu_excep.c · abort 文件引入宏 · L25–L25](#excep-25)
- [arch/arm/cpu/arm64/cpu_vcpu_excep.c · stage2_map 原映射失败 · L54–L61](#excep-54)
- [arch/arm/cpu/arm64/cpu_vcpu_excep.c · 指令 permission fault · L126–L130](#excep-126)
- [arch/arm/cpu/arm64/cpu_vcpu_excep.c · 数据 permission fault · L152–L156](#excep-152)
- [core/vmm_shmem.c · shmem 引入宏 · L25–L25](#shmem-25)
- [core/vmm_shmem.c · read/write/set 的原拒绝分支 · L41–L78](#shmem-41)
- [产品 arch/arm/cpu/arm64/cpu_hcall.c · CCM hypercall 引入宏 · L2–L2](#hcall-2)
- [产品 arch/arm/cpu/arm64/cpu_hcall.c · hcall_set_sbuf 参数读取失败 · L845–L850](#hcall-845)
- [产品 arch/arm/cpu/arm64/cpu_hcall.c · hcall_set_sbuf 最终注册失败 · L852–L862](#hcall-852)
- [产品 core/vmm_u_ioreq.c · sbuf 文件引入宏 · L2–L2](#ioreq-2)
- [产品 core/vmm_u_ioreq.c · sbuf_put 元素长度拒绝 · L255–L260](#ioreq-255)
- [产品 commands/cmd_memory.c · 内存命令依赖 · L9–L10](#memcmd-9)
- [产品 commands/cmd_memory.c · 读范围失败 · L303–L311](#memcmd-303)
- [产品 commands/cmd_memory.c · 写分类与 Guest 区域拒绝 · L333–L351](#memcmd-333)
- [产品 commands/cmd_memory.c · 测试观察适配器：只执行检查 · L354–L378](#memcmd-354)

### 8.2 本篇实际覆盖量

下表“完整行数”是文件实际长度；“解释行数”包含展示片段的空行/括号；原有大文件只解释 monitor 相关片段。

| 文件 | 完整行数 | 解释行数 | 覆盖范围 |
|---|---:|---:|---|
| core/include/vmm_monitor.h | 100 | 100 | 完整文件 |
| core/monitor/monitor_agent.c | 470 | 470 | 完整文件 |
| commands/cmd_monitor.c | 56 | 56 | 完整文件 |
| core/monitor/openconf.cfg | 44 | 44 | 完整文件 |
| core/monitor/objects.mk | 1 | 1 | 完整文件 |
| core/openconf.cfg | 246 | 1 | monitor接入及上下文 |
| commands/openconf.cfg | 329 | 6 | monitor接入及上下文 |
| commands/objects.mk | 71 | 1 | monitor接入及上下文 |
| core/vmm_main.c | 881 | 7 | monitor接入及上下文 |
| 产品 core/vmm_scheduler.c | 1851 | 78 | monitor接入及上下文 |
| arch/arm/cpu/arm64/cpu_interrupts.c | 252 | 25 | monitor接入及上下文 |
| arch/arm/cpu/arm64/cpu_vcpu_excep.c | 201 | 19 | monitor接入及上下文 |
| core/vmm_shmem.c | 245 | 39 | monitor接入及上下文 |
| 产品 arch/arm/cpu/arm64/cpu_hcall.c | 1164 | 18 | monitor接入及上下文 |
| 产品 core/vmm_u_ioreq.c | 457 | 7 | monitor接入及上下文 |
| 产品 commands/cmd_memory.c | 900 | 55 | monitor接入及上下文 |

### 8.3 指纹与路径

文档生成前核对原设计清单中的已知SHA，生成后再次核对所有源文件没有变化。以下哈希用于与你合入的版本对照，不代替产品构建验证。

- **core/include/vmm_monitor.h**
  - 路径：[C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/include/vmm_monitor.h](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/include/vmm_monitor.h>)
  - SHA-256：`b4c4a76ebd6555d39a5ac72884b8d6bd4ab17b93f3e16412714bae79becaad18`
- **core/monitor/monitor_agent.c**
  - 路径：[C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c>)
  - SHA-256：`9f7f3703f209515054467d5b56a6a2de14d07495a9a50ee743cfb1d92e4720c2`
- **commands/cmd_monitor.c**
  - 路径：[C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/commands/cmd_monitor.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/commands/cmd_monitor.c>)
  - SHA-256：`ef1856ebb50738468f81ded512225374caeaec4b3c04c6833000be8b8d3301aa`
- **core/monitor/openconf.cfg**
  - 路径：[C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/openconf.cfg](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/openconf.cfg>)
  - SHA-256：`35e59d3d9c1e6468fd43e8be07b6c959816f5715e5799b9201edae18af57bd9c`
- **core/monitor/objects.mk**
  - 路径：[C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/objects.mk](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/objects.mk>)
  - SHA-256：`de010a9a0cc559630677e83bec108740e5bfd603f97329b0c6bb2b71ceca5e35`
- **core/openconf.cfg**
  - 路径：[C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/openconf.cfg](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/openconf.cfg>)
  - SHA-256：`b3036b5f0a58517e31d01750e99d91800d903cda6aa5fa64a36ec4ef385ba858`
- **commands/openconf.cfg**
  - 路径：[C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/commands/openconf.cfg](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/commands/openconf.cfg>)
  - SHA-256：`39ca772165778cc63fc652b7c12acabb32cc44f8949a3883f8f3ddbfb602eaf4`
- **commands/objects.mk**
  - 路径：[C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/commands/objects.mk](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/commands/objects.mk>)
  - SHA-256：`5e4c2f30daf63be9ed559e022201498fe20a2fe6948a458d109818ae08fbc2a4`
- **core/vmm_main.c**
  - 路径：[C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/vmm_main.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/vmm_main.c>)
  - SHA-256：`adc077a4456c274cb956b3cb53a7992add7615decdbf49df7bb113d18f261cff`
- **产品 core/vmm_scheduler.c**
  - 路径：[C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_scheduler_history_适配_20261022/core/vmm_scheduler.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_scheduler_history_适配_20261022/core/vmm_scheduler.c>)
  - SHA-256：`accd975347050b958acd52233b471c32de4d5db25f46a9203e9f80261ebd7516`
- **arch/arm/cpu/arm64/cpu_interrupts.c**
  - 路径：[C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_interrupts.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_interrupts.c>)
  - SHA-256：`443ef291fa46591cc4395cf3e28a0378349d6df6e7da2170f54e81320f246792`
- **arch/arm/cpu/arm64/cpu_vcpu_excep.c**
  - 路径：[C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_vcpu_excep.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_vcpu_excep.c>)
  - SHA-256：`e3f11f2d26771b8cbf265478ab51b669ec2bb286c7dcb6ca438284453f41d90f`
- **core/vmm_shmem.c**
  - 路径：[C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/vmm_shmem.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/vmm_shmem.c>)
  - SHA-256：`5f97c11fcfaaf4bd943d1c9d746565627a0eaa895bcbbcfc3172d0f11cb482f8`
- **产品 arch/arm/cpu/arm64/cpu_hcall.c**
  - 路径：[C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_observer_from_20261023_v4_20261025/full_files/private_hypervisor/arch/arm/cpu/arm64/cpu_hcall.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_observer_from_20261023_v4_20261025/full_files/private_hypervisor/arch/arm/cpu/arm64/cpu_hcall.c>)
  - SHA-256：`f1462d08904ec52b658bf1224be5a5542d7f6109f9a2cf37d6023e3599e3f14f`
- **产品 core/vmm_u_ioreq.c**
  - 路径：[C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_observer_from_20261023_v4_20261025/full_files/private_hypervisor/core/vmm_u_ioreq.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_observer_from_20261023_v4_20261025/full_files/private_hypervisor/core/vmm_u_ioreq.c>)
  - SHA-256：`5b640eeb26ee67b6f8781dcf507058a19567f3ab3937b5869af516521318374f`
- **产品 commands/cmd_memory.c**
  - 路径：[C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_runtime_storm_v4_20261026/observer_base/full_files/private_hypervisor/commands/cmd_memory.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_runtime_storm_v4_20261026/observer_base/full_files/private_hypervisor/commands/cmd_memory.c>)
  - SHA-256：`6b121aad3624e64d315f4f113d731cbc925c6e6a70165783057dc0f9e2a3a361`

### 8.4 本文的核对方式

对五个自有文件逐一检查每个物理行都有解释；其他选定文件检查每处 vmm_monitor 调用均进入讲解片段。
代码框逐行取自冻结源码，不手抄另一版；重复覆盖或缺少非结构性行解释会使文档生成失败。
这属于文档准确性/完整性检查，没有因为写文档而重新声称已完成板端功能、性能或故障恢复测试。


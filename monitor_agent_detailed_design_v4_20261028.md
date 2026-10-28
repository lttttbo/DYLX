# Monitor Agent 详细设计说明书

版本：v4  
日期：2026-10-28  
适用范围：基于 Xvisor 的 ARM64 Hypervisor，生产运行路径，JSON schema=3。

本文以当前已经交付的 monitor_agent.c、vmm_monitor.h、cmd_monitor.c 及对应接入代码为依据，说明模块如何保存数据、接受打点、周期采样、识别 exit 风暴、发布事件和输出日志。文档围绕生产实现组织，不展开其他辅助功能。

本文区分“设计意图”“当前代码的实际行为”和“依赖产品平台提供的能力”。没有在源码中实现的保证，不作为已实现能力描述。源码定位与版本摘要见附录。

## 1. 设计目标、范围与术语

### 1.1 设计目标

monitor_agent 的职责是观察并记录 Hypervisor 已有运行行为：

1. 统计调度对象的 READY 等待时间和调度路径耗时。
2. 接收已有内存检查、异常处理和 CCM 失败分支提交的记录。
3. 按 Guest vCPU 统计退出次数，在持续超过配置门限时生成风暴事件。
4. 通过命令查看统计与事件，通过产品日志接口输出结构化事件。
5. 支持编译裁剪及运行时启停，使用固定大小的采集数据结构。

monitor 不重新决定内存访问权限，不改变 Guest 的静态内存划分，不改变调度优先级和时间片，也不在风暴告警中新增 vCPU 重置或中断屏蔽策略。原异常处理可能停止 vCPU，那是原处理流程的行为。

### 1.2 当前实现范围

| 项目 | 当前设计中的实现 |
|---|---|
| CPU 调度观察 | Guest、Hypervisor 线程、idle 的 READY/dispatch 累计统计 |
| CPU 延迟阈值 | 当前不提供，按已确认范围保留统计 |
| 内存异常 | 记录已接入的拒绝/失败/权限异常，汇总为内存类摘要 |
| exit 风暴 | Guest vCPU 单独判定，支持持续时间和去重 |
| 周期采样 | 内置模式约每秒一次，Hypervisor 定时器上下文 |
| 日志输出 | 后台工作线程调用 vmm_lwarning |
| 命令输出 | status/events 输出 JSON，config 使用简短文本 |
| 独立诊断 VM 导出协议 | 当前代码没有实现独立的 virtio-serial 或共享内存导出器 |
| 采集存储 | 静态槽数组、静态事件环；内部工作队列在初始化阶段创建 |

内存异常不是通过周期扫描 Guest 内存获得的；调度延迟也不是由后台线程抽样估算。它们在原操作发生时打点，定时采样负责整理已经记录的数据。

### 1.3 术语和时间单位

| 名称 | 本文含义 |
|---|---|
| 调度对象 | Xvisor 的 vCPU 对象，既可能是 Guest vCPU，也可能是 Hypervisor 线程或 idle |
| 记录主体 | 一次打点传入的 vCPU；没有可靠主体时传 NULL |
| 槽 slot | 按 vCPU ID 分配的固定统计单元 |
| epoch | 运行时从关闭切换到开启时产生的采集代号 |
| config_seq | 运行配置版本，配置实际变化时递增 |
| 窗口 | 同一槽两次成功采样边界之间的时间 |
| READY 等待 | 观察到进入 READY，到被选中的区间 |
| dispatch | 产品调度器既有 t1/t2 点之间的调度代码执行区间 |
| exit | 经已接入异常入口记录的 Guest 退出 |
| active | 某 Guest vCPU 的本轮风暴已经告警、尚未观察到有效低速恢复窗口 |
| 时间戳 | vmm_timer_timestamp() 返回的纳秒时间，不是日历时间 |

VMM_MONITOR_NS=1000000000ULL，表示一秒的纳秒数，同时用于当前周期和单位换算。VMM_MONITOR_EVENTS=16，表示事件环容量。

## 2. 模块划分与执行上下文

### 2.1 文件职责

| 文件 | 职责 |
|---|---|
| core/monitor/monitor_agent.c | 数据结构、采集、采样、风暴状态机、事件环、输出、内部执行器 |
| core/include/vmm_monitor.h | 常量、枚举、生产接口、打点宏、关闭时空桩 |
| commands/cmd_monitor.c | 参数解析、命令分发、简短配置反馈 |
| core/monitor/openconf.cfg | 模块编译配置 |
| core/monitor/objects.mk | 按编译开关加入 monitor_agent.o |
| commands/openconf.cfg、objects.mk | 命令配置和构建 |
| core/vmm_main.c | 系统启动时调用模块初始化和命令注册 |
| 调度器、ARM64 异常路径、shmem、CCM、内存命令 | 在原有行为发生处提供输入数据 |

### 2.2 三层执行模型

~~~mermaid
flowchart TD
    A["调度 / Guest 异常 / 内存检查"] --> B["即时记录层：vmm_monitor_record"]
    B --> C["按对象保存的静态槽"]
    C --> D["周期判定层：vmm_monitor_sample"]
    D --> E["静态事件环"]
    E --> F["后台输出层：vmm_monitor_drain"]
    F --> G["产品日志系统"]
    H["monitor status / events / config"] --> I["vmm_monitor_dump"]
    C --> I
    E --> I
~~~

| 层次 | 执行位置 | 主要工作 | 不在该层执行的工作 |
|---|---|---|---|
| 即时记录 | 原调度、异常或检查调用上下文 | 更新计数、时间统计、内存摘要 | 不逐事件打印，不创建动态事件对象 |
| 周期判定 | 内部定时器回调，或平台提供的 HV 定时上下文 | 刷新摘要、计算窗口、判断风暴、发布事件 | 不休眠，不调用日志输出 |
| 后台输出 | monitor 工作队列线程，或平台工作线程 | 把固定数量的事件格式化并调用日志接口 | 不替代原打点采集 |
| 命令查询 | 当前命令执行线程 | 复制数据后输出 | 不消费日志 cursor，不主动制造采样窗口 |

### 2.3 为什么后台优先级 3 仍能观察高优先级对象

调度点记录由调度器直接执行，Guest exit 记录由异常入口直接执行，不要求 monitor 线程先抢占被观察对象。因此日志线程优先级 3 并不把可观察对象限制为优先级不高于 3。

CONFIG_MONITOR_PRIORITY 只影响内部日志工作线程。定时器采样不依靠这个线程获得时间片。但关中断、共享锁竞争、定时器延迟仍会影响时效，不能由执行层次直接推导绝对准点或绝对无丢失。

### 2.4 内部与外部执行器

| 模式 | 初始化动作 | 周期采样来源 | 日志来源 |
|---|---|---|---|
| 内部执行器 | 建立 timer/work/queue 并设置亲和性 | tick() | report() 调用 drain() |
| CONFIG_MONITOR_EXTERNAL_EXECUTOR | 只初始化监控数据和状态，不建立内部执行器 | 产品平台串行调用 sample(now) | 产品平台串行调用 drain() |

外部模式的 sample 必须只有一个串行执行者，drain 也必须只有一个串行消费者。不能同时保留内部执行器又再启动一套外部周期任务。

## 3. 数据结构与所有权

### 3.1 struct latency：累计延迟统计

~~~c
struct latency {
    u64 count;
    u64 sum;
    u64 max;
};
~~~

| 字段 | 含义 | 更新时机 |
|---|---|---|
| count | 完整样本数 | 接受一次有效区间时加一 |
| sum | 所有已接受区间的纳秒总和 | 加上本次区间 |
| max | 最大区间，纳秒 | 本次更大时更新 |

查询时计算 mean=sum/count，count 为 0 时均值为 0。使用整数除法，不保存浮点数。当前没有直方图、P99 或抖动分位数。

这些量是槽生命周期内累计值，不在每秒采样时清零。slot 被复位、删除或进入新 epoch 时才一起清理。计数和总和为普通 u64 累加，没有饱和处理。

### 3.2 struct event：统一事件结构

~~~c
struct event {
    u64 seq, time, last, value, address, detail;
    u32 type, guest, vcpu, epoch, code, config_seq, sustain_s;
};
~~~

| 字段 | 所有权与语义 |
|---|---|
| seq | emit() 赋值，模块事件递增序号 |
| time / last | 内存摘要的首末发生时间；风暴事件两者都是触发采样时间 |
| value | 风暴为触发窗口速率；内存为摘要期间累计次数 |
| address / detail | 根据 type/code 解释的附加信息 |
| type | 当前生产事件使用 1=风暴、3=内存类摘要 |
| guest / vcpu | 记录主体标识；没有对应身份时为 ~0U |
| epoch | 事件归属的采集代号 |
| code | 风暴为最后 exit 原因；内存为监控错误代码 |
| config_seq / sustain_s | 风暴判定使用的配置版本和持续门限；内存摘要当前不填写这些语义，通常为零 |

同一个结构承载不同事件，读取方必须先看 type，再解释 code，最后解释 value/address/detail。

### 3.3 struct data：单主体完整状态

~~~c
struct data {
    struct latency ready, dispatch;
    u64 ready_since, previous, exits, interval, count, sustained;
    u32 epoch, guest, last_exit, windows, config_seq, kind;
    bool present, waiting, active, valid;
    struct event memory;
};
~~~

| 字段 | 具体作用 |
|---|---|
| ready / dispatch | 两组累计延迟 |
| ready_since | 当前被观察到的 READY 起点 |
| previous | 最近一次完成窗口或建立新基线的时间 |
| exits | 当前尚未采样的退出累计数 |
| interval | 最近一次已完成采样窗口长度 |
| count | 最近一次已完成窗口的退出次数 |
| sustained | 当前未告警超限序列累计的有效窗口时长 |
| epoch | 该槽数据所属采集代号 |
| guest | 主体属于哪个 Guest；host/idle 为 ~0U |
| last_exit | 最后一次记录的退出原因，不是分类直方图 |
| windows | 当前未告警超限序列中的窗口数 |
| config_seq | 当前窗口基线所属配置版本 |
| kind | OBJECT_GUEST / OBJECT_HOST / OBJECT_IDLE |
| present | 是否有可呈现的对象数据；不是实时 manager 状态查询 |
| waiting | 是否保存了一段尚未结束的 READY 等待 |
| active | 当前风暴是否已告警且未恢复 |
| valid | 最近退出采样窗口是否满足时长质量范围 |
| memory | 尚未发布的内存错误摘要 |

exits 和 count 刻意分离。每秒采样执行 count=exits、exits=0，使新退出能够继续累加，命令仍能查看上一个窗口结果。

### 3.4 struct slot 与槽索引

~~~c
struct slot {
    vmm_spinlock_t lock;
    struct data d;
};
static struct slot slots[CONFIG_MAX_VCPU_COUNT + 1];
~~~

非 NULL 主体使用 v->id 索引。范围外 ID 被直接忽略。最后一个槽固定用于 NULL 主体，不代表任何实际 vCPU。

槽按全局 vCPU ID 保存，不按物理 CPU 保存。因此对象迁核时无需搬运统计，只要 READY 生命周期通知完整，等待区间可以连续保留。

NULL 槽主要承接无可靠调用主体的 shmem/sbuf 记录。多个共享对象在该槽汇总，不能从槽本身还原共享对象身份。

### 3.5 全局配置、事件环与执行状态

| 对象 | 初值／大小 | 作用 | 同步方式 |
|---|---|---|---|
| ring | 16 个 struct event | 有限事件历史和日志待消费数据 | event_lock |
| head | 0 | 最新已发布事件序号 | event_lock |
| cursor | 1 | 下一个应交给日志输出的事件序号 | event_lock |
| lost | 0 | 未消费即被覆盖的事件数 | event_lock |
| epoch | 0 | 最新运行采集代号 | event_lock 下更新 |
| config.value[] | 编译默认门限、750、1250 | 四项运行参数 | event_lock |
| config.seq | 1 | 配置代号；0 留作槽未建立配置基线 | event_lock |
| initialized | 0 | 初始化是否完成 | 原子量 |
| enabled | 0 | 关闭时为0，开启时保存当前 epoch | 原子量 |
| skipped | 0 | sample 获取某槽锁失败的累计次数 | 原子量 |
| errors | 0 | 执行器调度错误计数 | 原子量 |
| sampler_cpu | 初始化核 | 内部采样/工作线程亲和性信息 | 初始化写入 |
| deadline | 首次预计触发时刻 | 下一次定时器到期基准 | 内部 tick 单执行者 |

enabled 在内部不是单纯布尔变量。它保存有效 epoch；JSON 输出时用双重逻辑取反转换成 0/1。

### 3.6 各种数据何时清理

| 数据 | 清理／推进时机 |
|---|---|
| ready/dispatch | 对象 RESET/UNKNOWN 或槽发现新 epoch |
| 当前 exits | 成功采样后清零；跨配置窗口丢弃时清零 |
| count/interval | 每次采样替换；新配置基线时置零 |
| windows/sustained | 有效低速、无效窗口、配置基线切换、槽复位 |
| active | 有效低速或槽整体复位；无效窗口和单纯改配置不主动清除 |
| memory.value | 发布摘要后清零；下一次错误重新建立摘要时间 |
| ring/head/cursor/lost | 不随每次 start 或配置修改整体清空 |
| skipped/errors | 不随每次 start 清零 |

## 4. 初始化与运行生命周期

### 4.1 vmm_monitor_init() 的函数设计

签名：

~~~c
int __init vmm_monitor_init(void);
~~~

调用者为系统启动流程，设计为一次性初始化。它不是支持任意时刻重复调用的 reset 接口，没有实现重复初始化已有工作队列的幂等处理。

内部执行器模式的步骤：

1. 初始化所有槽的自旋锁，包括 NULL 槽。
2. 保存当前物理核为 sampler_cpu。
3. 初始化静态工作项 work，回调为 report。
4. 初始化静态定时器 timer，回调为 tick。
5. 创建名称为 monitor 的工作队列，线程优先级为 CONFIG_MONITOR_PRIORITY。
6. 将工作线程亲和性设置为 sampler_cpu。
7. 读取时间，设置 deadline=now+1秒，启动首次定时器。
8. 写屏障后把 initialized 置1。
9. 若编译选择开机采集，则调用 vmm_monitor_enable(TRUE)。

| 失败点 | 返回与清理 |
|---|---|
| 工作队列创建失败 | 返回 VMM_ENOMEM |
| 线程亲和性设置失败 | 销毁刚创建的工作队列，返回原错误 |
| 首次定时器启动失败 | 销毁工作队列，返回原错误 |
| 全部成功 | initialized=1，返回 VMM_OK |

外部执行器模式跳过第3～7步；平台随后负责执行周期采样和日志消费。

### 4.2 系统启动接入

vmm_main.c 的 system_init_work() 在 IOMMU 初始化后、模块初始化前调用监控初始化。只有监控初始化成功，才尝试注册 monitor 命令。

失败时打印 monitor_agent unavailable，继续原系统初始化，不把可选监控失败转成直接的 Guest 启动失败。

如果监控本体初始化成功但命令注册失败，当前接入代码没有反向销毁已启动的监控执行器；应区分“监控未启动”与“命令未注册成功”。

### 4.3 vmm_monitor_enable() 与 epoch

签名：

~~~c
int vmm_monitor_enable(bool on);
~~~

未初始化返回 VMM_ENOTAVAIL。初始化完成后，在 event_lock 下更新开关：

~~~text
on=false：
    enabled = 0

on=true 且 enabled==0：
    epoch += 1；若回绕到0，再递增一次
    enabled = epoch

on=true 且已经开启：
    保持原 epoch，不重置统计
~~~

不在 start 命令中遍历并锁定所有对象。这样避免一次 start 长时间关中断清空所有槽。

### 4.4 懒清理如何保证新一轮统计

每次 record 取得槽锁后，重新读取 enabled 为 run。如果 d.epoch != run，就先发布旧内存摘要，再清空 struct data，设置新 epoch 和 previous。

这意味着新一轮 start 后，一个尚未发生新打点的旧槽不会立刻产生新数据。status 按 epoch 过滤，所以短时间内可能看不到该对象，而不是伪造一条从 start 瞬间开始的完整统计。

新 epoch 的首个打点如果是 selected、却没有新的 READY 起点，不能生成 READY 等待样本。这是从运行中途开启采集的自然边界。

### 4.5 stop 的准确语义

stop 关闭正常新增采集，不销毁 timer、queue 或历史事件，也不清空延迟累计值。

已经进入的 record 可能在并发边界完成；sample 在入口读取 run 后，期间发生 stop，也可能完成这一轮。stop 没有等待所有并发采集器退出的全局屏障。

此外，已经积累的内存摘要仍可被 sample 刷入事件环，后台日志仍可继续消费。这些是停用前数据的收尾，不等于开启了新的正常采集。

因此 status/events 在 stop 后仍可读取保留结果；ready_age_ns 在停用时输出0，避免把已冻结的等待继续按当前时间增长。

### 4.6 RESET 与 UNKNOWN 的生命周期处理

当 hook=MON_STATE 且状态为 RESET/UNKNOWN，记录器将其识别为 reset。即使正常采集关闭，这类生命周期通知仍允许处理，前提是已经初始化。

处理顺序为：发布旧内存摘要、清空槽、写入当前运行代号与时间、重新标记身份。UNKNOWN 令 present=false；RESET 不等于删除对象。

该机制防止 vCPU ID 复用或复位后继承旧对象统计。它依赖产品原生命周期路径确实调用已接入的状态通知，不是后台主动扫描 manager 对象列表。

~~~mermaid
stateDiagram-v2
    [*] --> Uninitialized
    Uninitialized --> Disabled: init 成功
    Disabled --> Enabled: start / 新 epoch
    Enabled --> Enabled: 重复 start
    Enabled --> Disabled: stop
    Disabled --> Disabled: status/events 可查询保留数据
~~~

图中的状态只描述采集开关；停止采集后执行器与日志消费仍可能存在。

## 5. vmm_monitor_record()：统一即时采集

### 5.1 接口契约

~~~c
void vmm_monitor_record(struct vmm_vcpu *v, u32 hook, u64 a, u64 b);
~~~

| 参数 | 要求 |
|---|---|
| v | 当前调用期间有效的 vCPU 指针；指定内存类接口允许 NULL |
| hook | 使用头文件规定的内部操作号 |
| a、b | 按 hook 编码的数据，见下一表 |

函数无返回值，前置条件不满足时直接忽略。它是 Hypervisor 内部受信任接口，不接收用户任意 hook 值。当前 switch 的 default 被用作内存事件分支，没有对任意未知 hook 建立独立错误返回。

### 5.2 打点宏与参数编码

| 宏 | hook | a | b |
|---|---|---|---|
| vmm_monitor_state(v,s,t) | MON_STATE | new_state | 原状态时间戳 |
| vmm_monitor_selected(v,t) | MON_SELECTED | 选中时间戳 | 0 |
| vmm_monitor_dispatch(v,a,b) | MON_DISPATCH | 起点 | 终点 |
| vmm_monitor_exit(v,r) | MON_EXIT | 退出原因 | 0 |
| vmm_monitor_mem_fault(v,k,a,d) | MON_FAULT+k | 地址/偏移 | 附加信息 |

公共宏把调用点与数据存储分离，调用点只需提供事实和时间，无需理解事件环、JSON 或日志线程。

### 5.3 快速过滤与锁内复查

进入函数先检查：

1. initialized 是否为真。
2. enabled 是否开启；RESET/UNKNOWN 例外。
3. 非 NULL vCPU ID 是否小于 CONFIG_MAX_VCPU_COUNT。
4. 正常 Guest vCPU 是否具备 guest 指针。
5. MON_EXIT 是否来自正常 Guest vCPU。
6. NULL 主体是否错误使用了调度或 exit 操作。

通过后取得对应槽锁，再次读取 enabled。第二次检查用于缩小“外层检查之后用户执行 stop”的竞争窗口。

它仍不是与 stop 完全串行化的强屏障：record 只持槽锁，不在整个更新期间持 event_lock。文档不把它描述为 stop 返回后绝不可能完成任何在途更新。

### 5.4 主体分类

正常 vCPU：kind=OBJECT_GUEST，guest=v->guest->id。

非正常 vCPU：guest=~0U，通常 kind=OBJECT_HOST。若对象等于当前核的 idle_vcpu，则标为 OBJECT_IDLE。已经识别出的 idle 身份在其他核通知该槽时保持，避免远程状态通知把它改成普通 host。

分类只读取无调度锁的 idle 指针接口。打点调用者可能已持有调度锁，不能在记录器里再次通过会取得相同调度锁的查询形成反向依赖。

### 5.5 主处理流程

~~~mermaid
flowchart TD
    A["record(v,hook,a,b)"] --> B{"前置过滤通过？"}
    B -- 否 --> Z["返回"]
    B -- 是 --> C["取得对应槽锁；再次读取 enabled"]
    C --> D{"允许正常记录或属于生命周期通知？"}
    D -- 否 --> Y["释放槽锁"]
    D -- 是 --> E{"reset 或 epoch 已变化？"}
    E -- 是 --> F["刷新旧内存摘要；清空槽；建立新基线"]
    E -- 否 --> G["更新主体身份"]
    F --> G
    G --> H["按 hook 更新状态、延迟、退出数或内存摘要"]
    H --> Y
    Y --> Z
~~~

record 不创建独立线程，不打印，也不直接持久化。正常更新触及一个槽；需要发布旧摘要时会进一步取得 event_lock，因此它不是无锁路径。

## 6. 调度数据的统计设计

### 6.1 MON_STATE：建立与取消 READY 等待

当 a=READY：

~~~text
如果 waiting=false：
    ready_since=b
waiting=true
~~~

当 a 为其他状态：waiting=false。

重复 READY 不刷新起点，因此一次长等待不会因为重复状态通知而被截成很短的等待。PAUSED/HALTED 等状态取消等待，避免把对象主动阻塞期间的时间累加为就绪等待。

RESET/UNKNOWN 在进入 switch 之前还会清空整个槽。普通暂停只取消当前等待，不清空已经完成的历史统计。

### 6.2 MON_SELECTED：形成一个完整等待样本

~~~text
如果 waiting=true 且 a>=ready_since：
    add(ready, a-ready_since)
waiting=false
~~~

一段等待只有在被选中时才形成完整样本。缺少起点、重复 selected 或时间反向时都不会增加样本。即使时间反向，waiting 仍会清除，不让损坏的旧起点继续污染后续选择。

长期 READY 但一直未被选中的对象，其等待仍在进行，不会立刻体现在 ready.max 中。查询时用 ready_age_ns 表示这段未完成等待。

### 6.3 MON_DISPATCH 与 add()

MON_DISPATCH 只在 b>=a 时调用 add(&d->dispatch, b-a)。

add() 是常数步骤的累计函数：

~~~c
s->count++;
s->sum += ns;
if (ns > s->max)
    s->max = ns;
~~~

add() 本身不取锁，依赖调用者已取得对应槽锁。它不保存原始样本列表，不筛除特别大的正耗时，也不判断是否达到某个延迟告警阈值。

### 6.4 与产品调度器的时间边界

产品调度器适配复用原时间戳和 t1/t2：

| 输入 | 产品接入点 | 设计依据 |
|---|---|---|
| READY 起点 | 成功状态提交、RUNNING 重新变 READY 入队 | 两条逻辑就绪路径都要通知 |
| selected 终点 | 首次选择、不同目标选择、同目标重选 | 不遗漏同一个 vCPU 被立即选回 |
| dispatch 起点 | 外层 switch 中实际开始选择前的 t1 | 复用原 trace 点 |
| dispatch 终点 | post_switch 后的 t2；同目标重选单独补终点 | 一个调度区间只记一次 |

适配通过 scheduled 标志区分“本次没执行调度”与“执行了调度但还是选回 current”。因为两种情况 next 都可能为 NULL，只看 next 会丢样本或误计数。

dispatch 是产品 C 调度路径测量，不是 Guest 获得唤醒请求到第一条 Guest 指令执行的完整端到端时间。READY 与 dispatch 的部分区间可能重叠，不能把两者均值直接相加。

原 history/trace 与 monitor 可共享计时点，但各自数据独立。monitor 不读取 history 环，也不在 CPU/vCPU 双份 history 写入处重复计数。

### 6.5 对外呈现

~~~text
ready    = [count, floor(sum/count), max]
dispatch = [count, floor(sum/count), max]
~~~

单位均为纳秒，count 除外。这是累计统计，不是最近一秒的延迟均值。当前没有调度延迟事件 type，也没有自动日志告警。

## 7. 内存类摘要的采集与发布

### 7.1 MON_FAULT+k 的更新逻辑

内存类宏把 k 编码到 hook。进入 record 的 default 后：

1. 读取当前纳秒时间，保存到 memory.last。
2. 若 memory.value 为0，同步设置 memory.time=memory.last。
3. memory.value 加一。
4. 填入 type=3、主体 ID、epoch。
5. code=hook-MON_FAULT。
6. address=a，detail=b。

与 CPU 延迟不同，内存事件时间由记录器读取；调用点提供的是地址/偏移和失败信息。

### 7.2 聚合键是什么

聚合键只有“槽”，即 vCPU ID 或 NULL 槽。当前没有按 code、address、共享对象分别分桶。

同一槽在刷新前先发生映射失败，再发生参数读取失败，最终事件的 value 是两者总次数，code/address/detail 保留最后一次参数读取失败。

因此：

- value 不是最后一个 code 的精确分类次数。
- time/last 能描述摘要的首末时间，但不能还原中间每一次发生时间。
- 不能从 NULL 槽摘要恢复具体共享对象或发起 Guest。
- 首条发生后、下一次刷新前的其他错误无需创建新的事件结构。

这样的设计控制了静态存储和热路径开销，也牺牲了逐条根因明细。

### 7.3 memory_flush() 的函数设计

~~~c
static void memory_flush(struct data *d);
~~~

调用者已经持有对应槽锁。memory.value 非0时，调用 emit(&memory) 发布摘要，再把 memory.value 清零。

它不清空 entire memory 对象。下一次记录在 value=0 的条件下重写首时间，其余实际使用字段也由新记录覆盖。

主要调用位置：

| 位置 | 目的 |
|---|---|
| 周期 sample 取得槽锁后 | 定期发布已发生的错误 |
| record 发现 RESET/UNKNOWN | 在旧主体统计清理前保存摘要 |
| record 发现新 epoch | 在进入新采集代号前保存旧摘要 |

内存事件不受风暴配置版本检查限制，emit 的配置失效过滤只针对 type=1。memory_flush 不意味着持久化完成，只意味着发布到事件环。

### 7.4 内存错误代码与事实来源

| code | 输入路径 | address | detail | 直接表达的事实 |
|---:|---|---|---|---|
| 1 | shmem read/write/set 原越界分支 | 对象内偏移 off | len | 原接口拒绝越界范围 |
| 2 | 基本页 vmm_guest_physical_map 失败 | fipa，IPA 语义 | 原 rc | 映射查询失败 |
| 3 | 内存命令原 Guest 写保护 | HPA | 写标志/访问宽度 | 原命令规则拒绝写入 |
| 4 | Guest 取指/数据权限 abort | FAR_EL2 | ISS | 命中已接入权限错误分类 |
| 5 | CCM 参数读取不完整 | 参数结构 GPA | 期望长度 | 参数读取失败 |
| 6 | CCM sbuf 注册最终失败 | sp.gpa | 最终 ret | 原注册流程失败 |
| 7 | sbuf_put 原元素尺寸拒绝 | 0 | ele_size/max_len | 元素描述长度超过本次可提供长度 |
| 8 | 内存命令范围/分类拒绝 | HPA | 读写标志/访问宽度 | 原访问检查失败 |

code=3/8：detail 高32位为写标志，低32位为宽度。code=7：高32位为 ele_size，低32位为 max_len。code=2/6：负错误码可能按 u64 无符号十进制输出。

这些 code 不是同一种物理地址错误，也不能全部解释成“已经证明越权”。特别是 CCM 注册失败可能只是 sbuf_id 不受支持。

### 7.5 为什么不会替代原内存保护

record 不查询域所有权、不重建页表、不阻止访问、不更改原返回码。是否发生拒绝由原接入点决定。

以下情况不在这套摘要本身的保证范围内：

- Guest 内部处理且没有进入已接入 EL2 路径的错误。
- 合法映射内部的数组、缓冲区或软件对象越界。
- 绕过 shmem 接口的直接共享页访问。
- 原拒绝条件未覆盖或因算术边界而漏掉的输入。
- 没有单独接入的 Hypervisor 普通指针异常和设备 DMA 故障。

权限事件当前没有单独保存 EC、异常 PC 或取指/读/写子类型；FAR 不应直接当作宿主物理地址。

### 7.6 内存事件的频率语义

内存记录没有持续五秒才触发的门限，也没有风暴 active 去重。它在采样时把当期摘要发布出来。

同一错误持续发生时，多个采样周期可能持续产生摘要；这是分周期汇总，不是跨周期只提醒一次。内存聚合与 exit 风暴去重是两个不同机制。

## 8. vmm_monitor_sample()：周期汇总算法

### 8.1 接口与调用约束

~~~c
void vmm_monitor_sample(u64 now);
~~~

now 使用与 record 相同的纳秒时间基准。函数必须由单个周期执行者串行调用。它不会自己创建下一次调度；内部模式由 tick 负责重新启动定时器。

函数不打印、不休眠，不分配监控数据。遍历上限为 CONFIG_MAX_VCPU_COUNT+1，与已配置最大对象数有关，不只与当前运行 Guest 数有关。

### 8.2 为什么先复制配置

函数开始读取 enabled 为 run，再在 event_lock 下复制整个 config 为局部 cfg，释放锁后才遍历槽。

这样一个采样批次使用一致的配置快照，也避免拿着 event_lock 再逐个等待槽锁。配置如果在批次中变化，最终发布风暴事件时还会重新核对版本。

now 是本批次统一参考时刻。各槽实际取得锁和冻结计数的时刻并不完全相同，所以这不是所有 vCPU 的硬件原子同步快照。

### 8.3 每个槽的处理顺序

~~~text
尝试取得槽锁
    失败：skipped++，处理下一槽

刷新该槽旧内存摘要

run 为0 / epoch 不符 / present 为假
    跳过后续窗口计算

处理配置基线
    不匹配：丢弃混合退出窗口，建立新基线，处理下一槽

计算 interval，冻结退出 count，清零当前 exits
根据窗口上下限得到 valid
    无效：清空连续超限窗口和时长，处理下一槽

非 Guest 主体
    不进入风暴判定

Guest 风暴判定与可能的 emit
释放槽锁
~~~

内存摘要刷新位于 run/epoch/present 检查之前，这是 stop 后仍能输出已采集内存事件的原因。

### 8.4 trylock 与 skipped

sample 使用 vmm_spin_trylock_irqsave() 取得槽锁。失败直接跳过，不为这一槽忙等；skipped 递增一次。

该槽的 exits 不会因为被跳过而清零，previous 也不推进。以后成功采样时，窗口变长，次数包括更长的累计区间。

skipped 是全局所有槽尝试的累计数，不包含哪个槽、哪个核的信息。不能用它单独判断一个具体 Guest 的采样是否停滞。

trylock 只应用在槽锁；复制配置和发布事件仍会取得 event_lock。因此不能将整个 sample 描述为完全无等待或无锁。

### 8.5 配置基线分支

若 d.config_seq=0 且全局 cfg.seq=1，直接令 d.config_seq=1。这允许初始默认配置下的槽按自身创建时间进入正常采样。

否则当 d.config_seq != cfg.seq：

~~~text
d.config_seq = cfg.seq
d.previous = now
d.interval = d.count = d.exits = d.sustained = 0
d.windows = 0
d.valid = false
~~~

然后结束该槽的本轮处理。ready/dispatch、waiting、ready_since 和 active 不在这里清空。

目的：不把一部分在旧门限下累计、一部分在新门限下累计的退出数拿来进行新的连续判断。代价是主动丢弃这个混合窗口的退出计数；这不计入事件环的 lost。

### 8.6 窗口冻结与有效性

~~~c
d->interval = now >= d->previous ? now - d->previous : 0;
d->previous = now;
d->count = d->exits;
d->exits = 0;
~~~

随后：

~~~text
valid =
    interval >= window_min_ms × 1,000,000
    且
    interval <= window_max_ms × 1,000,000
~~~

默认范围为750～1250ms，包含两个边界。now 早于 previous 时使用0间隔，从而被判无效，避免无符号减法变成巨大时间。

无效窗口仍可显示 interval/count，但不用于持续风暴判断。它清空 windows/sustained，保留 active，原因见下一章。

valid 只描述这份退出窗口的时长质量，不是对延迟累计、内存事件、系统运行状态的统一“正常”证明。

### 8.7 采样流程图

~~~mermaid
flowchart TD
    A["读取 run，复制 cfg"] --> B["遍历槽"]
    B --> C{"trylock 成功？"}
    C -- 否 --> D["skipped++"]
    C -- 是 --> E["memory_flush"]
    E --> F{"run、epoch、present 有效？"}
    F -- 否 --> N["解锁并继续"]
    F -- 是 --> G{"配置基线匹配？"}
    G -- 否 --> H["丢弃混合窗口，保留 active"]
    H --> N
    G -- 是 --> I["冻结 interval/count，清零 exits"]
    I --> J{"窗口 valid？"}
    J -- 否 --> K["清空连续累计，保留 active"]
    K --> N
    J -- 是 --> L{"Guest 主体？"}
    L -- 否 --> N
    L -- 是 --> M["风暴判定"]
    M --> N
    D --> B
    N --> B
~~~

图中遍历在固定数组结束后返回，不是无限执行。

## 9. exit 风暴判定与配置更新

### 9.1 原始退出流

MON_EXIT 更新 d.exits 和 d.last_exit。采样只对 kind=OBJECT_GUEST 进行风暴判定，host/idle 的调度活动不会成为 Guest exit 流。

当前有效参考接入包含 do_sync 的 Guest 同步异常和 do_irq 中来自 Guest 上下文的 IRQ。do_hyp_fiq 虽有调用代码，但当前参考异常向量没有调用该函数，不能计为已接通的 FIQ 覆盖。

VGIC 的 LR 写入计数不能替换这个入口计数：它描述向 Guest 提交虚拟中断，次数与 Guest 退出不一定一一对应。

### 9.2 单窗口超限公式

设 R 为 exit_limit，N 为本窗口 count，T 为 interval_ns：

~~~text
high = N > floor(R × T / 1,000,000,000)
~~~

比较严格大于。若 T 恰好一秒，N=R 不超限。若窗口略短于一秒，即使 N=R，实际速率仍可能略大于 R，从而满足条件。

事件输出速率使用 floor(N×1e9/T)。因为比较和展示分别进行整数运算，极接近阈值时，输出 value 可能恰好等于 detail，即使精确速率已经略高于门限。不能仅凭两个显示整数相等判定算法错误。

### 9.3 连续条件

未处于 active 且本窗口 high 时：

~~~text
windows += 1
sustained += interval
~~~

只有同时满足：

~~~text
windows >= sustain_s
且 sustained >= sustain_s × 1秒
~~~

才产生事件。

窗口数量门限对应当前一秒周期设计，实际时长门限防止偏短窗口使“5个窗口”少于5秒。如果以后改变采样周期，不能只改定时器，还要重新设计 windows 门限和有效区间。

例如 sustain_s=5，每个有效窗口都是0.9秒，则五个窗口只有4.5秒，不触发；第六个仍超限时才满足5.4秒。相反，某个窗口2秒默认无效，不会被直接用来凑满持续时间。

### 9.4 状态转换

| 当前输入／状态 | windows/sustained | active | 是否新事件 |
|---|---|---|---|
| 有效、不超限 | 清零 | false | 否 |
| 有效、超限、尚未 active | 累加 | 条件满足且 emit 成功后 true | 条件满足时 |
| 有效、超限、已 active | 不继续推进本轮触发累计 | 保持 true | 否 |
| 无效窗口 | 清零 | 保持原值 | 否 |
| 配置基线切换 | 清零 | 保持原值 | 否 |
| 槽 RESET/新 epoch | 随槽清零 | false | 否 |

无效窗口意味着缺少可靠证据，不等于观察到速率下降。因此不能用它解除 active，否则采样抖动会造成重复告警。

### 9.5 告警事件如何填写

| event 字段 | 内容 |
|---|---|
| type | 1 |
| guest/vcpu/epoch | 当前槽和采样代号 |
| time、last | now，达到触发条件的采样边界 |
| value | 触发窗口的归一化整数速率 |
| detail | cfg 中的 exit_limit |
| sustain_s | cfg 中的持续门限 |
| config_seq | 本次 cfg.seq |
| code | d.last_exit，最后一次退出原因 |
| address | 0，当前风暴不保存访问地址 |

value 不是整段超限时长的平均值或峰值。code 不是主要退出原因，更不是故障根因。time 不记录首次超限发生时刻。

emit 成功返回 TRUE 后，active 置真。若配置版本已经过期而 emit 返回 FALSE，active 仍为假，不把未发布事件误当成已完成告警。

### 9.6 vmm_monitor_configure() 的函数设计

~~~c
int vmm_monitor_configure(u32 key, u32 value);
~~~

未初始化返回 VMM_ENOTAVAIL。键或取值超出范围返回 VMM_EINVALID，合法时在 event_lock 下更新配置。

| key | 范围 | 默认值 | 单位 |
|---|---|---:|---|
| VMM_MONITOR_EXIT_LIMIT | 1～1000000000 | CONFIG_MONITOR_EXIT_RATE，默认50000 | 次/秒 |
| VMM_MONITOR_SUSTAIN_S | 1～60 | CONFIG_MONITOR_STORM_SECONDS，默认5 | 秒 |
| VMM_MONITOR_WINDOW_MIN_MS | 1～1000 | 750 | 毫秒 |
| VMM_MONITOR_WINDOW_MAX_MS | 1000～10000 | 1250 | 毫秒 |

设置成与当前相同的值，不增加 config.seq。实际变化时递增，跳过0。

每次接口调用只修改一个参数，不提供多参数原子事务。连续修改两个参数会产生两个配置版本；采样可能看到中间版本，但不会把一个版本里的四个字段读成撕裂快照。

### 9.7 为什么同时需要基线切换和 emit 版本复查

基线切换处理“采样开始前已修改配置”的情形。emit 复查处理“采样使用旧快照做完计算、发布前配置又变化”的情形。

~~~mermaid
sequenceDiagram
    participant S as sample
    participant C as configure
    participant E as emit
    S->>S: 复制配置版本7
    C->>C: 发布配置版本8
    S->>S: 按版本7得到超限结果
    S->>E: 提交 type=1/config_seq=7
    E->>E: 当前版本是8
    E-->>S: FALSE，不写入事件环
~~~

emit 只做配置代号复查，没有同时复查 enabled/epoch。因此 start/stop 并发边界不具有与配置相同的发布取消保证，应按生命周期章节理解。

### 9.8 同一事件不重复提醒的含义

去重维度是一个 Guest vCPU 的连续超限过程。不是全系统只报一次，也不是同一个 code 永久只报一次。

有多个 Guest vCPU 同时超限，就会分别产生事件。某个 vCPU 观察到有效低速窗口后恢复，再次满足持续超限条件，可产生新的事件。

修改阈值、查询 events、最后原因从 HVC 变成 IRQ，都不会单独构成一次“已恢复”。低速窗口才是 active 解除的正常依据。

## 10. 事件环设计

### 10.1 有限历史与日志待消费区共用一套存储

ring 既保存可供 events 查询的最近历史，又保存尚未交给日志的事件。两者通过 head 与 cursor 区分，而不是各存一份副本。

~~~text
head：最新发布序号
cursor：下一条待交给日志的序号
可查询历史：max(1, head-15) ... head
尚待日志消费：cursor ... head
~~~

已经消费过的事件仍可能位于环内，因此 events 能反复看到它。消费日志不清空该项。

### 10.2 emit() 的函数设计

~~~c
static bool emit(struct event *e);
~~~

输入为已经填写主体和业务字段的事件。函数取得 event_lock：

1. type=1 时检查事件 config_seq 是否仍等于当前 config.seq；过期返回 FALSE。
2. e.seq=++head。
3. 若 head-cursor >= 16，推进 cursor 一位并增加 lost。
4. 把事件复制到 ring[(head-1)%16]。
5. 释放锁，返回 TRUE。

它修改输入 e.seq，并把整个结构值复制到环中。调用者之后覆盖自己的临时结构不会影响环内记录。

所有数据和 seq 在同一个锁内发布，查询方不会读到半条事件。该锁可能从已持有槽锁的 sample 或 record 生命周期处理路径取得。

### 10.3 为什么 lost 只表示部分覆盖

例一：head=16、cursor=1，第17条到来。最老的第1条尚未交给日志，覆盖它时 cursor 变2、lost 加一。

例二：前16条已经由 drain 取走，cursor=17。第17条覆盖第1条历史时，不增加 lost，因为它已离开待消费区。

因此 lost=0 不能证明所有历史仍可查询，也不能证明日志后端成功落盘；只能说明此计数器没有观察到“未消费事件被环覆盖”。

### 10.4 event_get() 的函数设计

~~~c
static bool event_get(u64 seq, struct event *e);
~~~

取得 event_lock 后检查：

~~~text
seq != 0
且 seq <= head
且 head-seq < 16
~~~

成立则复制对应环项到输出 e，返回 TRUE；否则返回 FALSE，输出不应被当作有效事件。

这用于查询有限历史。调用者不能把某次查询失败简单解释成从未生成过该序号，它可能已经被覆盖。

### 10.5 环大小与突发负载

同时多个 vCPU 触发风暴、多个主体刷新内存摘要，单次 sample 可以发布多条事件。容量16并不随 Guest/vCPU 数自动扩大。

固定容量保证存储可预测，代价是突发事件可能覆盖旧项。没有动态扩容、溢出链表、阻塞生产者或持久化重放队列。将来改变容量需要同时评估 RAM、后台消费能力和源码常量，而不是认为环本身无损。

## 11. 内部执行器、后台消费与日志格式化

### 11.1 tick() 的整体职责

~~~c
static void tick(struct vmm_timer_event *ev);
~~~

内部定时器回调依次执行：

1. 读取 now。
2. sample(now)，汇总和判定。
3. 在 event_lock 下读取 cursor<=head，判断是否还有待日志消费事件。
4. 若有，调度唯一 work 到 monitor 队列。
5. 再读一次时间，计算下一次 deadline。
6. 重新启动同一个 timer。

tick 不直接调用日志后端。工作已经处于待调度状态而返回 VMM_EALREADY 时，不计入 errors；其他调度错误增加 errors。

### 11.2 deadline 为什么不是简单 now+1秒

当前公式：

~~~text
deadline += (floor(max(now-deadline, 0) / 1秒) + 1) × 1秒
delay = deadline - now
~~~

它沿原计划时间格点向前推进，跨过已经错过的周期，不为每一个错过周期补造一次 sample。

例如原 deadline 为10秒，处理完成时 now=10.03秒，下一个 deadline 为11秒，延时约0.97秒；如果已经拖到12.2秒，下一目标为13秒，不在12.2秒连续执行几次伪造的“一秒采样”。

这减少固定把回调执行时间叠加到下一周期造成的累计漂移，但不能保证硬件中断、调度或锁操作绝不延迟。每个槽仍用真实观测间隔评价窗口质量。

重新启动定时器失败会增加 errors。当前没有完整的故障恢复状态机自动重建 timer；若不再有后续回调，后台采样可能停止，不能只因 enabled=1 就认为采样仍在推进。

### 11.3 report() 的函数设计

~~~c
static void report(struct vmm_work *unused);
~~~

唯一动作是调用 vmm_monitor_drain()。它是工作队列回调适配层，不负责采样、补计退出或修改配置。

内部线程优先级默认3，与产品 mterm 相同、低于 auth 的4。该优先级用于后台输出，不作为观察更高优先级线程的前提。

### 11.4 vmm_monitor_drain() 的函数设计

~~~c
void vmm_monitor_drain(void);
~~~

要求单个串行消费者，且运行上下文允许调用产品日志接口。一次调用最多处理8条：

~~~text
取得 event_lock
若 cursor>head：释放锁并结束
否则把 ring[(cursor-1)%16] 复制到局部 event
cursor++
释放 event_lock
print_event(..., log=true)
~~~

限制批量是为了避免大量事件时后台线程永远陷在打印循环中。没有在一次 drain 内无界追赶生产者。

未消费完时，内部 tick 下次仍会看到 pending，并继续安排工作。内部每秒调度、每次最多8条只是名义消费预算，实际速度还受线程获得时间片和日志调用耗时影响。

### 11.5 为什么打印前必须解锁

日志后端可能执行格式处理、锁操作、设备输出或存储操作。若持着 event_lock 调用，会把所有生产者和查询都阻塞在日志耗时上。

drain 先复制事件再解锁，print_event 使用局部副本。即使环中原项随后被覆盖，本次输出使用的数据仍完整。

但 cursor 在日志调用之前已推进：当前没有根据持久化成功与否回退 cursor、重试或确认。其语义是“交给日志接口处理”，不是“持久化成功确认”。

### 11.6 print_event() 的函数设计

~~~c
static void print_event(struct vmm_chardev *c,
                        const struct event *e, bool log);
~~~

使用栈上 char line[384] 和 vmm_snprintf 生成一行 schema=3 JSON。数值均按整数输出，U(x) 宏把参数显式转换成 unsigned long long，与 %llu 匹配。

log=true：vmm_lwarning("monitor", "%s", line)。  
log=false：vmm_cprintf(c, "%s", line)。

记录器不区分“串口提示一条、持久化 JSON 一条”。产品日志接口同时回显到串口时，同一条 JSON 可能同时进入存储和控制台，这是后端行为。

format 缓冲区只保护 monitor 自己构造这一行的空间。下游日志系统如果另有较短缓冲、拼接前缀或并发输出，仍可能截断或交错，不能由384字节的局部数组推出整条链路无截断。

### 11.7 JSON 事件字段

输出固定包含：

~~~text
schema, seq, time_ns, last_ns, type, guest, vcpu, epoch,
code, value, address, detail, config_seq, sustain_s
~~~

事件是逐行 JSON 对象，不是把所有事件包进一个 JSON 数组。日志后端可能添加 WARNING: monitor: 等前缀；命令 events 则直接输出对象行。

大型 u64 数值需要保留整数精度；不能让消费端把全部数值无条件转为精度不足的浮点数。

## 12. 查询接口与命令适配

### 12.1 vmm_monitor_dump() 的函数设计

~~~c
int vmm_monitor_dump(struct vmm_chardev *c, u32 view);
~~~

view 大于已定义最大值返回 VMM_EINVALID；未初始化返回 VMM_ENOTAVAIL。函数先在 event_lock 下复制 head、lost、epoch 和 config，再按视图输出。

打印前释放共享数据锁。它不创建采样窗口，不推进日志 cursor，不重置告警状态。

### 12.2 events 视图

先取本次查询的 head 快照 end，再遍历 max(1,end-15) 到 end，逐条调用 event_get()；仍在环内的事件调用 print_event(log=false)。

遍历期间生产者可能继续写入，导致某条在查询时已覆盖。event_get 失败就跳过，避免拿旧索引直接输出新事件。这不是全量历史归档，也不是对整个环的一次原子复制。

查询可以包含不同 epoch 的保留事件，因为环并未在 start 时清空。消费者应使用事件自身的 epoch 分辨归属。

### 12.3 config 视图

输出：

~~~text
exit_limit=<值>/s sustain_s=<值>s window_min_ms=<值> window_max_ms=<值>
~~~

配置查询采用简短文本。当前没有通过该命令修改采样周期、后台优先级、日志级别或调度延迟门限。

### 12.4 status 全局行

| 字段 | 来源与含义 |
|---|---|
| schema | 固定3 |
| enabled | 内部 enabled 转成0/1 |
| epoch | 读取时的当前采集代号 |
| sampler_cpu | 初始化记录的核 |
| events | head，即最新事件序号 |
| lost | 环未消费覆盖计数 |
| skipped | 槽 trylock 失败累计值 |
| errors | 工作调度、定时器重启等内部错误累计值 |
| exit_limit / sustain_s | 配置快照 |
| window_min_ms / window_max_ms | 配置快照 |
| config_seq | 配置快照代号 |

events 不等于当前环中条数，最大可查询条数仍为16。errors 也不是内存错误或 Guest 异常总次数。

### 12.5 status 对象行

dump 对0至 MAX_VCPU_COUNT-1逐槽加锁复制 struct data，释放锁后输出。NULL 摘要槽不作为对象状态行输出。

只有 present=true 且 d.epoch 等于本次查询的 epoch 才显示。

| 字段 | 含义 |
|---|---|
| kind | guest / host / idle |
| guest、vcpu | 主体归属，vcpu 使用槽索引 |
| epoch | 该槽代号 |
| time_ns | d.previous |
| interval_ns | d.interval |
| valid | d.valid |
| exits | d.count，即最近完成窗口次数 |
| ready_age_ns | 仍在等待、仍属启用 epoch 且时间有效时，now-ready_since；否则0 |
| ready | ready.count、整数均值、ready.max |
| dispatch | dispatch.count、整数均值、dispatch.max |

它没有查询并输出当前 Running/Paused 状态，也不是当前瞬间全部 exit 累计。因此不能把 status 看作 vcpu list 的实时状态镜像。

一个 status 输出混合了全局配置快照、逐槽复制的统计和各行读取时的等待年龄。每个结构副本受锁保护，但整份多行输出不是同一时刻的全局事务。

### 12.6 monitor_usage()

该函数只打印支持的命令形式：

~~~text
monitor start|stop|status|events|config
monitor config exit_limit|sustain_s|window_min_ms|window_max_ms <decimal>
~~~

不生成事件，不变更采集。

### 12.7 monitor_exec()

argc=2 时按子命令分发至 enable/dump。

argc=4 且子命令是 config 时：

1. 按固定 key 表查找配置键。
2. 检查参数非空。
3. 逐字符解析十进制数字。
4. 用 value > (UINT32_MAX-digit)/10 检查乘加溢出。
5. 调用 vmm_monitor_configure()。
6. 失败输出 monitor: config failed，成功输出 OK: key=value。

负号、正号、十六进制前缀和非数字字符不属于这个解析器接受的形式。未知键最终由 configure 的索引边界拒绝。

start/stop 分支直接返回 enable 的返回码，本函数没有另外生成成功 JSON。实际命令框架是否额外显示返回码取决于产品终端。

### 12.8 vmm_monitor_cmd_init()

初始化静态 monitor_cmd 的名称、描述、usage 和 exec，调用 vmm_cmdmgr_register_cmd 注册，返回原结果。

该接口不增加认证绕过路径。认证仍由产品 mterm/auth 与命令框架控制。

### 12.9 协议示例

下面是结构说明用样例，数值用于展示字段关系。

~~~json
{"schema":3,"kind":"guest","guest":0,"vcpu":70,"epoch":2,"time_ns":9000000000,"interval_ns":1000000000,"valid":1,"exits":1200,"ready_age_ns":0,"ready":[100,20000,90000],"dispatch":[101,8000,40000]}
~~~

这表示最近一秒1200次退出，累计100个 READY 样本，累计101个 dispatch 样本；两个样本数不必相等。

~~~json
{"schema":3,"seq":12,"time_ns":9000000000,"last_ns":9000000000,"type":1,"guest":0,"vcpu":70,"epoch":2,"code":256,"value":1200,"address":0,"detail":1000,"config_seq":3,"sustain_s":5}
~~~

这是已满足持续门限后发布的一次风暴事件；单看这一行不能还原之前所有窗口。value 是触发窗口速率，code 是该窗口最后退出原因。

~~~json
{"schema":3,"seq":13,"time_ns":9100000000,"last_ns":9200000000,"type":3,"guest":4294967295,"vcpu":4294967295,"epoch":2,"code":1,"value":2,"address":4095,"detail":2,"config_seq":0,"sustain_s":0}
~~~

这是 NULL 主体的一份内存摘要，期间共有两次内存类记录，最后一次为 shmem 偏移4095、长度2的范围拒绝。不能由 value=2 推断同一个对象的这一偏移正好被访问两次。

## 13. 并发、锁顺序与一致性

### 13.1 锁保护矩阵

| 访问路径 | 槽锁 | event_lock | 其他约束 |
|---|---|---|---|
| record 常规更新 | 对应槽 irqsave 自旋锁 | 通常不需要 | 主体指针在调用期间有效 |
| record 生命周期摘要刷新 | 先持槽锁 | 再由 emit 获取 | 固定顺序 |
| sample | 每槽 trylock | 配置复制先独立取得；emit 时可嵌套 | sample 单执行者 |
| enable/configure | 无 | 持有 | 更新原子状态或配置 |
| event_get/emit | 无，或调用者已持槽锁 | 持有 | 不反向请求槽锁 |
| drain | 无 | 复制事件与推进 cursor 时持有 | 单消费者，打印前解锁 |
| dump | 逐槽短时持有 | 全局快照和事件复制时独立持有 | 不在 event_lock 内再取槽锁 |

合法嵌套顺序只有：

~~~text
slot.lock → event_lock
~~~

不得建立 event_lock → slot.lock 的反向路径。sample 先复制配置后释放 event_lock，再遍历槽，就是为了遵循这个规则。

### 13.2 为什么使用 irqsave

打点可能发生在调度、异常或普通线程上下文；同核中断如果打断了持有同一监控锁的代码，再尝试取该锁，会产生自锁风险。

irqsave 在持锁区间保存并屏蔽本地中断状态，退出时恢复。它不能避免其他核对同一锁的竞争，因此不能把这些锁理解成零等待。

### 13.3 受保护的内容与不保证的内容

受保护：

- 单槽的多字段更新不会被另一条持同槽锁的更新拆开。
- 配置四字段与 seq 以一个受锁保护的快照读取。
- 环项复制和 seq/head/cursor 更新受同一事件锁保护。
- 打印不读取正在被生产者直接改写的环项指针。

不保证：

- 整份 status 所有行属于同一个绝对时刻。
- stop 返回前等待所有在途 record/sample 完成。
- 日志交付与持久化成功之间的事务一致性。
- 固定容量环在任意突发负载下不丢事件。
- 外部平台并发调用 sample/drain 时仍保持既定时序。

### 13.4 三个代号分别解决什么问题

| 代号 | 解决的问题 | 不解决的问题 |
|---|---|---|
| epoch | 区分不同 start 周期，防止旧槽直接作为新周期数据展示 | 不自动清空整个事件历史，不构成停止屏障 |
| config_seq | 识别配置变更窗口，拒绝过期风暴结论 | 不保存历史配置全集，不证明地址或日志有效 |
| seq | 给发布事件排序，定位有限历史 | 不保证所有序号仍可查询或已经持久化 |

它们不能互相替代，也不应被消费端合并成一个“版本号”。

### 13.5 外部执行器的调用契约

外部模式下平台至少提供：

1. 初始化完成后才启动调用。
2. sample 使用与 record 相同且跨相关 CPU 可比较的纳秒时间基准。
3. sample 约每秒串行调用，并运行于适合该监控设计的 Hypervisor 上下文。
4. drain 串行调用，所在上下文允许执行产品日志接口。
5. 在开关关闭后，仍根据产品需要完成先前摘要和事件的收尾消费。

sample、drain 生产入口本身没有与 record 一样的 initialized 早退保护，因此平台必须遵守初始化顺序，不能把任意时刻调用当成受保护的无操作。

sampler_cpu 在外部模式仍保存初始化核；它不是每次外部 sample 实际执行核的动态追踪字段。外部平台若改变执行核，应另行明确展示语义。

## 14. 编译配置、内存和运行开销

### 14.1 生产编译选项

| 选项 | 默认 | 作用 |
|---|---|---|
| CONFIG_MONITOR_AGENT | n，依赖 ARM64 | 编译采集器与有效打点 |
| CONFIG_CMD_MONITOR | 在依赖满足时默认 y | 编译 monitor 命令 |
| CONFIG_MONITOR_START_ENABLED | n | 初始化后自动开始采集 |
| CONFIG_MONITOR_PRIORITY | 3，范围0～7 | 后台日志线程优先级 |
| CONFIG_MONITOR_EXIT_RATE | 50000 | 开机退出速率门限 |
| CONFIG_MONITOR_STORM_SECONDS | 5 | 开机持续门限 |
| CONFIG_MONITOR_EXTERNAL_EXECUTOR | n | 使用产品已有周期与日志执行上下文 |

core/openconf.cfg 引入 monitor 配置；core/monitor/objects.mk 按总开关编译对象；命令配置和对象单独受 CONFIG_CMD_MONITOR 控制。

### 14.2 编译关闭时的行为

vmm_monitor.h 提供 init 的成功空桩，以及 state/selected/dispatch/exit/mem_fault 空宏。空宏不求值参数，因此只作为宏参数传入的额外时间戳读取也不会执行。

运行时 stop 与编译关闭不同：stop 不卸载已编译路径，内部定时器仍运行、历史数据仍保留。量产需要最小采集开销时，应按产品构建选择总开关。

### 14.3 vmm_monitor_range_valid() 的辅助函数设计

~~~c
static inline bool vmm_monitor_range_valid(u64 size,
                                           u64 offset, u64 length)
{
    return offset <= size && length <= size - offset;
}
~~~

它先检查 offset<=size，再做 size-offset，避免直接使用 offset+length 形成溢出判断。

这个函数只是公共范围辅助，不会自动拦截所有内存访问。其存在不代表已经替换 shmem 或产品原命令里的边界公式，也不表示 monitor_agent 的 record 会重新验证每个 address。

### 14.4 静态存储预算

主要 RAM 项可写成：

~~~text
(CONFIG_MAX_VCPU_COUNT + 1) × sizeof(struct slot)
+ 16 × sizeof(struct event)
+ 全局锁、原子量、配置、序号与时间基准
+ 内部模式的静态 timer/work/queue 指针
~~~

实际结构大小取决于目标 ABI、对齐和锁实现。数组容量依据 MAX_VCPU_COUNT，不依据“产品只有12个物理核”；后台线程、idle、Guest vCPU 都消耗调度对象 ID。

内部工作队列及线程栈在初始化时由已有 Xvisor 接口创建，允许启动期分配。record/sample 不按采集次数申请监控对象；日志格式化使用固定栈缓冲。产品日志后端是否分配、缓存或写盘，由其自身实现决定。

### 14.5 运行复杂度

| 操作 | 数据处理规模 | 实际限制 |
|---|---|---|
| 一次 record | 一个槽，常数数量字段 | 槽锁及可能的事件锁竞争 |
| 一次 sample | 最多 MAX_VCPU_COUNT+1 槽 | IRQ 预算随配置容量增长 |
| 一次 emit/event_get | 一个环项 | 事件锁竞争 |
| 一次 drain | 最多8条 | 日志接口耗时可能主导 |
| 一次 status | 最多 MAX_VCPU_COUNT 个对象 | 逐行输出，命令耗时不属于纯采集更新 |
| 一次 events | 最多16个序号 | 可能在查询中被覆盖 |

“常数数量字段”不等于严格固定最坏执行时间。自旋锁、时间源和底层平台调用需要一并考虑。

### 14.6 ROM、CPU 与确定性约束的表述

代码采用固定容量、整数计算、异步输出，目的是控制 ROM/RAM 和采集开销。但不能由代码结构直接得出 ROM≤5KB、CPU<0.5% 已满足。

ROM 需区分采集器、命令、字符串、链接时保留的依赖与其他原模块；CPU 开销需覆盖真实频率下的打点、每秒槽遍历、并发锁及日志负载。本文给出实现和预算构成，不宣称尚无产品证据的数值。

采样运行在 Hypervisor 上下文能够摆脱对 Guest 用户进程调度的依赖，但关闭中断、硬件时钟问题、抢占延迟和锁竞争仍影响时效。当前 valid/skipped/errors 提供质量线索，不构成对任意工作负载的硬实时保证。

## 15. 设计边界与故障语义

### 15.1 接入路径就是观察边界

monitor 不能从未发生的打点推导异常。新设备后端、共享内存接口或调度路径绕过已接入入口时，需要明确提供数据，采集器不会自动识别。

CPU 源头应传入与指标定义一致的时间点；内存源头应提交原检查已经识别的结果；exit 源头应避免把 EL2 自身 IRQ 算为新的 Guest 退出。

### 15.2 错误处理表

| 情况 | 当前行为 |
|---|---|
| 初始化失败 | 返回错误；系统接入打印 unavailable 后继续 |
| 未初始化时命令调用 enable/configure/dump | 返回 VMM_ENOTAVAIL |
| 无效配置参数 | 返回 VMM_EINVALID，不修改配置 |
| record 主体或采集条件不满足 | 静默忽略，无返回错误码 |
| sample 槽锁繁忙 | skipped++，保留该槽原始累计等待后续采样 |
| 窗口过长／过短 | valid=false，不用于持续风暴判断 |
| 配置在判定途中变更 | emit 拒绝旧配置风暴结论 |
| 事件环覆盖未消费项 | 推进 cursor，lost++ |
| 工作调度已排队 | VMM_EALREADY 不作为内部错误 |
| 其他工作调度／timer 重启失败 | errors++；没有通用自动重建机制 |
| 日志输出后端失败 | 当前无持久化确认与自动重放 |

### 15.3 当前没有保存的信息

- 调度每一个原始样本及其调用栈。
- exit 各原因完整分类计数、异常 PC、处理耗时。
- 内存每一次错误完整明细、目标共享对象名称、被访问目标 Guest。
- 完整 ESR 与独立的取指/读/写权限子类型。
- 已覆盖事件的永久归档。

需要这些信息时，应作为数据结构和输入接口的扩展讨论，不能从现有摘要虚构推导。

### 15.4 对外输出能力

现有生产实现完成字符设备命令查询和产品日志调用。产品若通过既有日志后端把数据送往诊断 VM，可复用本 JSON。

本实现没有独立的 virtio-serial 连接管理、共享内存导出协议、诊断 VM 确认应答或重传机制。CCM/shmem 的错误打点与监控上报通道是不同事情。

### 15.5 算术与长期运行边界

时间、计数和序号使用 u64，配置使用有范围限制的 u32。长期累计没有统一的饱和策略或序号回绕状态机；速率乘法也以当前整数宽度执行。

epoch/config_seq 回绕会跳过0，但没有无限历史代号去重机制。正常部署应把这些视作有限宽度实现，而不是数学上的无界计数。

## 16. 端到端流程示例

### 16.1 一次调度等待如何进入 status

~~~text
对象成功进入 READY
→ 产品调度器传入原时间戳
→ record 保存 ready_since/waiting
→ 对象通过调度复查并被选中
→ selected 计算终点减起点
→ add 更新 ready 的 count/sum/max
→ status 复制槽，计算整数均值并输出
~~~

这条链不需要等待下一次 sample 才完成延迟累计。sample 主要影响退出窗口和事件发布，不是每个调度样本的计算器。

### 16.2 一次内存拒绝如何进入日志

~~~text
原检查决定拒绝
→ 调用 mem_fault，记录主体、错误类型、地址与附加信息
→ record 更新内存摘要
→ 原检查继续返回原错误
→ 后续 sample 刷新摘要至事件环
→ tick 发现 pending，安排 report
→ drain 复制事件并推进 cursor
→ print_event 生成 JSON，调用产品日志接口
~~~

原拒绝与日志打印之间存在异步间隔。原访问是否拒绝不依赖后台日志线程此时能否运行。

### 16.3 一次风暴如何触发且保持去重

~~~text
多个真实 Guest exit
→ record 增加当前 exits
→ sample 冻结窗口次数，检查时长质量
→ 若持续超限，累计 windows/sustained
→ 条件达到且配置仍有效，emit 发布事件
→ active=true
→ 后续有效超限窗口不重复发布
→ 观察到有效低速窗口，active=false
→ 未来再次持续超限，可以产生新事件
~~~

最后一步只是重新允许告警，没有新增对 Guest 的控制动作。

## 附录 A. 生产函数索引

以下链接定位到本次采用的参考源码。辅助入口、公开接口和静态内部函数都按实际实现列出；正文已分别说明其输入、状态变化与执行限制。

| 文件 | 函数定位 | 作用 |
|---|---|---|
| monitor_agent.c | [emit()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c:56>) | 版本复查、序号分配、事件发布、覆盖计数 |
| monitor_agent.c | [memory_flush()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c:71>) | 把单槽内存摘要发布到事件环 |
| monitor_agent.c | [add()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c:75>) | 更新 count/sum/max |
| monitor_agent.c | [vmm_monitor_record()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c:82>) | 即时采集统一入口 |
| monitor_agent.c | [vmm_monitor_enable()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c:147>) | 运行启停与 epoch |
| monitor_agent.c | [vmm_monitor_configure()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c:163>) | 参数边界和配置代号 |
| monitor_agent.c | [vmm_monitor_sample()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c:181>) | 窗口、摘要刷新、风暴判定 |
| monitor_agent.c | [print_event()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c:247>) | 单事件 JSON 与日志/字符设备输出 |
| monitor_agent.c | [event_get()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c:262>) | 锁内复制仍保留的事件 |
| monitor_agent.c | [vmm_monitor_drain()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c:272>) | 单消费者、有限批量交付日志 |
| monitor_agent.c | [vmm_monitor_dump()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c:294>) | 三种查询视图 |
| monitor_agent.c | [report()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c:343>) | 工作队列回调适配 |
| monitor_agent.c | [tick()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c:344>) | 采样、安排输出、推进定时器 |
| monitor_agent.c | [vmm_monitor_init()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c:362>) | 一次性初始化；头文件位置为编译关闭空桩 |
| vmm_monitor.h | [vmm_monitor_cmd_init()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/include/vmm_monitor.h:35>) | 命令注册；头文件位置为命令关闭空桩 |
| vmm_monitor.h | [vmm_monitor_range_valid()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/include/vmm_monitor.h:37>) | 减法式范围辅助 |
| vmm_monitor.h | [vmm_monitor_init()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/include/vmm_monitor.h:55>) | 一次性初始化；头文件位置为编译关闭空桩 |
| cmd_monitor.c | [monitor_usage()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/commands/cmd_monitor.c:6>) | 命令用法 |
| cmd_monitor.c | [monitor_exec()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/commands/cmd_monitor.c:11>) | 命令参数解析与接口分发 |
| cmd_monitor.c | [vmm_monitor_cmd_init()](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/commands/cmd_monitor.c:49>) | 命令注册；头文件位置为命令关闭空桩 |

## 附录 B. 源码依据

正文以生产核心为中心；接入源码用于确认输入语义与平台调用关系。下表路径和哈希锁定本说明所使用的文件，便于区分用户后续产品修改。

| 序号 | 文件 | SHA-256 |
|---:|---|---|
| 1 | [core/monitor/monitor_agent.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/monitor_agent.c>) | 9f7f3703f209515054467d5b56a6a2de14d07495a9a50ee743cfb1d92e4720c2 |
| 2 | [core/include/vmm_monitor.h](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/include/vmm_monitor.h>) | b4c4a76ebd6555d39a5ac72884b8d6bd4ab17b93f3e16412714bae79becaad18 |
| 3 | [commands/cmd_monitor.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/commands/cmd_monitor.c>) | ef1856ebb50738468f81ded512225374caeaec4b3c04c6833000be8b8d3301aa |
| 4 | [core/monitor/openconf.cfg](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/openconf.cfg>) | 35e59d3d9c1e6468fd43e8be07b6c959816f5715e5799b9201edae18af57bd9c |
| 5 | [core/monitor/objects.mk](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/monitor/objects.mk>) | de010a9a0cc559630677e83bec108740e5bfd603f97329b0c6bb2b71ceca5e35 |
| 6 | [core/openconf.cfg](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/openconf.cfg>) | b3036b5f0a58517e31d01750e99d91800d903cda6aa5fa64a36ec4ef385ba858 |
| 7 | [commands/openconf.cfg](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/commands/openconf.cfg>) | 39ca772165778cc63fc652b7c12acabb32cc44f8949a3883f8f3ddbfb602eaf4 |
| 8 | [commands/objects.mk](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/commands/objects.mk>) | 5e4c2f30daf63be9ed559e022201498fe20a2fe6948a458d109818ae08fbc2a4 |
| 9 | [core/vmm_main.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/vmm_main.c>) | adc077a4456c274cb956b3cb53a7992add7615decdbf49df7bb113d18f261cff |
| 10 | [core/vmm_timer.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/vmm_timer.c>) | f453fa28ecf0d7df661aa67c8a06459bf8a4b0b64708d88b026210704a4f9bf0 |
| 11 | [core/vmm_workqueue.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/vmm_workqueue.c>) | ec646f3a32247e3a511676b822fc73e45a82d477ff059425a76cfde6ac310a50 |
| 12 | [产品/core/vmm_scheduler.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_scheduler_history_适配_20261022/core/vmm_scheduler.c>) | accd975347050b958acd52233b471c32de4d5db25f46a9203e9f80261ebd7516 |
| 13 | [arch/arm/cpu/arm64/cpu_interrupts.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_interrupts.c>) | 443ef291fa46591cc4395cf3e28a0378349d6df6e7da2170f54e81320f246792 |
| 14 | [arch/arm/cpu/arm64/cpu_entry.S](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_entry.S>) | 1943a6d42d7e9a29ed1887ba8bfd76b95dc6247e4a7ccd764cfd7bbe1f7183c8 |
| 15 | [arch/arm/cpu/arm64/cpu_vcpu_excep.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/arch/arm/cpu/arm64/cpu_vcpu_excep.c>) | e3f11f2d26771b8cbf265478ab51b669ec2bb286c7dcb6ca438284453f41d90f |
| 16 | [core/vmm_shmem.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/work/monitor-runtime-storm/tree/core/vmm_shmem.c>) | 5f97c11fcfaaf4bd943d1c9d746565627a0eaa895bcbbcfc3172d0f11cb482f8 |
| 17 | [产品/arch/arm/cpu/arm64/cpu_hcall.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_observer_from_20261023_v4_20261025/full_files/private_hypervisor/arch/arm/cpu/arm64/cpu_hcall.c>) | f1462d08904ec52b658bf1224be5a5542d7f6109f9a2cf37d6023e3599e3f14f |
| 18 | [产品/core/vmm_u_ioreq.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_observer_from_20261023_v4_20261025/full_files/private_hypervisor/core/vmm_u_ioreq.c>) | 5b640eeb26ee67b6f8781dcf507058a19567f3ab3937b5869af516521318374f |
| 19 | [产品/commands/cmd_memory.c](<C:/Users/win/Documents/Codex/2026-10-18/d-code-xvisor-master-xvisor-xvisor-2/outputs/monitor_runtime_storm_v4_20261026/observer_base/full_files/private_hypervisor/commands/cmd_memory.c>) | 6b121aad3624e64d315f4f113d731cbc925c6e6a70165783057dc0f9e2a3a361 |

文档中的流程图描述当前代码关系；源码索引中的参考行号不应被用作直接覆盖产品文件的依据。

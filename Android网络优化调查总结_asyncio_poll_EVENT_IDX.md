# Android网络优化调查总结：asyncio、poll与EVENT_IDX

> **范围：** 汇总当前已提供的DSM、CCM、HOS源码，以及asyncio吞吐测试和EVENT_IDX开／关对照结果。不新增测试结论，不将不同通知路由、CPU布局或负载下的数据合并为同一组性能收益。
>
> **方向：** 上行＝Android→PC；下行＝PC→Android。文中带宽优先采用iperf接收端结果，IPI特指ServerVM Linux可见的Function-call IPI，不等同于HOS物理IPI或Guest虚拟网卡IRQ。

## 1. 总体结论

| 优化项 | 实际作用 | 当前调查状态 | 阶段性结论 |
|---|---|---|---|
| **asyncio异步通知** | 改变Guest通知后端的传输与完成路径 | 网络RX／TX异步登记已与vhost kick对象对应；已完成600秒双向及940 Mbps上行测试 | **已有明确吞吐改善，是当前主要优化方向；仍有少量丢包，不能记为无丢包验收通过** |
| **DSM定时poll／vhost忙轮询** | 主动检查队列，尝试减少依赖通知唤醒的等待 | 当前两种主动轮询都未开启，也没有对应性能对照 | **尚未验证，不能把已有提速归因于poll** |
| **EVENT_IDX** | 根据virtqueue事件索引判断是否需要发出kick或完成通知 | 已确认协商开启，并完成400 Mbps普通client开／关对照 | **固定绑核后，kick、Guest TX IRQ、IPI差异均不足0.5%，未观察到明显的通知数量收益** |

三者不是同一层的开关：

```text
asyncio：通知发出后，怎样交给后端，是否等待普通请求完成。
poll：后端是否主动检查新工作，而不是只等事件到达。
EVENT_IDX：队列推进到什么位置时，需要发送一次通知。
```

**此前“poll已经开启”的表述需要修正为：vhost使用事件驱动的就绪监听；主动定时poll和busy polling尚未开启。**

## 2. 调查背景与判定口径

此前普通client路径已定位到：

```text
CCM dispatcher／kworker
    → ioeventfd客户端
    → vhost
```

当这些执行上下文跨CPU交接时，可产生远程TTWU／Function-call IPI及后续激活、调度等待。此前的亲和性干预与时间分解支持：**高频通知交接是上行性能下降的重要影响机制，但不能将全部调度时间都称为IPI handler耗时。**

本阶段进一步区分四类计数：

| 计数对象 | 含义 | EVENT_IDX是否直接控制 |
|---|---|---|
| Android TX kick | Guest通知后端有新TX工作 | **是，受avail事件索引规则影响** |
| 后端完成通知／Android virtio IRQ | 后端通知Guest已有工作被消费；两者统计口径不完全相同 | **完成通知受used事件索引规则影响** |
| ServerVM Function-call IPI | 包括远程任务激活在内的系统级跨CPU活动 | **否，只可能间接受影响** |
| ServerVM物理eth0 IRQ | 物理网卡收发及完成等中断入口 | **否，不是EVENT_IDX的直接优化对象** |

因此，不能将“IPI减少42%”等同于“virtio通知被抑制42%”，也不能将物理eth0中断和Android虚拟网卡中断混为一项。

**依据：** 用户提供的CCM与DSM通知代码；内核`vhost_signal()`仅在通知判断允许时signal Guest对应eventfd，`vhost_enable_notify()`在EVENT_IDX模式下更新`avail_event`。fileciteturn97file0L43-L48 fileciteturn97file0L93-L114

## 3. asyncio：已确认改变通知路径，并取得吞吐改善

### 3.1 参数位置曾导致网络不通，原因是解析限制

当前正常网络参数：

```bash
-s 00:0.0,virtio-net,tap=tap1,vhost,iothread
```

曾经不通的排列：

```bash
-s 00:0.0,virtio-net,iothread,tap=tap1,vhost
```

DSM `virtio_net_init()`存在两处位置依赖：

| 代码行为 | 将iothread放在第一个设备选项时的结果 |
|---|---|
| 首次解析无条件跳过第一个选项，再识别vhost、iothread等 | iothread被跳过，未按预期设置 |
| 后续仅在选项字符串以`tap`开头时解析并初始化TAP | 不调用正常的TAP初始化路径 |

**所以，不是“iothread必须紧跟vhost”，而是当前实现要求`tap=...`位于设备选项开头。** 参数位置问题不应误判为asyncio与vhost天然不兼容。

**依据：** 用户提供的DSM `virtio-net.c`，`virtio_net_init()`中的两段参数解析。

### 3.2 异步通知已经连接到正确的vhost对象

DSM注册代码：

```c
if (base->iothread)
        ioeventfd.flags |= ACRN_IOEVENTFD_FLAG_ASYNCIO;

ioeventfd.fd = fd;
```

vhost调用者传入的是`vq->kick_fd`，同一个FD随后交给内核`VHOST_SET_VRING_KICK`。本次成功启动的日志对应如下：

| 网络队列 | 通知地址 | IOEM路由 | 注册FD | vhost kick FD | 内核回调 |
|---|---|---|---:|---:|---|
| RX | `0x6020003000` | asyncio | 14 | 14 | `handle_rx_kick` |
| TX | `0x6020003004` | asyncio | 16 | 16 | `handle_tx_kick` |

两队列对应同一个worker1022。上述地址、FD和worker仅指这次启动，不能作为以后启动的固定编号。

结合通用`virtio.c`，`virtio_set_iothread(base, true)`的正常启动入口受`BACKEND_VBSU`限制；网络使用`BACKEND_VHOST`时，不通过这一入口注册DSM用户态virtqueue消费者。**该配置中，iothread标记的关键作用是让vhost kick登记使用asyncio路由，不是必然增加一个DSM网络处理线程。**

**依据：** 用户提供的DSM `vhost.c`、`virtio_register_ioeventfd()`、`virtio_pci_status_handler()`及成功启动的IOEM_CFG／VQMAP日志。

### 3.3 为什么异步可能比单纯绑核收益更大

普通client的CCM代码要求handler成功返回后再完成请求；已提供的HOS普通请求代码调用`vmm_completion_wait()`，随后才消费完成结果。**它等待的是通知请求完成，不是等待物理网卡发送完成。**fileciteturn96file2L200-L208

```text
普通client：
Guest TX通知
    → HOS普通请求及完成等待
    → CCM dispatcher
    → ioeventfd客户端处理并signal vhost
    → CCM完成请求
    → Guest当前vCPU继续原I/O流程

asyncio：
Guest TX通知
    → 将通知token可靠提交到sbuf
    → upcall后返回，Guest可继续执行
同时：
CCM dispatcher取token
    → signal对应vhost kick对象
    → vhost处理数据
```

已提供的HOS异步成功提交路径没有普通请求的completion等待，但sbuf满时仍会重试，不能称为无条件零等待。fileciteturn96file1L115-L132

**机制结论：** 绑核降低原流程的部分交接代价；asyncio则绕过普通client交接及完成往返，使生产与消费更容易重叠。这与此前IPI相关归因一致，但本次没有新测异步模式的IPI总量，不能宣称IPI已经归零，也不能给出各阶段收益占比。HOS控制流依据已提供源码版本，不替代对运行构建版本的一致性核对。

### 3.4 已完成的600秒测试

下表采用用户提供的iperf最终统计：

| 测试 | 目标负载 | 实际sender | 实际receiver | 接收端丢包／总包数 | 计算丢包率 |
|---|---:|---:|---:|---|---:|
| asyncio UDP上行 | 1000 Mbps | 1000 Mbps | 955 Mbps | 2,415,860／53,572,608 | **4.509506%** |
| asyncio UDP下行 | 1000 Mbps | 954 Mbps | 954 Mbps | 20／51,129,746 | **0.0000391%** |
| asyncio UDP上行复测 | 940 Mbps | 940 Mbps | 940 Mbps（显示舍入） | 6,526／50,362,177 | **0.012958%** |

940 Mbps复测的接收速率按报文数计算为：

```text
实际收到包数 = 50,362,177 − 6,526 = 50,355,651

接收速率 = 50,355,651 × 1400 × 8 ÷ 600.07 ÷ 10^6
         ≈ 939.8625 Mbps
```

**结果说明：** 当前asyncio配置已能持续承载接近千兆链路有效载荷上限的流量；但940 Mbps测试仍有6526个丢包，不能写成“600秒零丢包”或“全部可靠性验收完成”。

沿用此前讨论的协议开销模型：在1 Gbit/s、IPv4无额外选项、无VLAN、不分片的假设下，1400字节UDP有效载荷对应1466字节等效链路占用：

```text
有效载荷上限 ≈ 1000 × 1400 / 1466 = 954.98 Mbps

1000 Mbps有效载荷超过该容量的比例
             ≈ 1 − 954.98 / 1000 = 4.502%
```

它与1000 Mbps上行实测4.5095%的丢包率接近，支持“该负载超出有效载荷容量”的解释，**但不能定位丢包点，也不能据此解释940 Mbps下的全部剩余丢包**。

本表不是严格固定所有变量的asyncio独立贡献率试验；不将其与其他client运行的461 Mbps直接相减，宣称得到精确优化百分比。

## 4. poll：代码与运行状态已澄清，主动轮询尚未验证

### 4.1 三种“poll”必须分开

| 机制 | 代码／配置入口 | 当前状态 |
|---|---|---|
| **DSM定时virtqueue poll** | `virtio_poll_enabled()`、定时器及`virtio_poll_timer()` | **未开启** |
| **内核vhost busy polling** | DSM设置非零`busyloop_timeout`，通过ioctl下发 | **未开启，busyloop_us=0** |
| **vhost eventfd就绪监听** | 等待队列／poll回调在事件到达时提交work | 正常使用，但**不是主动扫描队列** |

iothread代码中的`epoll_wait()`同样属于事件等待，不能根据函数名或存在epoll，就判断DSM定时poll／vhost忙轮询开启。

**此前“poll已开启”的结论撤回；准确说法是“事件驱动的就绪监听存在，主动poll未测试”。**

### 4.2 当前脚本为何没有启动DSM定时poll

用户提供的`virtio.c`明确：

```c
bool virtio_poll_enabled(struct virtio_base *base)
{
        return g_virtio_poll_enabled || base->polling_enable;
}
```

| 字段 | 设置条件 |
|---|---|
| `g_virtio_poll_enabled` | `acrn_parse_virtio_poll_interval()`解析成功 |
| `base->polling_enable` | 设备选项出现`virtio_poll_interval=...` |
| `base->iothread` | 用于本项目iothread／asyncio选择，不等同于poll开关 |

当前网络参数没有设备级poll间隔，本次运行日志又明确给出`poll_configured=0`，与未配置主动poll一致。

更重要的是，DSM定时器初始化和启动受后端类型限制：

```c
/* virtio_pci_status_handler() */
if (base->backend_type == BACKEND_VBSU) {
        /* 初始化及启动DSM poll的相关逻辑 */
}

/* virtio_poll_start() */
if (... || base->backend_type != BACKEND_VBSU || ...)
        return;
```

**因此，对当前BACKEND_VHOST网络，仅增加DSM的poll间隔参数，并不会按这份正常启动代码让内核vhost开始忙轮询。** 反而可能只令`poll_configured=1`，影响EVENT_IDX能力过滤，却没有得到预期的轮询行为。

全局命令行选项的准确拼写未在已提供主程序代码中确认，不能仅凭解析函数名推定。

### 4.3 vhost忙轮询使用另一套设置

DSM `vhost_net_init()`当前设置：

```c
uint32_t busyloop_timeout = 0;
```

`vhost_dev_start()`只有在该值非零时，才调用：

```c
vhost_kernel_set_vring_busyloop_timeout(...);
```

这才是后续评估内核vhost主动忙轮询应控制的入口。按当前循环，直接修改该值会作用于该vhost设备的各队列，不是仅TX。

**调查结论：** 主动poll尚无开／关性能结果，既不能宣布有效，也不能宣布无效。此前asyncio提速不是主动poll的试验结果。未来若研究，应独立记录吞吐、CPU占用、低负载行为及对其他实时任务的影响。

### 4.4 poll与EVENT_IDX不是所有情况下都互斥

当前DSM用户态定时poll通过`VRING_USED_F_NO_NOTIFY`等flags控制kick，而EVENT_IDX使用事件索引判断通知。因此，代码对该poll模式屏蔽EVENT_IDX有其实现背景，不能不检查事件索引处理就强行同时启用。

但**asyncio不等于这套poll**，所以asyncio与EVENT_IDX不是被上述条件天然互斥。此次EVENT_IDX实验保留了“不在DSM poll配置下强行开启”的限制，未测试主动poll与EVENT_IDX的组合。

## 5. EVENT_IDX：协商已开启，固定布局下通知数量收益很小

### 5.1 为什么原来为0，怎样确认已经开启

DSM原来的Guest能力集合`VIRTIO_NET_S_HOSTCAPS`没有EVENT_IDX。虽然`VIRTIO_NET_S_VHOSTCAPS`包含它，后续按位AND过滤不会将Guest能力中的0补成1。

另外，原清位表达式把位编号当成掩码：

```c
/* 原表达式 */
device_caps &= ~(uint64_t)VIRTIO_RING_F_EVENT_IDX;

/* 修正表达式 */
device_caps &= ~(1ULL << VIRTIO_RING_F_EVENT_IDX);
```

实验修改是在实际vhost初始化成功、后端支持且未配置DSM poll时，直接向Guest能力加入EVENT_IDX，再沿现有Guest协商和`VHOST_SET_FEATURES`路径传递。

实际日志确认：

```text
offered=1 negotiated=1 sent=1
VQCFG ... event_idx=1 packed=0 busyloop_us=0 size=1024
```

**说明功能已经开启，不是“只改了宏但没有协商”。** 这是DSM源码修改后的结果，单独执行export或把采集标签写成on不会开启该能力。

### 5.2 试验方法及可比性边界

使用`eventidx_count.sh`在ServerVM和Android各读取稳定窗口首尾计数，再由`eventidx_report.py`离线比较。主负载为：

```bash
./iperf3 -A 1 --cport 41001 \
    -p 5201 -c 192.168.1.1 \
    -u -b 400M -l 1400 -t 120 -i 10
```

本轮选择400 Mbps，是为了让两组达到相同负载，比较每份工作对应的通知成本，**不是测最大吞吐上限**。统计对象包括Android驱动kick、Guest虚拟IRQ、ServerVM IPI及物理eth0 IRQ；没有记录每次`vring_need_event()`的返回值。

首次未固定线程CPU；随后按相同布局复测：

| 对象 | OFF | ON |
|---|---|---|
| ioeventfd | CPU1 | CPU1 |
| vhost | CPU0 | CPU0 |
| eth0 IRQ | 按相同CPU0布局测试 | 相同 |
| 通知路由 | 声明client | 声明client |
| Guest实际EVENT_IDX | 0 | 1 |

**固定绑核复测的Server侧质量为REVIEW：** 工具未能从保存的初始化日志中完整关联当前网络对象和IOEM路由，`route_observed=None`不代表实际路由名为None。以下按用户声明的client配置解读；Guest特征、线程亲和性和计数可分析，但Server路由关联仍需在归档中保留这一限制。不能将报告末尾“未发现明显不一致”理解成路由已完整验证。

### 5.3 固定绑核后的实测数据

数据来源：用户提交的“重新绑核后”feedback及对应OFF／ON的PC日志。

| 指标 | OFF | ON |
|---|---:|---:|
| ServerVM主方向PPS | 35,709.763 | 35,710.630 |
| Android主方向PPS | 35,720.597 | 35,724.793 |
| PC接收带宽 | 400 Mbps | 400 Mbps |
| PC丢包／总包数 | 50／4,285,717 | 155／4,285,719 |
| PC计算丢包率 | 0.001167% | 0.003617% |
| ServerVM全核平均CPU busy | 9.422% | 8.300% |
| Android全核平均CPU busy | 22.516% | 22.567% |

归一化计算：

```text
每万包事件数 = 事件次数/秒 ÷ 实际包数/秒 × 10000

减少率 = (OFF每万包次数 − ON每万包次数)
         ÷ OFF每万包次数 × 100%
```

| 指标 | OFF：次/万包 | ON：次/万包 | 每万包减少率 |
|---|---:|---:|---:|
| **Android TX kick** | **9,542.412** | **9,496.174** | **0.485%** |
| **Android virtio TX虚拟IRQ** | **9,846.313** | **9,811.940** | **0.349%** |
| **ServerVM Function-call IPI** | **19,187.440** | **19,117.513** | **0.364%** |
| ServerVM物理eth0 IRQ | 400.019 | 400.559 | −0.135%，基本不变 |

例如：

```text
TX kick减少率
= (9542.412 − 9496.174) / 9542.412 × 100%
≈ 0.485%
```

换成每1000包，TX kick仅由约954次变成950次，Guest TX IRQ仅由约985次变成981次。**均未显示明显的通知数量净收益。** 单次不足0.5%的变化也不能直接记成稳定优化百分比。

ServerVM CPU busy降低1.122个百分点，但这是全核平均、包含其他业务；不能直接用IPI仅减少0.364%解释，更不能将全部CPU差额归给EVENT_IDX。Android CPU基本不变。ON本次丢包略多，但没有足够重复样本证明稳定退化或改善。

### 5.4 IPI数量关系基本未改变

| IPI接收位置 | OFF次数 | ON次数 |
|---|---:|---:|
| CPU0 | 1,019,807 | 1,017,357 |
| CPU1 | 1,022,685 | 1,018,191 |
| **CPU0＋CPU1** | **2,042,492** | **2,035,548** |
| 全CPU | 2,056,222 | 2,048,778 |
| CPU0＋CPU1占比 | 99.33% | 99.35% |

按各自窗口换算，两核IPI频率与Android TX kick频率之比约为：

```text
OFF：1.997
ON ：1.999
```

两组都与“每次kick附近出现约两份主要CPU上的IPI活动”的数量关系相符。**这是跨OS频率对照，不是逐事件配对，也不能据此重新证明每个IPI的目标任务；结合此前已定位的通知链，它支持原跨核交接结构基本未变。**

### 5.5 如何修正首次未绑核的42.12%结果

| 阶段 | 线程允许CPU | TX kick变化 | Guest TX IRQ变化 | IPI变化 |
|---|---|---:|---:|---:|
| 首次对照 | 两线程均为0–5 | 增加3.782% | 增加1.829% | 减少42.122% |
| 固定布局复测 | ioeventfd为1、vhost为0 | 减少0.485% | 减少0.349% | 减少0.364% |

首次ON组IPI主要集中CPU4；固定布局后，两组IPI均主要集中CPU0、CPU1，差异明显缩小。

**修正结论：** 42.12%的IPI下降没有在固定布局中重现，不能作为EVENT_IDX的稳定独立收益。原比较混入了实际落核、运行状态或它们与通知时序相互作用的影响，尚不能精确区分各项原因。

### 5.6 为什么已开启却未明显减少通知

本地内核在OFF模式就检查`VRING_AVAIL_F_NO_INTERRUPT`；ON模式改用`used_event`和`vring_need_event()`。所以OFF／ON比较的是两套判断方式，而不是“完全没有抑制”与“开始抑制”。fileciteturn97file0L20-L41

后端重新启用通知时，EVENT_IDX分支更新：

```c
vhost_update_avail_event(vq, vq->avail_idx);
```

它不是强制“每N包再通知”的固定批量设置。若工作供给细碎、队列经常需要等待下一批，开启后仍可能接近每包一次kick。**这与本次数据相符，但本轮未采具体批次分布，不能当成已完成的批次原因归因。**fileciteturn97file0L93-L114

对仍然发出的kick，EVENT_IDX不会绕过普通client处理或删除completion等待。**kick几乎没少、后续交接结构也没变，因此本轮IPI几乎没少，与已有机制一致。**

本阶段结论是“当前场景未观察到明显通知数量收益”，不是“功能未开启”“内部从未抑制过任何通知”或“所有负载均无效”。同样，限速400 Mbps的结果不能判断最大带宽变化。

## 6. 三项调查的综合判断

| 问题 | 已获得的答案 |
|---|---|
| 为什么异步能明显提速，而EVENT_IDX改善小？ | 异步改变通知交接和完成路径；EVENT_IDX只决定部分通知是否必要。当前负载的kick数量没有明显减少，因而没有明显降低普通client的交接活动 |
| 目前是否已通过poll取得收益？ | **没有。** DSM定时poll和vhost忙轮询均未开启，已有提速不能归给它们 |
| EVENT_IDX是否主要优化物理eth0中断？ | **不是。** 它作用于virtqueue两向通知，物理eth0 IRQ不是直接对象 |
| EVENT_IDX对IPI是否完全无效？ | 不能这样概括。kick显著减少时可能间接减少IPI；本轮固定布局只观察到约0.364%的IPI差异 |
| 是否已证明整个优化方案无丢包、无可靠性风险？ | **没有。** asyncio 940 Mbps仍有0.012958%丢包；重启／重绑、队列满、异常恢复等尚未完成工程验收 |
| 能否宣布asyncio＋EVENT_IDX优于asyncio单独开启？ | **不能。** 当前完整的EVENT_IDX固定绑核对照声明为client路径，没有提供同等完整的asyncio组合对照 |

## 7. 当前取舍与后续工作

**主线保留asyncio＋vhost。** 保持已验证的参数顺序，优先处理剩余丢包、生命周期和恢复可靠性。源码审查中提出的异步登记返回值、队列错误及资源释放问题，修复状态尚未全部确认，不能因吞吐达标而忽略。

**EVENT_IDX作为次级选项。** 在当前普通client、400 Mbps场景下，不将其视为解决跨核交接问题的核心措施；保留试验代码和结果，其他负载或asyncio组合需要时再独立评价。未验证收益前，不必为了减少IPI而默认要求开启。

**主动poll作为未验证候选。** 若后续确有研究需要，应区分DSM用户态定时poll与内核vhost busy polling，只选择实际适用的路径，并单独衡量CPU／实时性代价，不与其他优化同时改动。

---

## 资料来源与归档说明

本文直接依据当前对话中的源码、初始化日志和测试输出整理。未重新测量，未使用新的外部性能数据。

| 资料 | 本文使用内容 |
|---|---|
| 用户提供的DSM `iothread.c`、`virtio-net.c`、`vhost.c`、`virtio.c` | 参数解析、iothread与后端类型关系、poll配置、EVENT_IDX能力协商 |
| 用户提供的CCM `ioeventfd.c`、`ioreq.c` | client完成顺序、asyncio token消费和eventfd signal |
| 已提供的HOS `vmm_u_ioreq.c.txt` | 普通请求completion等待、异步请求成功提交及满队列重试 |
| 已提供的Linux `vhost.c.txt` | EVENT_IDX／flags判断及通知后端、Guest的相关代码 |
| 成功启用asyncio后的IOEM_CFG／VQMAP及三项600秒iperf结果 | 异步路由确认、实际吞吐与丢包 |
| EVENT_IDX未绑核与固定绑核feedback、IPI分CPU统计、PC日志 | 实际通知数量、CPU布局、IPI与丢包对照 |
| `eventidx_count.sh`、`eventidx_report.py`及输出说明 | 采集口径、归一化方法、REVIEW限制 |

**最终结论：异步已有明确吞吐效果；主动poll未开启、未验证；EVENT_IDX已开启，但在固定布局的普通client等负载试验中，未显示明显通知抑制收益。**

# 第四轮：特征状态、CCM处理耗时、vhost TX批次与调度等待

## 1. 目标及证据边界

保持vhost开启。本包**不改变**EVENT_IDX、busy polling、CCM client/asyncio、亲和性或任何网络参数。
先测三件事：

1. Android协商特征与运行中vhost TX队列的EVENT_IDX、packed及busyloop状态。
2. CCM普通handler的锁获取/匹配/signal经过时间，以及vhost每次handle_tx的处理量、时间。
3. 独立短窗口内两个目标任务的waking→wakeup→switch-in时间。

第三项采用已有tracepoint，不新增调度器打点。不把时间称为纯IPI延迟，也不称为I/O请求完成延迟。
完整的dispatcher发布→client取请求→请求完成必须按本地请求身份/代次配对；本包没有拿未提供的CCM ioreq实现拼出一个假定补丁。

## 2. 文件

| 文件 | 用途 |
|---|---|
| read_virtio_features.sh | Android只读检查，首字符bit0的features格式 |
| notify_round4_probe.h | 模块内局部统计和抽样计时；CCM与vhost-net各自独立一份 |
| integration_ccm.c.txt | 按用户实际CCM handler变量写的插入片段 |
| integration_vhost_net.c.txt | 5.15风格handle_tx包装及两处调用点 |
| integration_config.c.txt | 可选控制路径配置日志，不改业务 |
| capture_n4.sh | 3秒窗口，停止后延迟输出 |
| capture_sched_wait.sh | 另一次测试使用独立ftrace instance采集0.10秒 |
| analyze_sched_wait.py | PC解析有效任务唤醒/调度配对，输出CSV/JSON |
| selftest.py | PC运行的解析器合成输入测试 |
| VALIDATION.txt | 实际完成的验证范围 |

这是插入式调试代码，不是对任意厂商源码直接可应用的完整diff。保留厂商函数签名、锁、对象生命周期及所有业务调用。部署CCM模块和vhost-net实际产物；仅更新kernel不保证更新rootfs里的模块。

## 3. 首先只读确认EVENT_IDX

Android运行：

```sh
sh read_virtio_features.sh eth0 > /data/local/tmp/virtio_features.txt
cat /data/local/tmp/virtio_features.txt
```

脚本沿eth0/device找到实际virtio设备，保留driver/device/status信息，再解码features。它是逐bit字符串，**从左向右bit0、bit1……**；不是通常的最高位在左二进制数。bit29是第30个字符。核对device为网络设备、driver为virtio_net。

EVENT_IDX=1说明Guest特征集合包含它，仍应与下面后端运行时CONFIG对照；两端不一致属于优先调查的协商问题。
RING_PACKED=1时不能用split-ring的avail/used结构解释，且本包后端units/batch统计会标记诊断错误，不产生虚假的“零包批次”结论。

## 4. CCM插入

把头文件放到实际CCM ioeventfd.c同目录，仅include一次，不放到全局ccm_drv.h。
按integration_ccm.c.txt加入局部变量并替换handler末尾的锁/match/signal区域。原来的MMIO/PIO解码、READ分支、eventfd_signal签名和返回逻辑不改。

参数预计位于：

```
/sys/module/ccm_proxy/parameters/n4_run
/sys/module/ccm_proxy/parameters/n4_report
/sys/module/ccm_proxy/parameters/n4_tid
/sys/module/ccm_proxy/parameters/n4_addr
/sys/module/ccm_proxy/parameters/n4_shift
```

读取前stop；n4_run=1会清空旧统计并开始新epoch。地址过滤使用**本次VQMAP/MATCH已对应的实际TX地址**。0x6020003004只是当前上传结果的地址，不保证换配置后仍相同。n4_tid选择当前ioeventfd TID；0代表不按TID过滤。

阶段解释：

| 输出阶段 | CCM含义 |
|---|---|
| elapsed | 从原mutex_lock前至原mutex_unlock后 |
| begin_to_mark0 | 获取mutex所经过的时间，包含调度等待，不是纯自旋/锁CPU成本 |
| mark0_to_mark1 | 匹配查找阶段 |
| mark1_to_mark2 | 匹配判断、旧对象probe关闭分支、eventfd_signal或未匹配分支 |

units为成功匹配通知次数，zero batch为未匹配；这一模块不是报文批处理计数。计时覆盖handler锁区域，不包括等待dispatcher发布、client被调度前的时间，也不包括handler返回后的完成通知。

## 5. vhost-net插入

在drivers/vhost/net.c include头文件一次。按integration_vhost_net.c.txt：

- 完整保留handle_tx()。
- 在其定义后、kick/net回调定义前添加n4_handle_tx()包装函数。
- 仅替换handle_tx_kick和handle_tx_net中的原handle_tx(net)调用，分别传origin=1/2。
- 不全局替换，否则会导致包装器递归。若本地有额外调用者，显式记录其用途。

预计参数目录：`/sys/module/vhost_net/parameters`。若不同，以
`find /sys/module -path '*/parameters/n4_run'`为准。

运行时报告：

```
CONFIG,event_idx=...,packed=...,busyloop_us=...,ring_size=...,changes=...
ORIGIN,kick=...,backend_ready=...
```

这是选定worker实际处理TX时读到的队列状态。changes非0说明存在状态变化或混入多个不同配置对象，不能当成稳定实验。

`units`是split `last_avail_idx`的**净推进量**（可用环描述符链头），不是descriptor元素总数，不是成功发到线上的包数。后端失败退回描述符可能影响净推进量。仅在稳定设备生命周期、单worker序列处理、有界批次下使用；如果厂商改成无界单次消耗>=65536头，应改为内部显式计数。packed=1或明显异常差值时errors增加，units无效。

零推进不唯一代表队列空；也可能是backend不存在、前置检查失败或重试。零多时下一步再在原handle_tx各出口添加原因计数，不能直接判定没有输入。

elapsed包括handle_tx原来的锁、处理、TAP调用、可能的busy wait和抢占，不是纯vhost CPU计算时间。它不包括work入队后worker尚未开始执行的时间。

## 6. 采集步骤（先不改三个优化机制）

### 6.1 准备

关闭旧探针和全量跟踪，先于压力测试完成：

```sh
echo stop > /proc/ipi_origin
echo 0 > /sys/module/ccm_proxy/parameters/ioem_run
find /sys/module -path '*/parameters/n4_run'
ps -eLo pid,tid,psr,comm | grep -E 'ioeventfd|vhost-'
grep -w eth0 /proc/interrupts
```

不要运行旧eth0逐秒采集脚本。不要执行全局ftrace清理破坏其他会话；本包新脚本只操作自身实例。
保存同一次初始化VQMAP/IOEM_CFG/NETNEG。记录eth0实际IRQ编号和effective affinity；不能沿用旧131/134。CPU编号为ServerVM内编号，不与Android CPU自动对应。

### 6.2 两个状态先做

| 状态 | ioeventfd | vhost | eth0 IRQ |
|---|---:|---:|---:|
| A通知跨核 | CPU1 | CPU0 | CPU0 |
| B通知同核 | CPU0 | CPU0 | CPU0 |

IRQ保持不动，只改变ioeventfd的允许CPU。kworker不强绑。可选C在B基础上只将eth0 IRQ改成CPU1，用于独立调查物理IRQ；不要混入A/B第一轮。

每个状态先做**所有探针关闭**的60秒基线，然后独立再跑同一条命令采集。Android用同一个3.17.1+二进制、相同源端口/发送CPU（原来有则保留），不改变-l/-b、不加-R：

```sh
./iperf3 -p 5201 -c 192.168.1.1 -b 1000M -t 60 -l 1400 -i 10 -u
```

出现第一条10秒输出后，在ServerVM执行，替换实际TID：

```sh
TX_ADDR=0x6020003004 CCM_DIR=/sys/module/ccm_proxy/parameters \
VHOST_DIR=/sys/module/vhost_net/parameters REPORT_DELAY=60 \
sh capture_n4.sh IOEVENT_TID VHOST_TID A 3
```

脚本采集3秒后停止，再等待60秒输出，非卡死。label填A或B的实际配置。report delay并非自动等待iperf结束，更长压测需增加。
SAMPLE_SHIFT=10表示每CPU每1024个选中调用抽样耗时，COUNT仍全量；SAMPLE_SHIFT=21用于只计数对照。采样为确定性间隔，不是均匀随机；短窗口极值不代表长期最坏情况。

观察计数开启后是否明显改变基线。若影响显著，不把本轮吞吐作为验收；使用只计数/缩小范围后继续定位。两模块各自start/stop，时间窗口不完全相同，不能强行一一对应。

### 6.3 另一次压力中做短调度等待跟踪

此时n4_run、ioem_run及ipi_origin均关闭，不与上一步叠加。
Android重新运行同一60秒上行，10秒后ServerVM执行：

```sh
sh capture_sched_wait.sh IOEVENT_TID VHOST_TID A 0.10
```

仅跟踪两个TID的sched_waking、sched_wakeup、sched_switch，全部CPU可记录；使用独立instance和mono时钟。实际trace持续时间受shell唤醒影响，不保证精确100ms。stop后延迟60秒再读，检查每CPUoverrun等指标。截断事件不凭空拼接。

结果拷贝到PC后：

```sh
python3 analyze_sched_wait.py /实际采集目录 IOEVENT_TID VHOST_TID
```

得到wait_pairs.csv和wait_summary.json：

- waking_to_wakeup：从唤醒发起事件到激活事件，包含锁、入队、TTWU处理等，**不是纯IPI延迟**。
- runnable_to_run：从wakeup事件到第一次switch-in，表示这一唤醒周期的可运行等待，不含以后所有抢占时间。
- waking_to_run：上述两段之和。
- 两个TID彼此独立配对，不假装配对成同一个I/O请求。
- 缺waking的窗口边界记录只能算wakeup→run；有丢事件时拒绝计算正式汇总。重复/边界等诊断仍须查看。
- 时戳输出精度通常到微秒，纳秒列只是统一单位，不表示ns测量精度。

## 7. 应反馈的文件

每个A/B状态提交：

1. Android virtio_features.txt和无探针/有探针的完整iperf结果。
2. n4目录：ccm_n4.txt、vhost_n4.txt、context_before/after.txt、config_logs.txt。
3. 调度等待目录（另一次测试）：trace.txt、cpu*_stats.txt、三个event format、context.txt、wait_summary.json和wait_pairs.csv。

保留事件窗口与完整60秒结果的区别；同核/跨核前后不更改EVENT_IDX、busyloop或client/asyncio。

## 8. 如何根据结果决定优化

- 两端EVENT_IDX不一致：先核对DSM最终offer、协商结果、VHOST_SET_FEATURES实际mask。不在已运行队列中强行翻位。
- 两端都0：确认端到端支持后独立测试EVENT_IDX；0并非完全没有通知抑制，split仍有flags机制。
- 两端都1、每批头数仍很小：开启机制不等于能合并稀疏到达；查空队列睡眠与上游请求供给。
- busyloop_us=0：该队列的vhost busy-loop timeout配置为0；vhost_poll_wakeup仍然是正常的事件驱动回调，不是忙等。
- busyloop_us>0：只证明配置非0，是否实际进入以及忙等命中率仍需对对应分支计数。
- CCM handler很短、调度等待大：优先讨论跨上下文交接和client完成协议。
- CCM锁/匹配/signal段慢：按已定位区间继续拆分。
- vhost handle_tx经过时间大：可能包含锁、TAP/bridge后续处理和抢占，不能直接叫vhost算法慢。
- units/ends小：提供了批次规模证据，但不能直接称每包一唤醒或用单位比值当通知抑制率。

busy polling也不在本轮盲开；老版本实现可能在busy loop里禁止抢占。用户ServerVM为RT内核，应核对本地实现、CPU占用和实时负载影响。

ASYNCIO改造在消费者代码/完成语义/引用生命周期未核对前不提供盲改flags补丁。尤其本地配置只向HOS传addr、type、eventfd token，len/data匹配和队列消费语义不能默认与client相同。

## 9. 公开代码参考（与本地事实分开）

- Linux5.15特征sysfs显示： https://raw.githubusercontent.com/torvalds/linux/v5.15/drivers/virtio/virtio.c
- Guest split kick决策： https://raw.githubusercontent.com/torvalds/linux/v5.15/drivers/virtio/virtio_ring.c
- Virtio1.2通知抑制规范： https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html
- vhost队列通知控制： https://android.googlesource.com/kernel/common/+/ad06eaf051cd0bdfd330f378c91f537107ce938e/drivers/vhost/vhost.c
- vhost busy-loop参考： https://android.googlesource.com/kernel/common/+/89928190f5b0cb4eb2eede797030f8e9e17c3c4f/drivers/vhost/net.c
- Linux event tracing： https://www.kernel.org/doc/html/v5.15/trace/events.html

这些公开版本仅说明机制和接入依据，不能替代本地CCM/HOS客制化源码。

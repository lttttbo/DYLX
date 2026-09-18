# 先确定 IPI1 来源：ServerVM call-function 队列打点

## 1. 范围

这是独立于 `net_path_probe_v1` 的一次来源诊断。不测网络函数耗时，不修改 Android，不关闭 vhost，不更改 CPU 亲和性或调度策略。只修改 ServerVM 的 `kernel/smp.c`，以及新增同目录头文件。

公开参考基线为 Linux v5.15：

- https://raw.githubusercontent.com/torvalds/linux/v5.15/kernel/smp.c
- https://raw.githubusercontent.com/torvalds/linux/v5.15/kernel/sched/core.c
- https://raw.githubusercontent.com/torvalds/linux/v5.15/kernel/irq_work.c

厂商 5.15.158-rt76 可能改过该路径；以下是定位明确的插入点，不是声称可以无冲突应用于任意厂商树的补丁。保留原有锁、队列顺序、IRQ状态、回调及所有原逻辑。临时调试代码应在来源确认后移除。

验证：辅助头文件和四个 hook 的包含测试模块已在本环境 Linux 6.12.96 amd64 内核头文件上编译并通过 modpost；未加载测试模块，未在用户 ARM64 5.15.158-rt76 内核运行。没有声称完成该厂商内核的集成编译或功能验证。

前置配置：CONFIG_SMP=y、CONFIG_PROC_FS=y。函数符号输出依赖可用的内核符号信息；即便没有符号名仍保留地址，可用本次构建的 vmlinux/System.map 解析。

## 2. 为什么这比继续 sched_waking 更直接

之前的网络边界探针主要回答“哪里慢”，不识别 IPI1 正在消费什么。

本探针在接收端取出 call_single_queue 后、任何 callback 执行和对象解锁之前，识别每个真实队列项：

- ASYNC、SYNC：统计 callback 函数地址/符号；
- TTWU：统计真实 task_struct 的 TID/comm，而不是猜测 sched_waking 的预选目标 CPU；
- IRQ_WORK：统计真实 irq_work callback；
- OTHER：只计数，绝不把未知载荷当函数指针解引用。

三个量必须分开：IPI handler 进入次数、取队列批次数、队列项数。不能用“目标任务项数 / IPI次数”声称逐个IPI已经归因。一个批次可有多个任务或混合类型。

同时区分：在 generic call-function IPI handler 内取得的队列项（context=ipi），以及 idle/hotplug 等非该入口的队列清空（context=other）。不要把后者算作硬件IPI接收。

## 3. 接入：只改 ServerVM kernel/smp.c

### 3.1 新增头文件

把包内 `ipi_origin_probe.h` 复制到：

```text
<ServerVM Linux source>/kernel/ipi_origin_probe.h
```

在 `kernel/smp.c` 的原有 includes 后添加一次：

```c
#include "ipi_origin_probe.h"
```

不需要 Makefile 目标，不要编成独立模块，也不要在其他 C 文件重复包含。

### 3.2 A/B：标记真实 generic call-IPI handler 范围

定位：

```c
void generic_smp_call_function_single_interrupt(void)
```

在函数执行语句开头增加：

```c
ipio_irq_enter();
```

在原来的 `flush_smp_call_function_queue(true);` 返回后、函数退出前增加：

```c
ipio_irq_exit();
```

保留原 debug/sequence 代码。该函数原合同是 IRQ 已关闭，不增加新的 IRQ enable/disable。如果厂商函数有提前 return，每条出口都必须配对调用 `ipio_irq_exit()`，不要把 helper 插到只有某一分支能执行的位置。

本地 ARM64 IPI_CALL_FUNC 分支应最终调用到此 generic handler；核对这个调用关系。如果厂商绕过此入口，本探针 `irq_handler_calls` 与 /proc/interrupts 不会对应，需调整范围标记，而不是继续强行比较。

### 3.3 C：在已摘下的队列批次上识别工作类型

定位：

```c
static void flush_smp_call_function_queue(bool warn_cpu_offline)
```

在原有：

```c
entry = llist_reverse_order(entry);
```

后面立即添加：

```c
ipio_note_batch(entry);
```

必须满足：

1. 已完成 `llist_del_all()`，当前CPU拥有这批待消费节点；
2. 尚未执行 callback、`csd_unlock()`、任务激活或任何允许对象复用的操作；
3. IRQ仍关闭；
4. 每批只调用一次，包括空批次。

不要在普通callback已执行之后再读取 `csd->func`；异步CSD可能已被复用。不要在每个原循环分别调用整批扫描，以免重复计数。

只做以上 A/B/C，已经能够直接确定接收端工作类型、普通callback、TTWU目标任务，适合第一轮。

### 3.4 D（可先装入）：记录实际入队源、目标和caller

定位：

```c
void __smp_call_single_queue(int cpu, struct llist_node *node)
```

在执行语句最前面、任何 debug提前分支和 `llist_add()` 之前添加：

```c
ipio_note_enqueue(cpu, node, (unsigned long)_RET_IP_);
```

所有元数据必须在发布节点之前读取。不能在 `llist_add()` 后再读取节点类型、任务或函数指针，因为目标CPU可能已经处理并释放/复用对象。

本 hook 只在 `start_sources` 模式实际计数，普通 `start` 不记录源端明细。

**源端覆盖限制：** `smp_call_function_many*()` 某些路径直接入队，可以不经过 `__smp_call_single_queue()`。所以 ENQ 是 single-queue入口请求计数，不是全系统所有call-function入队，更不是实际IPI发送次数。接收端分类仍覆盖到达该接收队列的这些工作。若非TTWU callback占主导，下一步对该callback对应的具体上游API定向增加caller采样。

**上下文限制：** ENQ中source_tid是入队时current。context=hardirq/softirq时，它可能只是被打断的任务，不能据其comm直接认定业务发起者。caller只记录直接调用地址，不是完整调用栈。

## 4. 控制接口

重新编译并启动测试ServerVM后：

```bash
ls -l /proc/ipi_origin
```

接口仅root可读写。支持：

```text
start          清零并启动接收端来源统计
start_sources  清零并启动接收端统计+源端入队明细
stop           停止并等待正在进行的短统计更新完成
```

每次start都会清空上一轮结果。**采集时不允许读取报告**，避免周期轮询污染性能；未stop读取返回EBUSY。

统计路径不执行printk、动态内存分配、栈展开或符号解析，不调用smp_call_function来同步自己的计数。使用每CPU私有计数和短raw spinlock。控制和报告阶段才执行清零、快照、符号格式化。

它仍有额外队列扫描、哈希查找和短锁开销，不是零扰动。只用于来源诊断，不用于最终吞吐验收。本阶段先别同时开启 net_path_probe 或大范围 ftrace。

## 5. 第一轮：先确认真实类型与目标对象

保持当前vhost开启，使用已有低性能布局。准备好Android命令后，ServerVM运行：

```bash
echo start > /proc/ipi_origin
```

在Android运行与之前相同版本、相同CPU/源端口设置的UDP上行。例如保持原有参数，仅缩短第一次定位窗口：

```bash
./iperf3 -p 5201 -c 192.168.1.1 -u -4 -b 1000M -l 1400 -t 20 -i 10
```

若此前用了 -A 或 --cport，继续使用同一取值，不要为本轮临时改变。以上只是命令结构示例。

iperf结束后ServerVM运行：

```bash
echo stop > /proc/ipi_origin
cat /proc/ipi_origin > /tmp/ipi_origin_abnormal.txt
```

需要的话，在启动和停止前后各读取一次 /proc/interrupts 用于交叉核对，不能拿相邻但不相同的窗口要求完全相等。

先检查CPU行的rx_key_overflow和enqueue_key_overflow。只要非零，对象归因明细就不完整；类型总计仍保留。减少背景任务、缩短窗口或增大IPIO_BITS后重测，不要把overflow默默当成零。

## 6. 第二轮：再看真实入队源

第一轮若TTWU占主导，用相同配置：

```bash
echo start_sources > /proc/ipi_origin
# Android执行同一个测试
# 测试结束后：
echo stop > /proc/ipi_origin
cat /proc/ipi_origin > /tmp/ipi_origin_sources.txt
```

ENQ会直接给出源CPU、实际入队目标CPU、源TID/context、目标TID、调用点。结合之前sched_waking，而不是再重复仅靠其target_cpu推断。

TTWU的func字段为0，是有意设计：task wake节点不是通用call_single_data，不能凭空读取所谓csd->func。目标任务在RX/ENQ字段中明确给出。

## 7. 输出说明

不同类型行有自己的字段布局，行首#为说明。

```text
CPU,cpu,irq_handler_calls,rx_key_overflow,enqueue_key_overflow
ITEMS,cpu,context,ASYNC,SYNC,IRQ_WORK,TTWU,OTHER
BATCH,cpu,context,mask,batches
RX,cpu,context,type,target_tid,target_comm,func_addr,func_symbol,count
ENQ,src_cpu,dst_cpu,type,source_tid,source_comm,context,target_tid,target_comm,func_addr,func_symbol,caller_addr,caller_symbol,count
```

BATCH mask：ASYNC=1，SYNC=2，IRQ_WORK=4，TTWU=8，OTHER=16。

- 0x0：取到空队列；
- 0x8：该摘取批次只有TTWU任务；
- 0x1：该批次只有普通ASYNC callback；
- 0x9：同一批次混合ASYNC和TTWU。

BATCH是摘取批次，不能在未检查本地调用结构时一律等同一个独占类型的硬件IPI。接收入口计数、队列项数、入队请求数不同是允许的。

comm使用首次出现时的尽力读取标签（不拿task_lock）；以TID和当前进程身份核对。短窗口中避免任务销毁/重启和PID复用。输出中的逗号、引号及控制字符会替换为下划线。

## 8. 判定标准

### TTWU占主导

ITEMS中ipi上下文TTWU显著多于其他类型，且RX目标任务主要是ioeventfd/vhost：可以直接认定大量call-function工作用于激活这两个任务，不再只是“sched_waking数量相近”的推断。

若BATCH大部分为0x8，进一步说明这些取队列批次主要服务远程任务唤醒。

第二轮ENQ再确定actual source CPU / target CPU。只有context=task时，source task作为发起者才比较直接；中断上下文需继续取样调用栈。

### ASYNC/SYNC占主导

直接看RX的func_symbol。该符号就是进入待消费队列的callback；不凭空猜测是RPS、TLB或vhost。然后在该函数及其上游调用点定向排查。

### IRQ_WORK占主导

直接看实际work->func。仅统计irq_work_single()入口只能得到通用包装器，不能说明真正工作是什么。

### 空批次/非IPI drain很多

需考虑通知合并、提前清空队列、idle/hotplug清空及测量边界，不能把“IPI次数多于任务项数”直接解释为丢失回调或IPI故障。

### 归因与性能是两件事

确认IPI内处理TTWU，只证明用途。要证明它是吞吐损失的主导成本，还需结合现有亲和性干预及后续等待/批量化分析；本包不测IPI延迟，不给出耗时比例。

## 9. 建议反馈

只需提供异常状态下 /proc/ipi_origin 的完整文本与该轮iperf最终结果。先看第一轮RX分类，再决定是否需要start_sources，不必先修改virtio_net/tun/stmmac三条通路。

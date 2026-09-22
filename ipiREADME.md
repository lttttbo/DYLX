# 第三轮：确认唤醒业务栈及网络通知对象

## 1. 本包回答什么

保持vhost开启，不修改CPU亲和性、调度策略或网络性能参数。沿此前已经确认的两段TTWU，补充：

1. 发起唤醒时的少量调用栈，用于识别实际work function和业务唤醒函数。
2. ioeventfd实际匹配的I/O写请求、eventfd对象及次数。
3. 该eventfd绑定的vhost virtqueue、worker和kick处理函数。

**调用栈回答“经过哪些函数”，通知对象映射回答“哪个VM/哪次I/O写、哪条设备队列”。只抓调用栈不能自动证明请求属于网络TX。**

不重新采集全量sched_waking，不在热路径逐次printk，不新增独立内核模块。

## 2. 文件与验证范围

- `ipi_origin_probe.h`：替换已经接入的v1头文件。保留start/start_sources/stop和原计数，新增start_stacks命令。
- `ipi_origin_probe_v1_to_v2.patch`：仅头文件差异，供审核；替换文件与应用patch二选一。
- `ioeventfd_object_probe.h`：在本地ioeventfd handler所在C文件包含一次，增加对象计数和sysfs参数。
- `insertion_snippets.c.txt`：ioeventfd handler及vhost注册路径的插入片段。
- `collect_notify_chain.sh`：可选的短窗口采集脚本，不修改亲和性、不轮询流量。

两个辅助头文件以及其调用入口已用本环境 Linux 6.12.96 amd64 头文件构建包含测试模块，通过编译及modpost。没有加载模块；没有完成用户 ARM64 5.15.158-rt76 厂商内核的集成编译或运行验证。vhost/ACRN片段按公开代码的同类位置提供，须保留本地原逻辑。不是可对任意厂商树直接应用的完整diff。

建议配置：CONFIG_SMP=y、CONFIG_PROC_FS=y、CONFIG_STACKTRACE=y、CONFIG_KALLSYMS=y。栈完整性还取决于架构unwinder、frame pointer和优化；不要把缺失/inlined的栈帧当成函数未执行。

## 3. 改动A：扩展原IPI探针，保存有限调用栈

将新头文件复制为：

```text
<ServerVM内核>/kernel/ipi_origin_probe.h
```

原`kernel/smp.c`中的include以及四个hook全部保留一次，不需新增第五个hook：

```c
#include "ipi_origin_probe.h"

/* generic_smp_call_function_single_interrupt(): */
ipio_irq_enter();
/* 原flush及其原有逻辑 */
ipio_irq_exit();

/* flush_smp_call_function_queue(): llist_reverse_order之后 */
ipio_note_batch(entry);

/* __smp_call_single_queue(): 在发布node之前 */
ipio_note_enqueue(cpu, node, (unsigned long)_RET_IP_);
```

新增控制命令：

```text
start_stacks <worker_tid> <ioevent_tid> <vhost_tid>
```

例如当前TID仍为79、198、1057时：

```bash
echo 'start_stacks 79 198 1057' > /proc/ipi_origin
```

- edge=0：指定worker -> 指定ioeventfd的任务上下文TTWU。
- edge=1：指定ioeventfd -> 指定vhost的任务上下文TTWU。
- worker_tid=0：edge=0放宽为任何任务上下文唤醒指定ioeventfd，适合worker在重启后改变的情况；输出保留真实源任务。不是只记录PID0。
- **每个源CPU、每条edge最多保存4个栈，每栈最多32帧。** 六CPU理论上限48个栈；如果两条edge各只有一个源CPU，一共最多8个。
- 只保存当前源任务的调用栈，不读取目标线程栈；不用dump_stack或stack_trace_print。
- 满额后不继续展开栈，原RX/ENQ累计计数仍进行。
- 这是首次命中样本，不是均匀随机采样，更不能用于推算每条调用栈的出现频率。压力稳定后再开启。
- 栈采集位于当前探针私有短锁和IRQ关闭区域内，只执行上述有限次数，但仍有测量扰动。
- 无CONFIG_STACKTRACE时，start_stacks返回EOPNOTSUPP，原统计模式可继续使用。

停止后报告新增：

```text
STACK,cpu,edge,sample,src_tid,src_comm,dst_cpu,target_tid,target_comm,nr_frames,time_ns
FRAME,cpu,edge,sample,frame,pc,symbol_with_offset
```

frame=0靠近探针；沿更大的frame序号向上寻找业务调用者。不要预先认定某个函数名必然出现。edge=0的栈通常可在process_one_work下面找到实际被调用的work function。

若edge=0栈截断、未包含work callback，则再用workqueue_execute_start事件直接读function字段，并按源TID过滤。已有ftrace可作为备用，不必同时开启两套高频trace。

## 4. 改动B：计数ioeventfd实际匹配的请求

把`ioeventfd_object_probe.h`复制到本地实现ioeventfd handler的同目录，在该C文件include一次。公开位置是`drivers/virt/acrn/ioeventfd.c`；厂商改名则选择实际函数文件，不要人为另写第二套handler。

在原来的匹配成功分支中，紧邻原eventfd_signal之前添加一行：

```c
p = hsm_ioeventfd_match(client->vm, addr, val, size, req->type);
if (p) {
        ioem_note(client->vm->vmid, req->type, addr, size, val, p->eventfd);
        eventfd_signal(p->eventfd, 1); /* 保持本地原调用及参数，只调用一次 */
}
```

**如果本地是单参数eventfd_signal，保持单参数；不要按片段改变API。若本地字段名称不同，传入同义的原局部值。** 保留原锁、匹配条件、请求完成及所有返回处理。

本探针：

- 只观察已经匹配成功且即将执行原signal的请求。
- 记录实际请求addr/size/value，而不是用配置中的匹配值替代实际写值。
- 按CPU、源TID、VM、type、addr、len、data、eventfd_ctx归类。
- 计数是`matched_signal_attempts`，不是包数、TTWU数或成功发出IPI数；不改变或额外调用eventfd_signal。
- 未匹配请求和被原handler忽略的读请求不在该计数中，不能据此声称统计了所有I/O请求。
- 每CPU64个key，满时保留total和overflow，不能把溢出忽略。
- 内核对象地址只用于同一次对象生命周期内关联；报告中不持有引用，也不在停止后解引用。

控制参数所在模块名以本机为准：

```bash
find /sys/module -path '*/parameters/ioem_run'
```

例如找到`/sys/module/acrn/parameters/ioem_run`，设：

```bash
IOEM=/sys/module/acrn/parameters
echo 1 > "$IOEM/ioem_vmid"    # 本地VM ID确为1时；-1表示所有VM
echo 1 > "$IOEM/ioem_run"     # 清零并启动
# 稳定压力窗口
# 结束后：
echo 0 > "$IOEM/ioem_run"
cat "$IOEM/ioem_report"
```

只有停止后允许读取report。不要运行时改vm过滤；本轮避免Guest/设备重启、注册注销和FD重绑。

输出：

```text
MATCH,cpu,tid,vmid,type,addr,len,data,eventfd_ctx,count
```

若`truncated_rows>0`，停止状态下可按CPU读取：

```bash
echo 0 > "$IOEM/ioem_cpu"; cat "$IOEM/ioem_report"
# 对其他实际CPU重复
echo -1 > "$IOEM/ioem_cpu"
```

表项按hits递减显示；truncated_rows表示报告页未能显示的行，key_overflow表示采集时归类表容量不足，两个概念不同。

## 5. 改动C：在vhost注册kick时记录对象映射

在`drivers/vhost/vhost.c`的`vhost_vring_ioctl()`中，完成原来的`vhost_poll_start()`及返回处理后、最终释放`vq->mutex`之前，加`insertion_snippets.c.txt`中的C段。

该段只在成功处理`VHOST_SET_VRING_KICK`时记录：

```text
VQMAP bind tgid=... tid=... dev=... q=... vq=... worker=... kickfd=... ctx=... kick_fn=...
```

字段意义：

- ctx：通过eventfd_ctx_fileget(vq->kick)取得的eventfd内核对象，打印后配对put。
- q：这个vhost device中的实际virtqueue索引。
- worker：该device的worker任务ID。
- kick_fn：该virtqueue实际注册的handle_kick符号，如handle_tx_kick/handle_rx_kick。
- dev/vq：区分多个vhost设备或队列，不能只用q编号。

不要复用/覆盖函数原有的ctx变量，不修改原fput/put次数，额外get有自己配对的put。这里是初始化/重绑路径，不是每个数据包打印；测试开始前保留日志即可。

这段明确依赖5.15风格的`d->worker`字段。后续内核若改为不同vhost任务结构，需要按实际字段调整，不能直接套用。

**作用：** 同一轮的运行期MATCH中`ctx=X`，与初始化VQMAP中`ctx=X、worker=<目标TID>、kick_fn=handle_tx_kick`匹配，才能确认实际写请求接到了该vhost-net TX通知队列。`handle_rx_kick`是Guest提供RX buffer的通知，不是Guest TX通知。

不能只凭线程名中的数字、某一个FD数值、data=1或q=1来认定网络TX。FD受进程/文件表和复用影响，eventfd对象才是跨这些位置的关联键。

## 6. 测试顺序

一次构建接入A/B/C后启动调试ServerVM，DSM按原配置启动vhost后端。记录本次初始化映射：

```bash
dmesg | grep 'VQMAP ' > /tmp/notify_vqmap.txt
```

用与前两轮相同的可复现跨核布局。不要为了本次采集再移动eth0 IRQ，不要开旧的eth0周期采样脚本，也不要开net_path_probe。

先确认当前实际TID，重新启动后旧TID不再可靠。单VM示例：

```bash
ps -eLo pid,tid,psr,comm | grep -E 'ioeventfd|vhost-|kworker/0:'
```

如果TID仍为79/198/1057，并且IOEM参数目录已知，可用包内脚本：

```bash
# 先在Android启动原有60秒UDP上行命令，运行约10秒。
# 再在ServerVM执行，不修改亲和性：
IOEM_DIR=/sys/module/acrn/parameters \
sh collect_notify_chain.sh 79 198 1057 3
```

不知道新worker TID时，第一参数使用0：

```bash
IOEM_DIR=/sys/module/acrn/parameters \
sh collect_notify_chain.sh 0 <本次ioeventfd_TID> <本次vhost_TID> 3
```

脚本只启动两类采集、sleep一次、停止，然后再等待60秒才读取报告；默认用于60秒iperf测试。长于60秒的测试应相应增加REPORT_DELAY，或等测试结束后再读取/传输报告。

输出目录打印在最后，其中：

```text
ipi_stacks.txt       原RX/ENQ + 新STACK/FRAME
ioeventfd_match.txt  运行期匹配通知对象及数量
vqmap.txt           同一次启动的VQMAP注册/解绑记录
context.txt         当前任务身份/允许CPU及采集参数
```

两套探针的start/stop是顺序写入，不是同一条原子操作。报告携带各自时间戳，不要求其计数严格相等。此轮是来源与对象识别，非无扰动吞吐验收。当前已有IPI总数探针仍有每次计数开销，即使栈采样已经满额也不是完全零开销。

## 7. 如何形成结论

按以下顺序验证：

1. STACK edge0：找到真实work function和唤醒ioeventfd的业务调用栈。
2. STACK edge1：确认ioeventfd handler、eventfd和vhost唤醒的实际调用关系。
3. MATCH：哪个VM/哪种I/O写/哪个ctx占主要匹配请求。
4. VQMAP：同一ctx连接哪个vhost device、worker、q和handle_kick。

例如若实际输出（不是预设结果）满足：

```text
MATCH中高频ctx=X
VQMAP中ctx=X、worker=目标vhost TID、kick_fn=handle_tx_kick
两条栈分别显示实际请求分发函数与eventfd→vhost唤醒函数
```

才可以写：高频两级任务交接与该VM的vhost-net TX kick对象相对应。

若ctx对应RX、其他设备或同时注册给多个消费者，应如实记录。多个消费者共享同一ctx时，该映射不能唯一证明某次唤醒属于哪一条queue，需要在后续vhost_poll_wakeup处定向记录poll对象和work->fn；不要随意选一条注册行。

调用栈是在发起者当前调用中采集，不跨异步线程边界：在ioeventfd唤醒vhost时，不应要求同一栈中出现未来由vhost执行的handle_tx_kick。它通过VQMAP确认。

## 8. 限制与安全

- 对象地址只能在同一启动、同一注册生命周期内对照。不要跨重启或跨解绑比较；测试期间避免设备重建，保留unbind/rebind日志。
- v2首次命中4个栈不是全调用栈频率统计；若有多条较低频分支，不能从未采到就推断不存在。
- 当前阶段不测IPI响应时间，不验证每包两次IPI，不给出性能损失比例。
- init/rebind日志及对象报告包含内核地址，仅用于受控调试环境，结案后移除，不提交生产镜像。
- 采集接口对start/stop进行保护，仍需在实验机上验证。两套helper均为调试代码，不宣称硬实时无影响。
- 如果只想先确认业务栈，可以只接入A，脚本设置SKIP_OBJECTS=1；该结果不能替代网络对象映射。

## 9. 公开参考资料

公开源码用于确认接口/结构，不代替厂商本地实现：

- 原用户探针：ipi_origin_probe_v1/ipi_origin_probe.h。
- Linux stack_trace_save：kernel/stacktrace.c；https://android.googlesource.com/kernel/common/+/35556bed836f/kernel/stacktrace.c
- ACRN ioeventfd handler/assign：drivers/virt/acrn/ioeventfd.c；https://code.googlesource.com/linux/torvalds/linux/+/84e9a2d5517bf62edda74f382757aa173b8e45fd/drivers/virt/acrn/ioeventfd.c
- vhost_vring_ioctl/vhost_poll/vhost_worker：https://android.googlesource.com/kernel/common/+/ad06eaf051cd0bdfd330f378c91f537107ce938e/drivers/vhost/vhost.c
- vhost-net handle_tx_kick/handle_rx_kick及open注册：drivers/vhost/net.c；https://android.googlesource.com/kernel/common/+/9e1410f338b57ffe97d083972e755dfa25b3d749/drivers/vhost/net.c
- Linux 5.15 eventfd get/put API：https://origin.kernel.org/doc/html/v5.15/filesystems/api-summary.html
- Linux 5.15 event trigger有限次数stacktrace：https://origin.kernel.org/doc/html/v5.15/trace/events.html

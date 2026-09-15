# ServerVM eth0 中断数量对照测试

## 1. 方向定义

以 Android 为参照，Android 运行 iperf3 客户端，PC 运行服务端：

| 测试 | Android 命令 | 主流量路径 | ServerVM 主方向计数 |
|---|---|---|---|
| UDP 上行 | `-u`，不带 `-R` | Android → tap1 → br0 → eth0 → PC | tap1 RX、eth0 TX |
| UDP 下行 | `-u -R` | PC → eth0 → br0 → tap1 → Android | eth0 RX、tap1 TX |
| TCP 上行 | 不带 `-u`、不带 `-R` | Android → tap1 → br0 → eth0 → PC | tap1 RX、eth0 TX |
| TCP 下行 | 不带 `-u`、带 `-R` | PC → eth0 → br0 → tap1 → Android | eth0 RX、tap1 TX |

`--bidir` 是同时双向，本轮不要使用。TCP 会有反向 ACK；UDP 也有控制连接，所以单向负载不代表反方向计数绝对为零。

此前 41400 与 85825 个 eth0 TX packet 的对照均为 UDP 上行，是未绑定与全链同核的对照，不是上行与下行对照。

## 2. 脚本测量什么

脚本只读取 ServerVM Linux 中 eth0 对应设备 IRQ 的计数。不会修改线程 affinity、IRQ affinity、irqbalance、网络配置或 tracefs。

`/proc/interrupts` 的 eth0 IRQ 行不区分本次 IRQ 的原因究竟是 RX、TX completion 还是其他设备状态；因此输出是“上行/下行负载期间的 eth0 IRQ 数量”，不是“纯 TX/RX 中断数量”。也不包含 Linux IPI 行或 Xvisor 内部的物理中断计数。

脚本动态识别 IRQ：以接口 action 名称以及设备 MSI IRQ 信息为依据，支持多条 IRQ；默认不使用 131、134 等固定号码，也不以宽泛关键词猜测。指定 `IRQ_LIST` 时仍需通过设备身份检查。无法识别则报错退出。

## 3. 快速使用

在 PC 上启动对应版本的服务端：

```sh
./iperf3 -s -p 5201
```

ServerVM：

```sh
chmod 755 eth0_irq_monitor.sh
sh eth0_irq_monitor.sh detect
```

先在 ServerVM 启动采集，再到 Android 启动相应方向的测试。以下 TID 来自当前记录；DSM 重启后需要重新查询。TID 参数仅用于保存状态，也可以省略，不影响 IRQ 计数。

### UDP 上行

ServerVM：

```sh
IOEVENTFD_TID=227 BACKEND_TID=1094 \
sh eth0_irq_monitor.sh capture udp_up_before up 40
```

Android：

```sh
./iperf3 -A 1 --cport 41001 -p 5201 -c 192.168.1.1 \
    -u -4 -b 1000M -l 1400 -t 60 -i 10 --udp-counters-64bit
```

### UDP 下行

ServerVM：

```sh
IOEVENTFD_TID=227 BACKEND_TID=1094 \
sh eth0_irq_monitor.sh capture udp_down_before down 40
```

Android：

```sh
./iperf3 -A 1 --cport 41001 -p 5201 -c 192.168.1.1 \
    -u -4 -b 1000M -l 1400 -t 60 -i 10 --udp-counters-64bit -R
```

### TCP 小块上行/下行

ServerVM 分别执行，只运行与本轮对应的一条：

```sh
sh eth0_irq_monitor.sh capture tcp_up_before up 40
sh eth0_irq_monitor.sh capture tcp_down_before down 40
```

Android 对应命令，不同时运行：

```sh
# TCP 小块上行
./iperf3 -A 1 -p 5201 -c 192.168.1.1 \
    -4 -b 1000M -l 1400 -t 60 -i 10

# TCP 小块下行
./iperf3 -A 1 -p 5201 -c 192.168.1.1 \
    -4 -b 1000M -l 1400 -t 60 -i 10 -R
```

TCP 的 `-l 1400` 是应用读写长度，不保证每个物理报文长 1400 字节。TCP 用例不额外固定源端口，避免重复短间隔运行时源端口复用受到连接状态影响。

## 4. 采集窗口

脚本先按方向检查连续两次流量：上行检查 eth0 TX 与 tap1 RX 的字节速率，下行检查 eth0 RX 与 tap1 TX 的字节速率。默认阈值均为 100 Mbit/s。检测成功后预热 8 秒，再采集 40 个约 1 秒的间隔；60 秒 iperf3 测试为此留出余量。

所有速率用 `/proc/uptime` 的实际时间差计算，不假定 sleep(1) 恰好等于 1 秒。IRQ 和接口计数通过多个文件读取，并非原子快照；`max_snapshot_span_seconds` 给出单次读取耗时上界。

测试期间不要同时运行其他带宽压测、抓高频 ftrace、执行 STR、重启驱动或改变 CPU 在线状态。全部接口流量都会进入计数，脚本不是按 iperf3 五元组过滤的流量统计工具。

## 5. 比较什么状态

第一类对照：相同协议和方向，比较现有未绑定状态与全链 CPU0 状态。改变状态后，将标签的 `before` 改为 `after`，其余参数不变。例如：

```sh
IOEVENTFD_TID=227 BACKEND_TID=1094 \
sh eth0_irq_monitor.sh capture udp_up_after up 40
```

这回答“现有低速与高速两种状态的 eth0 IRQ 数量有无区别”。

第二类对照：为了单独验证 eth0 IRQ 亲和性的作用，应固定 ioeventfd 与 vhost 在 CPU0，只改变 eth0 IRQ 的目标 CPU。不要同时放开线程绑定。IRQ 移动须先用 `detect` 确认设备，注意串口操作和恢复原配置。比较 IRQ0 与 IRQ1 时，可以分别使用标签 `udp_up_irq0`、`udp_up_irq1`。

同编号的 Android CPU 与 ServerVM CPU 不意味着同一个物理 CPU。保持 Android 绑核参数一致，并以实际 vCPU→pCPU 映射为准。

## 6. 输出与比较

每次结束打印 `OUTPUT_DIR=...`。使用实际打印的目录，不要猜时间戳：

```sh
sh eth0_irq_monitor.sh compare <before目录> <after目录>
```

重点文件：

| 文件 | 内容 |
|---|---|
| `summary.csv` | 总 IRQ、每秒 IRQ、双向 PPS/字节速率、主方向 IRQ/万包、有效性提示 |
| `irq_delta.csv` | 每条 IRQ 在每个 CPU 上的增量，以及汇总 |
| `samples.csv` | 每秒网络收发和 IRQ 增量/速率 |
| `irq_samples.csv` | 每个间隔、每条 IRQ、每个 CPU 的增量 |
| `irq_affinity.tsv` | 每次采样时 IRQ requested/effective affinity |
| `thread_state.tsv` | 指定 TID 的身份、允许 CPU 和最近运行 CPU |
| `before_context.txt`、`after_context.txt` | 设备、驱动、IRQ、threaded NAPI、RPS、irqbalance 状态 |
| `before_interrupts.txt`、`after_interrupts.txt` | 原始中断计数，包含但不汇总 IPI |
| `raw_samples.tsv` | 原始采样值，可重算 |
| `result.txt` | 汇总说明与每 CPU IRQ 表 |

`main_packets_per_irq` 和 `irq_per_10k_main_packets` 是归一化指标，不等于一次 NAPI 真正处理或回收的包数。上行使用 eth0 TX 包数，下行使用 eth0 RX 包数作为分母。

接口 Mbit/s 来自接口字节计数，不是 iperf3 应用有效载荷吞吐。请保留每轮 iperf3 最后的 sender/receiver、UDP loss 或 TCP Retr。

若 `capture_status=CHECK_WARNINGS`，检查低流量间隔、反向流量占优、IRQ affinity 变化、TID 消失或身份/affinity 变化。`OK` 仅表示这些检查未触发，不代表没有丢包或不存在其他性能问题。IRQ 身份、CPU 列、接口 ifindex 或累计计数回退时，脚本会拒绝输出正常汇总。

比较结果中分母为零时输出 `NA`，不会把无法计算的比值写成 0。

## 7. 本地验证范围

脚本使用 POSIX shell 和 awk，不依赖目标系统 Python。已以 BusyBox ash/awk 和模拟 proc/sysfs 数据验证上/下行判断、多 IRQ/每 CPU 累计计数、超过 32 位的计数、错误设备 IRQ 拒绝和计数回退检测。尚未在用户实际板端执行。

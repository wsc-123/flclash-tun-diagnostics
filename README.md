# FlClash TUN Diagnostics

Windows 上的 FlClash TUN 排查工具：保存故障现场、记录路由变化，并根据当前网卡生成供用户手动执行的删除命令。

本工具源于一次 Fake-IP 路由冲突排查：`198.18.0.0/24` 被导向物理网关，使部分域名在 TUN 下无法访问。后续 ETW 记录捕获到 `IDBWM.exe` 删除并重建该路由。详见[脱敏案例](docs/case-study.md)。这一案例不代表所有 TUN 故障或 Intel 软件环境都存在相同问题。

## 快速使用

从 GitHub 的 **Code → Download ZIP** 下载并完整解压，或克隆仓库。日常使用根目录的四个 `.bat` 文件；编号用于排序，不要求每次依次执行。

| 入口 | 用途 | 权限 | 输出 |
|---|---|---|---|
| [01-采集当前网络诊断.bat](01-采集当前网络诊断.bat) | 保存当前内核、网络状态及有限联网对照 | 通常普通用户即可，权限不足单项记录 | `output/diagnostics/日期/` |
| [02-开始记录路由来源.bat](02-开始记录路由来源.bat) | 开始后台 Windows ETW 路由记录 | 右键，以管理员身份运行 | `output/route-traces/时间_随机值/` |
| [03-停止记录并保存.bat](03-停止记录并保存.bat) | 停止本轮记录、保存快照并导出路由事件 | 管理员 | 与 02 相同的记录目录 |
| [04-生成删除命令.bat](04-生成删除命令.bat) | 查询指定故障模式，生成当前接口与网关对应的命令 | 普通用户；查询拒绝访问时用管理员 | `output/commands/route-delete-command.txt` |

**四个脚本都不会自动修改路由、DNS 或 FlClash 配置。04 只生成文本，由你判断并手动执行。** 出现 `198.18.x.x` 不等于路由异常，正常 TUN 的 `/30` 直连路由不应删除。

### 保存故障现场

保持发生故障时的 TUN 状态，运行 **01**。它先采集本机控制器，再采集 Windows 状态，最后进行有限的网络对照。需要跳过外部联网测试时，在 PowerShell 中运行：

```powershell
.\01-采集当前网络诊断.bat -SkipNetworkTests
```

该选项仍会读取本机控制器。默认控制器为 `127.0.0.1:9090`，初始代理地址为 `127.0.0.1:7890`；成功读取控制器后可按端口配置自动选择代理。自定义地址、DNS 及可选入口测试见[诊断说明](docs/diagnostics.md)。

### 找出路由何时、由谁改变

1. 最好在已删除异常路由、网络恢复后，以管理员运行 **02**。
2. 照常使用 TUN。02 窗口可以关闭，Windows 会继续记录。
3. 故障复发后，以管理员运行 **03**，等显示 `STOPPED`。
4. 需要恢复时运行 **04**，核对生成结果，再在管理员终端手动执行。

也可以先恢复再尽快运行 03；已保留的事件不会因为手动删除路由而主动清空，但停止快照将是恢复后的状态。关闭 TUN 不保证异常路由消失，开始时已有的路由也不保证会再次创建。详见[路由记录说明](docs/route-tracing.md)。

## 适用范围与要求

- Windows 10/11、Windows PowerShell 5.1；启动器明确调用 `powershell.exe`。
- 01 使用系统 `curl.exe`、NetTCPIP 等 Windows 命令；02/03 使用 `logman.exe` 和 Microsoft-Windows-TCPIP ETW 提供程序。
- 运行工具不需要 Python 或 GitHub CLI。开发验证需要 Python 3.10 或更新版本。
- 04 仅针对 **`198.18.0.0/24` 经物理网卡非直连 IPv4 网关**的模式生成候选命令；这是筛选条件，不是故障自动诊断。它不适用于任意地址段或任意 TUN 故障。
- 02/03、04 不主动访问网站或节点；01 默认访问百度、Google、公共 DNS 并做有限 ICMP 对照。
- ETW 使用 32 MB 循环日志，可能覆盖较早事件；观察到故障后应及时停止。所有工具副本共用一个会话名，一次只使用一份副本开始/停止记录。

## 文件与隐私

```text
flclash-tun-diagnostics/
├─ 01～04 四个 .bat 入口
├─ scripts/              PowerShell 实现与 tests/ 回归测试
├─ docs/                 用法、脱敏案例、公开范围说明
├─ output/               本地生成的诊断、事件和命令
└─ README.md
```

输出目录按工具位置定位，不受终端工作目录影响。请完整保留入口和 `scripts`；停止记录后才移动整个目录。01/02 每次保存独立记录，04 每次覆盖上一份结果，避免误用旧网络的删除命令。

**仓库未包含原始个人日志。** 生成的报告仍可能包含用户名、域名、代理组名、IP、进程及网络事件；内置遮盖不等于完全匿名。`output` 的运行结果默认被 Git 忽略，公开分享前仍需检查。见[公开范围与脱敏说明](docs/publishing.md)。

## 验证与说明

```powershell
python -m unittest discover -s scripts/tests -v
```

测试使用本机回环 HTTP 服务和模拟路由，不启动真实 ETW 会话、不删除路由。部分集成测试只读采集本机 Windows 状态，临时报告不会进入仓库。GitHub Actions 在 Windows 上运行同一套检查。

- [诊断参数与结果解释](docs/diagnostics.md)
- [路由来源记录、状态查询与导出](docs/route-tracing.md)
- [删除命令的筛选边界](docs/command-generation.md)
- [IDBWM 路由重建脱敏案例](docs/case-study.md)

本工具为独立排查项目，与 FlClash、Microsoft、Intel 官方无隶属关系。

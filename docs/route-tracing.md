# 02/03：记录路由来源

02 开始临时 Windows ETW 会话，03 停止并整理同一轮记录。它们不修改路由，不安装后台服务或计划任务，不主动探测节点。关闭窗口不会停止 ETW；重启 Windows 会结束该临时会话。

## 操作时机

最好在异常路由不存在时开始 02，故障复发后及时运行 03。也可以在 TUN 关闭时开始，但关闭 TUN 不保证异常路由消失。开始时已有路由只会被枚举；捕获创建者需要记录后续创建或重建事件。

需要先恢复网络时，可以先手动删除异常路由再尽快停止记录。请记下操作顺序，便于区分手动删除与后台修改。不要为了重新采集而刻意破坏已经恢复的网络。

## 文件

每轮位于 `output/route-traces/时间_随机值/`：

| 文件 | 内容 |
|---|---|
| `route-events.etl` | Windows 原始事件；32 MB 循环，满后覆盖较早内容 |
| `route-events.jsonl` | 按路由事件 ID 筛选的导出，每行一个 JSON 对象，含原始 XML |
| `start-routes.txt` / `stop-routes.txt` | 前后 IPv4 路由表 |
| `start-processes.json` / `stop-processes.json` | 进程 ID、名称、可读取的启动时间 |
| `start-services.json` / `stop-services.json` | 服务名称、状态、进程号；读取失败另存错误 |
| `trace-info.json` / `stopped-at.txt` | 归档的启动信息、停止时间 |
| `session-status.txt` | **停止前**的状态查询，其中 running 不表示停止后仍运行 |
| `export-status.json` | 导出是否完成、已保留的路由事件数、错误 |

运行时标记在 `output/route-traces/.active.json`。不要手动删除活动标记或搬动目录。所有副本共用会话 `FlClashRouteOrigin`，只能从同一份工具开始并停止一轮记录。

## 事件与归因边界

提供程序 `Microsoft-Windows-TCPIP`，GUID `{2F07E2EE-15DB-40F1-90EF-9D7BA282188A}`，关键字 `0x20`（TcpipRoute），级别 4。

| ID | 含义 |
|---|---|
| 1145 | 路由创建 |
| 1146 | 路由删除 |
| 1147 | 路由属性变化 |
| 1452 | 既有路由状态枚举，**不能用其 PID 认定创建者** |

筛选目标前缀与当时物理网关，核对创建时间和 PID，再对应前后进程快照。网关随网络环境变化，不能固定筛选某个个人网关。事件 PID 是执行上下文，可能为代理服务或系统工作线程，不保证能指出最初的请求方；PID 回收和短命进程也需考虑。

0 条事件可以是有效导出；循环覆盖、开始时机与错误状态决定其解释范围。缓冲区丢失为 0 也不代表循环文件没有覆盖。ETL 不是自动脱敏材料，不要直接公开。

## 查询和补做导出

在工具根目录的管理员 PowerShell 中查询：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\route-origin-trace.ps1 -Action Status
```

如果停止后导出中断，保留原始文件。将下面的占位目录替换成实际已停止的轮次：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\route-origin-trace.ps1 -Action Export -RecordingDirectory '.\output\route-traces\实际记录目录'
```

Export 只处理当前工具输出目录内、有停止标记的记录，不重新开始采集。

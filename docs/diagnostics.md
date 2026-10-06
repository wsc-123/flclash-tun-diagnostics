# 01：当前网络诊断

先保存 FlClash 本机控制器状态（版本、配置白名单、最近连接、代理组选择和规则类型统计），再读取 Windows 网卡、地址、DNS、路由、端口、限定的代理环境变量及近期网络事件。默认最后执行少量 HTTP、DNS、ICMP 对照，不测速节点，不改系统配置。

## 参数

| 参数 | 默认值 | 用途 |
|---|---|---|
| `-Api` | `http://127.0.0.1:9090` | 必须是回环控制器地址 |
| `-Proxy` | `http://127.0.0.1:7890` | 显式指定对照代理；未指定时尝试读取控制器配置中的端口 |
| `-Secret` | 环境变量 `FLCLASH_DIAG_SECRET` | 控制器认证；建议使用本机环境变量，不要公开真实值 |
| `-DnsServer` | 空 | 额外 DNS 对照；不提供时只测系统解析与公共 DNS |
| `-EntryDomain` | 空 | 可选入口域名 HTTPS 测试；不提供时不访问任何预置个人节点 |
| `-EntryIP` | 空 | 与 EntryDomain 一起提供，增加固定 IP 且保留域名/SNI 的对照 |
| `-OutputDirectory` | `output/diagnostics/日期/` | 自定义时目录须已存在 |
| `-RequestTimeoutSeconds` | 8 | HTTP 最长等待时间，范围 2～30 秒 |
| `-SkipNetworkTests` | 关闭 | 跳过外部探测，仍读取本机控制器与系统状态 |
| `-NoPause` | 关闭 | 自动化调用时不等待按 Enter |

旧参数名 `CampusDns` 仅作为 `DnsServer` 的兼容别名，不代表网络类型；发布版没有个人 DNS 默认值。默认外部探测目标包括百度、Google、`223.5.5.5` 及当前接口网关。

例如，只读取现场：

```powershell
.\01-采集当前网络诊断.bat -SkipNetworkTests -NoPause
```

自定义 DNS 对照：

```powershell
.\01-采集当前网络诊断.bat -DnsServer 1.1.1.1
```

## 怎样理解结果

- `OK` 只代表该项采集成功，不表示互联网一定可用。
- `RESPONSE` 表示收到 HTTP 响应，包括 3xx/4xx/5xx；应用错误与传输断开不同。
- 显式代理成功、系统路由/TUN 失败，可以帮助定位，但需结合路由、DNS 和现场操作。
- 固定 IP 测试只绕过该请求的常规解析，流量仍可能经过 TUN；入口网页可达不代表节点协议必然正常。
- ICMP 失败、IPv6 解析失败不单独构成 TUN 故障证据。DNS 请求也可能被 TUN 劫持。

控制器密钥通过 curl 标准输入传递；配置按字段白名单输出，常见 URL 凭据会遮盖。报告仍包含其他环境信息，不应直接作为公开附件，见[脱敏说明](publishing.md)。

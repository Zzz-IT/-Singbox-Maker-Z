# Singbox Maker Z

**基于模块化架构的高性能 Sing-box 编排方案**

Singbox Maker Z 是一个专为资源受限服务器（如 128MB 内存 VPS）设计的自动化部署与管理系统。它不仅实现了 Sing-box 核心协议的快速配置，更通过内置的进程守护（Watchdog）与精细化的生命周期管理，为用户提供企业级的稳定性保障。

## 核心架构设计

项目采用 **微内核 + 插件化（Library-based）** 的模块化设计。核心逻辑位于 `singbox.sh`，而底层功能拆分为独立的 Shell 库，确保了系统的可维护性与扩展性：

* **自动化资源调优**：动态计算 `GOMEMLIMIT`。对于内存 > 64MB 的系统，预留 40MB 给内核；对于极小内存（≤ 64MB）系统，通过极限压缩预留 20MB，确保核心进程在 10MB 的极端配额下仍能稳定运行。
* **跨发行版兼容层**：自动识别 `systemd` 与 `openrc` 初始化系统，支持 Debian、Ubuntu及 Alpine Linux 等主流发行版。
* **配置原子化操作**：所有 JSON 与 YAML 配置的修改均通过原子化函数完成，有效避免因脚本中断导致的配置文件损坏。

## 核心功能详解

### 1. 高可用 Argo 隧道守护系统

内置独家“看门狗”逻辑，彻底解决 Argo 隧道随机断连的痛点：

* **状态感知**：通过 `keepalive` 指令每分钟扫描 `cloudflared` 进程状态与日志流。
* **自动重联**：一旦检测到隧道链路中断，系统将自动触发热重启，并实时更新元数据（Metadata）中的临时域名。

### 2. 全生命周期管理 (Scheduled Lifecycle)

支持对服务运行状态进行精确到分钟的时间编排：

* **定时启停**：允许设定每日固定的服务“工作窗口”（例如：08:00 自动开启，01:30 自动关闭）。
* **资源静默**：在非运行时间内完全释放系统资源，并清理所有相关的防火墙规则与后台进程。

### 3. 极速部署引擎 (Quick Deploy)

支持一键并行部署 **VLESS-Reality**、**Hysteria2** 与 **TUIC v5** 协议组合：

* **智能去重**：自动生成随机端口并执行冲突检测。
* **安全预设**：默认集成 `www.apple.com` 等高可信度 SNI 伪装。

## 安装与维护

### 系统部署

建议使用官方安装器进行部署，该程序会自动处理所有二进制依赖（如 `jq`、`yq`、`curl`）及环境初始化：

```bash
curl -fsSL https://raw.githubusercontent.com/Zzz-IT/-Singbox-Maker-Z/main/install.sh | bash

```

### 常用管理指令

| 指令 | 作用域 | 技术说明 |
| --- | --- | --- |
| `sb` | 全局入口 | 启动交互式管理控制台 |
| `sb -q` | 快速部署 | 自动执行协议矩阵编排 |
| `sb keepalive` | 隧道守护 | 手动触发 Argo 链路健康检查 |
| `sb scheduled_start` | 生命周期 | 强制触发定时启动任务流 |

## 协议支持矩阵

| 协议 | 传输层 | 安全特性 |
| --- | --- | --- |
| **VLESS-Reality** | TCP / Vision | 基于真实 TLS 指纹的抗封锁方案 |
| **Hysteria 2** | UDP / Salamander | 针对高丢包链路的吞吐量优化 |
| **TUIC v5** | QUIC / BBR | 低延迟、高性能的现代化传输协议 |
| **Argo Tunnel** | HTTP/2 | 穿越 NAT 与被墙 IP 的内网穿透技术 |
| **Shadowsocks** | GCM / 2022 | 经典、稳定且具备多路复用能力的协议 |

## 目录规范

* `/usr/local/etc/sing-box/`：业务配置与元数据存储路径。
* `/usr/local/share/singbox-maker-z/`：模块化组件存放路径。
* `/var/log/sing-box.log`：服务运行日志（支持自动轮转清理）。

---

**致谢**：本项目在 [singbox-lite](https://github.com/0xdabiaoge/singbox-lite) 的基础上进行了深度重构与功能演进。







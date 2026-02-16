
# Singbox Maker Z

> 🚀 **专注小内存 VPS 优化** | 🛡️ **Argo 隧道守护** | ⏰ **定时生命周期管理**

本项目基于 [**singbox-lite**](https://github.com/0xdabiaoge/singbox-lite) 进行**魔改**，精简功能，加入定时启停，重构UI。针对低配置环境（如 Alpine/128M）深度优化内存占用，并新增了企业级的 Argo 进程守护与定时启停功能。

## ✨ 核心特性

* **🛡️ Argo 隧道全家桶**：集成 **TryCloudflare** (临时) 与 **Token** (固定) 双模式，支持 VLESS/Trojan 穿透。
* **🐶 独家看门狗 (Watchdog)**：内置进程守护，**每分钟**检测隧道状态，断连自动拉起，确保持久在线。
* **⏰ 生命周期管理**：支持设置精确的**“工作时间”**（如 08:30 启动，02:15 停止），适合按量付费或定时静默场景。
* **🧩 模块化架构**：重构为 `singbox.sh` (控制)、`utils.sh` (工具)、`parser.sh` (解析)，自动热更新核心组件。
* **🧠 智能优化**：动态计算 `GOMEMLIMIT` 防止 OOM，自动规避小内存机器 `apt-get` 死机问题。

---

## 📥 安装与使用

### 交互式安装（推荐）

自动识别系统环境并安装至 `/usr/local/bin/sb`：

```bash
(curl -LfsS https://raw.githubusercontent.com/Zzz-IT/-Singbox-Maker-Z/main/singbox.sh -o /usr/local/bin/sb || wget -q https://raw.githubusercontent.com/Zzz-IT/-Singbox-Maker-Z/main/singbox.sh -O /usr/local/bin/sb) && chmod +x /usr/local/bin/sb && sb
```
### ⚡ 快速部署

安装完成后，输入以下指令即可自动部署 **VLESS-Reality**、**Hysteria2**、**TUICv5** 三节点：

```bash
sb -q
```

**特点**：

* ✅ **端口防冲**：自动生成随机端口并强制去重
* ✅ **默认伪装**：SNI 默认使用 `www.apple.com`
* ✅ **自动展示**：自动展示系统版本和运行方式
* ✅ **即刻管理**：部署后可运行 `sb` 进入管理菜单

---

## 📋 支持协议矩阵

|协议|特性|适用场景|
|-|-|-|
|**VLESS-Reality**|Vision 流控 / 免域名|🚀 主力协议，高隐蔽性|
|**Hysteria2**|UDP / 端口跳跃 / 伪装|⚡ 弱网救星，防 QoS|
|**TUIC v5**|QUIC / BBR / 0-RTT|⚡ 高性能低延迟|
|**Argo Tunnel**|Cloudflare 内网穿透|☁️ 无公网 IP / 救被墙 IP|
|**AnyTLS**|平滑伪装|🛡️ 特殊网络环境|
|**Shadowsocks**|2022 / GCM / Multiplex|🔄 兼容老旧设备|

## 🕹️ 常用指令

|指令|说明|
|-|-|
|**`sb`**|打开管理主菜单|
|**`sb -q`**|极速部署 (Reality + Hy2 + Tuic)|
|**`sb keepalive`**|手动触发一次 Argo 守护检查|
|**`sb scheduled\_start`**|手动触发定时启动流程|

---

## 🤝 致谢 (Credits)

本项目基于开源项目 [**singbox-lite**](https://github.com/0xdabiaoge/singbox-lite) 进行二次开发与重构。

特别感谢原作者 [**0xdabiaoge**](https://github.com/0xdabiaoge) 的杰出工作与开源精神！

---

<p align="center">Made with ❤️ by Zzz-IT</p>





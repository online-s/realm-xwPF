# 端口流量狗 (Port Traffic Dog)

> 一只轻巧的“守护犬”，随时守护你的端口流量，让流量监控和管理更简单。

🔔 **端口流量狗**是一款轻量级 Linux 端口流量监控与管理工具，基于 `nftables` 和 `tc`，支持精准的**端口级**流量统计、速率限制与流量配额控制。

## 脚本界面预览

**主界面**
![cc59017896d277a8b35109ae44eac977.gif](https://i.mji.rip/2025/12/12/cc59017896d277a8b35109ae44eac977.gif)

## 适用场景

### 🌐 网络服务监控
- 中转、Web 服务器、代理服务、游戏服务器等
- 为没有流量管理的程序附加轻量级的监控与控制能力

### 💰 流量计费管理
- **VPS 流量控制**：避免超额流量导致额外费用  
- **成本管理**：通过速率与流量限制来降低运营成本

## ✨ 核心功能

### 流量监控
- **持久化**：即使服务器异常关机或重启，完全无感保持数据正常工作
- **精确统计**：基于 `nftables` 的端口级流量监控  
- **双向支持**：支持单向（出站）和双向（入站+出站）流量统计
- **端口范围**：支持单端口与端口段（如 100-200）  
- **实时统计**：实时累计流量数据  

### 流量控制
- **速率限制**：基于 `tc` 的端口速率控制（支持 Kbps/Mbps/Gbps）
- **突发速率处理**: 动态计算 burst 值,既能应对瞬间速率高峰，又不会过度放宽限制
- **流量配额**：基于 `nftables quota` 的月度流量配额（支持 MB/GB/TB）  
- **自动重置**：端口可配置每月流量自动重置（默认每月 1 日，支持 1–31 日自定义）  
- **超限阻断**：流量超限后自动阻断，支持手动重置恢复

### 数据与记录
- **一键导出/导入**：完整迁移配置与数据
- **历史记录**：保留流量重置历史  
- **日志轮转**：自动日志清理和轮转

### 通知系统
- **独立模块分隔**: 同时启用两个,各自独立的间隔设置,任意禁用其中一个,不影响另一个
- **Telegram 通知**：支持机器人推送
- **webhook通知(企业wx 群)**: 支持机器人推送
- **状态汇报**：可按间隔（1 分钟–24 小时）推送状态  
- **扩展支持**：预留邮箱接口（敬请期待）  

### 端口备注管理
- **多用户场景**：为不同端口(用户)添加备注，方便管理  

## 🚀 一键安装

> 端口流量狗脚本属于完整独立脚本，可单独安装使用(快捷键:dog)

### 方式一：直接安装
```bash
wget -O port-traffic-dog.sh https://raw.githubusercontent.com/zywe03/realm-xwPF/main/port-traffic-dog.sh && chmod +x port-traffic-dog.sh && ./port-traffic-dog.sh
```

### 方式二：使用加速源
```bash
wget -O port-traffic-dog.sh https://v6.gh-proxy.org/https://raw.githubusercontent.com/zywe03/realm-xwPF/main/port-traffic-dog.sh && chmod +x port-traffic-dog.sh && ./port-traffic-dog.sh
```
若加速源失效，可多次重试或更换其他具有内置加速功能的代理源

## 系统要求

### 自动安装的依赖
遵循**Linux原生轻量化工具**原则，保持系统干净整洁：

- `nftables` - 现代网络过滤框架，替代iptables
- `iproute2` - 网络工具套件(包含tc、ss、ip命令)
- `jq` - JSON处理工具
- `gawk` - GNU AWK文本处理工具
- `bc` - 基础计算器，用于流量单位转换
- `unzip` - 解压缩工具

### 配置文件位置
- **主配置**: `/etc/port-traffic-dog/config.json` - 端口配置、通知设置等
- **日志目录**: `/etc/port-traffic-dog/logs/` - 运行日志和通知日志
- **通知模块**: `/etc/port-traffic-dog/notifications/` - Telegram等通知脚本

## Telegram通知配置

### 1. 创建Telegram机器人
1. 在Telegram中找到 @BotFather
2. 发送 `/newbot` 创建新机器人
3. 获取Bot Token

### 2. 获取Chat ID
1. 将机器人添加到群组或私聊
2. 发送任意消息给机器人
3. 访问 `https://api.telegram.org/bot<TOKEN>/getUpdates`
4. 从返回结果中找到chat_id

### 3. 配置通知
在脚本主菜单选择：
8. 通知管理 → 1. Telegram机器人通知

配置项：
- Bot Token
- Chat ID
- 服务器名称
- 状态通知(可选间隔：1分钟到24小时)
- 邀请自己的机器人到群组,然后在输入ID那里输入群组ID就可以在群组通知，，输入个人ID就个人通知

## webhook(企业wx 群机器人)通知配置

1. 在企业wx 群中添加群机器人
2. 获取机器人的 Webhook URL复制
3. 粘贴到`请输入Webhook URL: ` 即可

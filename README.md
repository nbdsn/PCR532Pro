# PCR532 Pro - iOS NFC 读写器

基于 **PCR532 Pro 蓝牙版** 的 iOS 原生 App，控制 PN532 芯片进行 MIFARE Classic 卡片读写和破解。

## 功能

- **BLE 设备连接**：扫描连接 PCR532 Pro（标准 SPP 蓝牙串口）
- **卡片检测**：读取 UID、SAK、ATQA、卡片类型识别
- **MIFARE Classic 读写**：认证、读块、写块、全卡 Dump
- **扇区编辑**：十六进制编辑器，一键设置密钥和访问位
- **密钥管理**：50+ 默认密钥字典，自定义密钥库
- **字典攻击**：自动尝试所有默认密钥破解各扇区
- **嵌套攻击**：利用已知密钥通过 Crypto1 分析破解未知扇区
- **暗侧攻击**：零知识恢复密钥（无需任何已知密钥）
- **魔术卡支持**：改 UID、写 Block 0、融合/恢复、克隆卡片
- **Dump 管理**：保存/加载/导出 .mfd 文件

## 硬件要求

- **PCR532 Pro 蓝牙版**（带电池的版本，内置 HM-10/HC-08 蓝牙芯片）
- 或其他基于 PN532 的 BLE 转串口 NFC 读写器

## 构建

### 方法一：GitHub Actions（推荐）

1. 创建公开 GitHub 仓库，push 代码
2. 进入 Actions 页面，手动触发 workflow
3. 下载编译好的 .ipa
4. 用 TrollStore 安装

### 方法二：本地 Xcode

1. 需要 macOS + Xcode 15+
2. 安装 XcodeGen：`brew install xcodegen`
3. 在项目目录运行：`xcodegen`
4. 用 Xcode 打开 `PCR532Pro.xcodeproj`
5. 选择 iOS 16.0 目标，Build
6. 产物用 TrollStore 安装

## 项目结构

```
PCR532Pro/
├── .github/workflows/   # GitHub Actions 自动编译
├── Sources/
│   ├── App/             # 入口 + 主界面
│   ├── BLE/             # CoreBluetooth 通信
│   ├── PN532/           # PN532 协议栈
│   ├── Crypto1/         # MIFARE 加密算法
│   ├── MIFARE/          # 卡片操作 + 攻击算法
│   ├── MagicCard/       # 魔术卡支持
│   ├── Utils/           # 工具类
│   └── Views/           # SwiftUI 视图
├── project.yml          # XcodeGen 配置
└── Info.plist
```

## 系统要求

- iOS 16.0+
- iPhone 7 或更新机型（支持 BLE 4.0+）

## 技术说明

- **通信协议**：BLE SPP（标准串口服务 UUID: `00001101-0000-1000-8000-00805F9B34FB`）
- **NFC 协议**：通过 PN532 的 `InDataExchange` 和 `InCommunicateThru` 命令操作
- **加密算法**：Crypto1 流密码（48 位 LFSR + 非线性滤波器）
- **攻击算法**：嵌套攻击（Nested）、暗侧攻击（DarkSide）、字典攻击

## 免责声明

本工具仅用于合法用途，如测试自己的卡片安全性。请遵守当地法律法规，勿用于非法用途。使用者需自行承担所有责任。
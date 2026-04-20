> 基于 lark-cli 的家庭物品收纳助手。
>
> __发消息给飞书机器人，一句话记录物品位置，再也不怕找不到东西。__

---

## 这是什么

家庭收纳助手是一个飞书机器人，通过 lark-cli 操作飞书多维表格。你只需要在飞书群里发消息：

1. __存物品__ — "把充电器放书桌第二个抽屉"
2. __查物品__ — "充电器在哪？"
3. __看清单__ — "看看家里都存了什么"
4. __收建议__ — "钥匙太多怎么收纳？"
5. __传图片__ — 拍张照片，再告诉机器人是什么、放哪了

## 工作原理

```
你在飞书群里发消息
         │
         ▼
┌──────────────────────────────┐
│  bot.sh（Bash 脚本，7x24 运行）│
│                              │
│  ① lark-cli 轮询飞书消息      │  ← lark-cli im +chat-messages-list
│         │                    │
│  ② 发给 LLM 识别意图          │  ← 智谱/通义/DeepSeek 等
│         │                    │
│  ③ 根据 intent 执行操作       │
│      ├─ store → 写入表格      │  ← lark-cli base +record-upsert
│      ├─ query → 查询表格      │  ← lark-cli base +record-list
│      ├─ list  → 列出全部      │  ← lark-cli base +record-list
│      └─ 图片  → 下载+上传附件  │  ← lark-cli im +messages-resources-download
│                → 关联到记录    │  ← lark-cli base +record-upload-attachment
│         │                    │
│  ④ lark-cli 发送回复          │  ← lark-cli im +messages-send
└──────────────────────────────┘
```

**核心：所有飞书操作 100% 通过 lark-cli 完成。** 唯一的非 lark-cli 调用是 LLM API（语义识别）。

## lark-cli 使用详解

家庭收纳助手通过 lark-cli 调用飞书开放平台 API，以下是具体使用情况：

### 即时通讯操作

| lark-cli 命令 | 飞书 API | 用途 |
| --- | --- | --- |
| `lark-cli im +chat-messages-list` | 拉取聊天消息 | 轮询模式获取新消息、离线补课 |
| `lark-cli im +messages-send` | 发送消息 | 回复用户（确认、查询结果、清单） |
| `lark-cli im +messages-resources-download` | 下载消息资源 | 下载用户发送的图片 |
| `lark-cli im chats list` | 获取群列表 | 发现机器人加入的群聊 |

### 多维表格操作

| lark-cli 命令 | 飞书 API | 用途 |
| --- | --- | --- |
| `lark-cli base +record-upsert` | 创建/更新记录 | 存储物品信息（名称、位置、分类、数量） |
| `lark-cli base +record-list` | 读取记录 | 查询物品位置、列出所有物品清单 |
| `lark-cli base +record-upload-attachment` | 上传附件 | 将用户发送的图片关联到物品记录 |

### 认证方式

通过 lark-cli 的项目级配置实现多应用支持：

```bash
# 项目级配置（不影响全局 lark-cli）
HOME="/你的项目目录" lark-cli im +messages-send ...
```

每个项目有独立的 `.lark-cli/config.json`，多个飞书机器人可以同时运行互不干扰。

## 功能演示

| 场景 | 你说的 | 机器人回复 |
| --- | --- | --- |
| 存物品 | "把充电器放书桌第二个抽屉" | ✅ 「充电器」已存入「书桌第二个抽屉」 |
| 存物品 | "身份证在保险箱里" | ✅ 「身份证」已存入「保险箱里」 |
| 查物品 | "充电器在哪" | 找到了！📦 充电器（1个）在书桌第二个抽屉 |
| 查物品 | "我的护照呢" | 还没收录「护照」的位置信息哦，要现在记录吗？ |
| 看清单 | "看看家里都有什么" | 📋 物品清单（共5件）1. 充电器 ｜ 电子产品 ｜ 书桌第二个抽屉... |
| 收建议 | "钥匙太多怎么收纳" | 1. 用钥匙挂钩按用途分区挂放 2. 用带标签的钥匙扣区分... |
| 发图片 | 发一张照片 | 收到图片！请告诉我：这是什么物品，放在哪里？ |
| 图片+描述 | "鼠标放在桌子上" | ✅ 「鼠标」已存入「桌子上」📷 图片已关联 |
| 闲聊 | "你好" | 你好！告诉我东西放在哪，或者问我找东西~ |

## 数据结构

### 多维表格 — 物品清单

| 字段 | 类型 | 可写 | 说明 |
| --- | --- | --- | --- |
| 物品名称 | text | ✅ | 物品名（主查询字段） |
| 位置 | text | ✅ | 存放位置 |
| 分类 | select | ✅ | 电子产品/文具/衣物/厨房用品/工具/证件/药品/玩具/书籍/钥匙卡包/其他 |
| 数量 | number | ✅ | 物品数量，默认 1 |
| 存放人 | text | ✅ | 谁放的 |
| 备注 | text | ✅ | 补充说明 |
| 存放时间 | created_at | ❌ | 系统自动记录 |
| 附件 | attachment | ✅ | 关联的图片 |

---

## 快速开始

### 一键初始化（推荐）

```bash
git clone https://github.com/asiyoua/home-storage.git
cd home-storage
bash setup.sh
```

`setup.sh` 会引导你完成所有配置：

1. ✅ 检查依赖（lark-cli、jq、curl）
2. ✅ 配置飞书应用（App ID / App Secret）
3. ✅ 连接多维表格（Base Token / Table ID）
4. ✅ 选择 LLM 厂商并填入 API Key
5. ✅ 自动生成 `config.json`

### 手动配置

<details>
<summary>点击展开手动配置步骤</summary>

#### 1. 安装依赖

```bash
# 安装 lark-cli（需要 Node.js）
npm install -g @larksuite/cli

# 安装 jq（macOS）
brew install jq

# 验证
lark-cli --version && jq --version
```

#### 2. 创建飞书应用

1. 前往 [飞书开放平台](https://open.feishu.cn/app) 创建应用
2. 获取 **App ID** 和 **App Secret**
3. 开通以下权限：
   - `im:message` — 发送消息
   - `im:message:readonly` — 读取消息
   - `im:resource` — 下载图片资源
   - `bitable:app` — 读写多维表格
4. 发布应用，将机器人添加到群聊

#### 3. 创建多维表格

在飞书中创建多维表格，添加以下字段：

| 字段名 | 类型 |
|--------|------|
| 物品名称 | 文本 |
| 位置 | 文本 |
| 分类 | 单选（电子产品/文具/衣物/厨房用品/工具/证件/药品/玩具/书籍/钥匙卡包/其他） |
| 数量 | 数字 |
| 存放人 | 文本 |
| 备注 | 文本 |
| 存放时间 | 创建时间 |
| 附件 | 附件 |

从 URL 获取 Token：`https://xxx.feishu.cn/base/XXXXXX?table=YYYYYY`

#### 4. 配置

```bash
# lark-cli 项目级配置
mkdir -p .lark-cli
cat > .lark-cli/config.json << 'EOF'
{ "apps": [{ "appId": "你的ID", "appSecret": "你的Secret", "brand": "feishu", "lang": "zh" }] }
EOF

# 应用配置
cp config.example.json config.json
# 编辑 config.json 填入你的信息
```

</details>

### 启动

```bash
bash bot.sh
```

## LLM 配置

所有接口兼容 OpenAI Chat Completions 格式，只需改 3 个字段：

| 厂商 | `llm_base_url` | `llm_model` | 获取 API Key |
| --- | --- | --- | --- |
| **智谱（推荐，免费）** | `https://open.bigmodel.cn/api/paas/v4` | `glm-4.5-air` | [open.bigmodel.cn](https://open.bigmodel.cn) |
| 阿里通义 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-turbo` | [dashscope.console.aliyun.com](https://dashscope.console.aliyun.com) |
| DeepSeek | `https://api.deepseek.com/v1` | `deepseek-chat` | [platform.deepseek.com](https://platform.deepseek.com) |
| Moonshot | `https://api.moonshot.cn/v1` | `moonshot-v1-8k` | [platform.moonshot.cn](https://platform.moonshot.cn) |
| 硅基流动 | `https://api.siliconflow.cn/v1` | `Qwen/Qwen2.5-7B-Instruct` | [cloud.siliconflow.cn](https://cloud.siliconflow.cn) |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` | [platform.openai.com](https://platform.openai.com) |

## 开机自启（macOS）

```bash
cat > ~/Library/LaunchAgents/com.home-storage-bot.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.home-storage-bot</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/你的完整路径/home-storage/bot.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/你的完整路径/home-storage</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key>
    <string>/你的完整路径/home-storage/bot-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/你的完整路径/home-storage/bot-stderr.log</string>
</dict>
</plist>
PLIST

launchctl load ~/Library/LaunchAgents/com.home-storage-bot.plist
```

## 项目结构

```
home-storage/
├── bot.sh                # 主程序（Bash，~500行）
├── setup.sh              # 一键初始化脚本
├── config.example.json   # 配置模板
├── system-prompt.txt     # LLM 语义识别提示词
├── assets/               # 二维码图片
│   ├── 公众号二维码.jpg
│   └── 个人微信.jpg
├── .gitignore            # 安全（排除凭证和数据）
└── README.md             # 就是你在看的这个文件
```

运行时自动生成（已 gitignore）：

```
├── config.json           # 你的配置（含 API Key）
├── .lark-cli/config.json # 飞书凭证（含 App Secret）
└── data/                 # 运行时数据
    ├── known_chats.txt   # 机器人加入的群
    ├── dedup_*           # 消息去重标记
    └── images/           # 图片缓存
```

## 运行保障

| 机制 | 实现 |
| --- | --- |
| 常驻运行 | macOS launchd（`KeepAlive=true`，`RunAtLoad=true`） |
| 崩溃自恢复 | launchd 自动重启 |
| 消息去重 | 按 `message_id` 文件标记，不重复处理 |
| 离线补课 | 启动时回看 24 小时未处理消息 |
| API 超时保护 | curl `--max-time 30`，防止 LLM 无响应卡死 |
| 图片超时清理 | pending 文件 5 分钟自动过期 |
| 附件字段自动检测 | 无需手动查找字段 ID |

## 常见问题

__Q: 需要Claude Code吗？__

A: 不需要。这是一个独立的 Bash 脚本，直接运行 `bash bot.sh` 即可。只要有 lark-cli。

__Q: LLM API 必须用智谱吗？__

A: 不是。支持任何 OpenAI 兼容接口的 LLM。智谱推荐是因为 GLM-4.5-air 免费。

__Q: 可以同时运行多个飞书机器人吗？__

A: 可以。每个项目有独立的 `.lark-cli/config.json`，通过 `HOME` 环境变量隔离，互不干扰。

__Q: 图片发送后机器人没反应？__

A: 发图片后机器人会问"这是什么物品，放在哪里？"，你需要回复文字描述。5 分钟内不回复会自动超时。

__Q: 如何停止机器人？__

A: `pkill -f home-storage/bot.sh` 或 `launchctl unload ~/Library/LaunchAgents/com.home-storage-bot.plist`

---

## 贡献

欢迎提交 Issue 和 Pull Request！

## License

MIT

---

__作者__: 胡九思 | __公众号__: 九思AI歪博 | __GitHub__: [asiyoua/home-storage](https://github.com/asiyoua/home-storage)

<div align="center">
  <img src="assets/公众号二维码.jpg" width="200" alt="公众号：九思AI歪博" />
  &nbsp;&nbsp;&nbsp;&nbsp;
  <img src="assets/个人微信.jpg" width="200" alt="个人微信" />
  <br/>
  <sub>公众号：九思AI歪博 &nbsp;&nbsp;|&nbsp;&nbsp; 个人微信</sub>
</div>

# superagent

飞书（Lark）自动化工作区：CLI 配置、群内 @ 应答机器人、踩坑沉淀。

> 本仓库只包含**自写代码与文档**。第三方依赖与运行时数据（`dsh-cli/`、`repo/`、`state/`、日志）已被 `.gitignore` 排除。

---

## 一、lark-bot —— 飞书群 @ 应答机器人

常驻进程，监听飞书群消息，只在**群内 @ 机器人**时按规则自动回复。

### 启动 / 停止 / 查看

```powershell
cd lark-bot
.\bot.ps1 start      # 启动（后台运行）
.\bot.ps1 status     # 查看状态与最近日志
.\bot.ps1 log        # 实时跟踪日志
.\bot.ps1 stop       # 停止
.\bot.ps1 restart    # 重启
```

> 也可以直接用 node 启动：`node lark-bot.mjs`

### 支持指令（群里 @ 机器人后输入）

| 指令 | 回复 |
|---|---|
| `帮助` / `help` / `?` | 指令说明 |
| `时间` / `time` | 当前时间（Asia/Shanghai） |
| `ping` | `pong 🏓` |
| `复制 <内容>` | 原样回显 |
| 其他任意内容 | 回显内容 + 提示当前为规则模式 |

### 配置（环境变量，均可选）

| 变量 | 默认 | 说明 |
|---|---|---|
| `LARK_BOT_OPEN_ID` | 内置值 | 机器人 open_id，用于识别 @ |
| `LARK_ALLOWED_CHATS` | 空（不限） | 逗号分隔的 chat_id 白名单 |
| `LARK_CLI_ENTRY` | npm 全局 lark-cli.exe | lark-cli 可执行文件路径 |
| `LARK_AI_ENABLED` | 未启用 | 置 `1` 接入 AI（需在代码里补 `askAI`） |

### 工作方式

```
飞书服务器 ──WebSocket──▶ lark-cli event consume ──NDJSON──▶ lark-bot.mjs
                                                                    │
                                                         规则匹配生成回复
                                                                    │
                             lark-cli im +messages-send --as bot ◀──┘
```

- **不经过 shell**：直接 spawn `lark-cli.exe`，避免 Windows 下含 `「」` 等字符的文本被错误拆分成独立参数。
- **按 `message_id` 去重**：服务端可能重复推送（不要用 `event_id` 去重）。
- **子进程自愈**：事件消费进程退出后 5 秒自动重启。

### 接入 AI（预留接口）

`lark-bot.mjs` 的 `makeReply()` 中已留出位置：

```js
// if (process.env.LARK_AI_ENABLED === '1') { return await askAI(t); }
```

补上 `askAI()` 实现并把该行放开即可，规则匹配仍会优先命中。

---

## 二、lark-cli 配置要点

```powershell
lark-cli config show     # 查看当前应用配置
lark-cli auth status     # 查看身份与 token（bot / user）
lark-cli doctor          # 健康检查（9 项）
lark-cli whoami          # 当前生效身份
```

- 配置文件：`C:\Users\<用户>\.lark-cli\config.json`
- 输出判断成功用 `ok == true`（成功信封没有 `code` 字段，别用 `code == 0` 判断）。
- 登录后退出码可能是 1（企业管理员禁止申请的权限提示），以 `auth status` 里 `user.status == ready` 为准。

### 常用命令

```powershell
lark-cli calendar +agenda                                   # 今日日程
lark-cli im +messages-send --as bot --chat-id oc_xxx --text "hi"
lark-cli im +chat-list --as bot                              # 机器人所在群
lark-cli event consume im.message.receive_v1 --as bot        # 监听群消息事件
```

---

## 三、踩坑记录

见 [踩坑与复利.md](./踩坑与复利.md)，已沉淀的关键坑：

1. **DSH 沙箱 ACL**：首条命令报 `SetNamedSecurityInfoW failed (Win32 5)` → 用 ACL 修复技能一条命令解决。
2. **lark-cli 配置不落盘**：沙箱禁止注册表写入导致 `keychain unavailable`，看似成功实际没保存 → 需完全权限运行。
3. **PowerShell 5.1 读 UTF-8 乱码**：无 BOM 的中文脚本被按 GBK 解析，导致引号配对失败 → 脚本必须存为 **UTF-8 with BOM**。
4. **Windows `shell:true` 拆分参数**：文本含 `「」` 被拆成额外参数 → 直接 spawn exe，不经 shell。

---

## 四、目录结构

```
superagent/
├── lark-bot/               # 飞书 @ 应答机器人
│   ├── lark-bot.mjs        # 主程序
│   ├── bot.ps1             # 启动/停止/状态管理
│   └── data/               # 运行时日志与 pid（不入库）
├── 踩坑与复利.md            # 项目踩坑与经验
├── start-superagent.cmd    # superagent 服务启动入口
├── start-superagent.ps1
└── README-superagent.md    # superagent 原始说明
```

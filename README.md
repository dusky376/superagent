# superagent

飞书（Lark）× GitHub 的**主动型编程智能体**：在飞书群里 @ 机器人提需求，它会开工作单、
在独立目录里真正写代码，再把结果回到原对话（例如一个 Pull Request）。基于
[dsh-superagent](https://github.com/deepseek-ai/dsh-superagent-prototype)（研究原型）。

> 本仓库只包含**自写代码、平台修复与文档**。第三方依赖与凭据（`dsh-cli/`、`repo/`、
> `tools/gh/`、`state/`、`.gh-agent/`、`lark-cli-bot/` 配置）已被 `.gitignore` 排除。

---

## 一、架构

```
飞书群 @机器人 ──┐
                ├─▶ Feishu Source ─┐
GitHub 通知 ────┘                  ├─▶ Policy 授权 ─▶ 工单 ─▶ 独立 DSH Session 执行 ─▶ 回到原对话
                GitHub Source ─────┘                     （按需开 PR / 改仓库文件）
```

关键点：**不要手写回声机器人**。superagent 自带 Feishu Source，它才是正确的入口——
手写的固定规则机器人与它抢同一个 bot open_id，且完全绕开了工单、授权、执行能力。

---

## 二、运行

```powershell
.\start-superagent.cmd            # 启动并打开面板
.\start-superagent.cmd -NoOpen    # 只启动
.\start-superagent.cmd -Status    # 状态
.\start-superagent.cmd -Stop      # 停止
.\start-superagent.cmd -Restart   # 重启
```

面板：`http://127.0.0.1:3082/`，侧边栏 → Superagent。

---

## 三、配置（必须走管理 API）

配置**不读** `cordis.patch.yml`，而是存在 settings 数据库里，用 API 写入。
必须带请求头 `x-orchestrator-request: 1`，且**不要**加 `Origin`（会触发同源检查返回 404）。

```powershell
$h = @{ 'x-orchestrator-request' = '1' }
$api = 'http://127.0.0.1:3082/orchestrator/api'

# 状态与配置
GET  $api/state      # health.{runtime,github,feishu,history}
GET  $api/settings   # blocks.{policy,eval,executor}
```

四个必配项：

| 顺序 | 块 | 要点 |
|---|---|---|
| 1 | `source:github` | `repository` + `cli`（gh 包装器）。**没配它整个部署不通过**，飞书会卡 `setupPending` |
| 2 | `source:feishu` | `cli`（lark-cli 包装器）+ `chats[{chatId,listen}]` + `directMessages` + `otherChats` |
| 3 | `policy` | `sources.feishu.allowed[{id: ou_…}]`、`sources.github.allowed[{id: <login>}]`；不配则无人可发起工作 |
| 4 | `eval` | **`mode` 必须是 `auto`**；默认 `observe` 只观察不执行 |

完整 JSON 示例见 [踩坑与复利.md](./踩坑与复利.md) 第 3.1 节。

---

## 四、两个独立包装器

superagent 拒绝能扮演用户的 CLI，所以两者都必须用**独立配置目录**：

| 包装器 | 作用 | 隔离方式 |
|---|---|---|
| `lark-cli-bot/lark-bot.cmd` | 飞书 bot 身份 | `LARKSUITE_CLI_CONFIG_DIR` 指向独立目录，配置带 `strictMode: "bot"`，**复用主配置的 keychain 引用，不取密钥明文** |
| `tools/gh/gh-agent.cmd` | GitHub 智能体身份 | `GH_CONFIG_DIR` 指向独立目录，`hosts.yml` 存 user + token |

> 两者都只影响各自进程，不污染个人 `lark-cli` / `gh` 登录态。

---

## 五、Windows 兼容性修复

原型的源码**没有一处 `process.platform` 判断**，在 Windows 上有 5 处 POSIX 假设，已全部修复
（修改 `repo/src` 后需 `pnpm build`）：

| # | 位置 | 症状 |
|---|------|------|
| 1 | `deployment.ts` `absolute()` | `stateDir` 正则只认 `/`，但 DSH 又拒绝 root-relative 路径 → 改为接受盘符 |
| 2 | `deployment.ts` `workerProbe()` | `spawn env ENOENT`（Windows 无 POSIX `env`） |
| 3 | `deployment.ts` `resolveFeishuBot()` | 同上，飞书探测也用了 `env` |
| 4 | `sessions.ts` `tools.restrict()` | `unknown global tool "bash"`（Windows 只有 `pwsh`） |
| 5 | `feishu-loops.ts` / `commands.ts` | `.cmd` 直接 spawn → `EINVAL`；加 shell 后 JSON 参数被拆散 → 走 `cmd /d /s /c` + 逐参数转义 |

细节与排障顺序见 [踩坑与复利.md](./踩坑与复利.md) 第 3.3 / 3.5 节。

---

## 六、排障

**看到 `/orchestrator/api/*` 全部 404，先看 `superagent.err.log`。**
出现 `dsh: warning: N entries did not activate` 说明插件激活失败，HTTP 路由根本没注册——
这不是路径或鉴权问题。修好后 `-Stop` → `pnpm build` → `-NoOpen` 重跑。

已知未解决：补收群历史需要 `im:message.group_msg` 权限，当前只有 `group_at_msg`，
`history` 健康项会报 `230027`。**不影响 @ 消息的实时接收与执行**，只影响补收历史消息。

---

## 七、踩坑记录

见 [踩坑与复利.md](./踩坑与复利.md)。最关键的一条：

> 一开始手写了固定规则回声机器人（`lark-bot/`），方向就错了——superagent 本身就是
> 「来源 → 授权 → 工单 → 执行 → 回传」的完整平台，正确做法是启用内置 Feishu Source，
> 而不是另写一个只会说「收到」的机器人。

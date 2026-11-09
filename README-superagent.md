# dsh-superagent · Windows 一键启动包

官方仓库：<https://github.com/deepseek-ai/dsh-superagent-prototype>（commit `8c32a9d`）

> ⚠️ 官方 README 原文：**"Research prototype for reference only, not an official DeepSeek product."**
> 这是研究代码，不是生产软件；worker Session 以 `danger-full-access` 运行，可读整个用户目录。
> 请只在你信任的仓库上使用，并优先考虑独立的系统账户。

---

## 一、怎么用

双击 **`start-superagent.cmd`** 即可。它会启动服务、等服务就绪、自动打开面板。

命令行用法：

```bat
start-superagent.cmd              :: 启动（已在运行则只打开面板）
start-superagent.cmd -Stop        :: 停止
start-superagent.cmd -Restart     :: 重启
start-superagent.cmd -Status      :: 查看状态（运行=退出码0，未运行=1）
start-superagent.cmd -NoOpen      :: 启动但不打开浏览器
```

面板地址：`http://127.0.0.1:3082/?token=…`（token 每次启动会变，脚本会自动带上正确的那一个）。
界面入口：**侧边栏 → Superagent**。

---

## 二、目录里都是什么

| 路径 | 作用 |
|---|---|
| `start-superagent.cmd` | 一键入口（双击这个） |
| `start-superagent.ps1` | 实际逻辑：启停、健康检查、日志、锁清理 |
| `repo/` | 官方仓库克隆 + 本地构建产物 `repo/lib/` |
| `dsh-cli/` | 独立的 dsh `0.2.1-rc.5`，**不影响你桌面 App 的 0.2.2-rc.1** |
| `state/` | 运行态：`orchestrator.sqlite`（工单、设置、会话） |
| `superagent.log` / `superagent.err.log` | 运行日志 |
| `superagent.pid` | 当前监听进程号 |
| `state.lock.stale-*` | 强制停止后残留锁的备份，只保留最近 3 个 |

配置在 `C:\Users\Administrator\.dsh\profiles\superagent\cordis.patch.yml`（不在本目录）。

---

## 三、WorkBuddy 积分

已接入，沿用你桌面版同一个登录态：

```
CN (domestic): signed in as 鲜花送给老妈
  Access token expires 2026-11-30T11:06:08.000Z (refresh is automatic)
  Remaining credit: 3021.26000016
```

原理：WorkBuddy 凭据存在 `$DSH_HOME/workbuddy-vault/<region>/`，
所以 `superagent` profile 必须与前缀共用同一个 `DSH_HOME`（`C:\Users\Administrator\.dsh`）。
**这是有意为之，不要把它改成独立目录，否则积分会失效。**

默认模型：`workbuddy / deepseek-v4.1-flash / high`（在 `cordis.patch.yml` 的 `agent-default-model` 段）。

自检命令：

```powershell
node "C:\Users\Administrator\.dsh\profiles\superagent\node_modules\dsh-connect-workbuddy\lib\bin.js" status
```

---

## 四、为什么需要这些 Windows 特化（三处硬改，都有源码依据）

插件由 POSIX 环境假设写成，在 Windows 上有 3 个坑。下面每条都能在官方源码里定位：

**1. `stateDir` 只接受以 `/` 开头的路径**

```ts
// repo/src/deployment.ts:13
const absolute = (description: string) => s.string().pattern(/^\//)
```

配置里用根相对形式 `/workspace/superagent/state`。Node 会把它解析到**当前盘符**，
所以服务必须从 E: 盘启动——脚本用 `Win32_Process.Create` 的 `CurrentDirectory` 固定了这一点。

> 试过的其它写法：`//?/E:/…` 能过正则，但 `proper-lockfile` 的 `realpath` 会报
> `EISDIR: lstat 'E:'`；`/E:/…` 会拼成 `E:\E:\…`。都不行。

**2. worker 命令 shim 是 `#!/bin/sh` 脚本**

```ts
// repo/src/infra/environment.ts:89
await writeFile(temporary, `#!/bin/sh\n${MARKER}\n${body}\n`, { mode: 0o755 })
```

**这一处尚未处理。** 影响范围：面板、设置、模型、积分都正常；但一旦真的派发 GitHub 任务，
worker 启动阶段写 shim 会失败。要打通需改源码（偏离官方），需另行批准。

**3. 官方 `scripts/dsh-superagent` 依赖 tmux + fcntl**

```python
# repo/scripts/dsh-superagent:10,166
import fcntl
if not dsh or not shutil.which('tmux'):
    raise RuntimeError('Both dsh and tmux must be on PATH.')
```

Windows 上没有，所以本包用 `start-superagent.ps1` 替代它（PID 文件 + netstat 检测）。

**4. 强制停止会残留锁**（本包已处理）

`proper-lockfile` 锁的是 `<stateDir>.lock`。`Stop-Process -Force` 不会清理它，
下次启动就报 `Lock file is already being held`。脚本在停止后和启动前都会清掉这个残留锁，
只保留最近 3 份备份。

---

## 五、当前状态

```
[OK]   服务启动 / 停止 / 重启 / 状态查询      全部通过（8/8 回归）
[OK]   WorkBuddy 积分                         可用，余额 3021.26
[OK]   面板与 orchestrator API                200
[待办] GitHub 仓库与 gh CLI                   面板里填（setup.problem = repositoryUnset）
[待办] worker 派发任务                        Windows 下 shim 需改源码才能通
```

`GET /orchestrator/api/state` 现在返回：

```json
"problem": { "place": "github", "code": "repositoryUnset",
             "detail": "The GitHub Source names no repository." }
```

这是设计上的正常状态，不是故障。

---

## 六、重建步骤（万一需要从零来）

```powershell
# 1) 独立 dsh（满足官方 engines.dsh = ^0.2.1-alpha.2）
npm install -g --prefix E:\workspace\superagent\dsh-cli @deepseek-ai/dsh@0.2.1-rc.5

# 2) 克隆 + 构建（仓库未提交 lib/）
git clone --depth 1 https://github.com/deepseek-ai/dsh-superagent-prototype E:\workspace\superagent\repo
cd E:\workspace\superagent\repo
corepack prepare pnpm@11.7.0 --activate     # 仓库 packageManager 要求
pnpm install; pnpm build

# 3) profile（共享 DSH_HOME 以复用 WorkBuddy 登录）
$env:DSH_HOME = 'C:\Users\Administrator\.dsh'
$dsh = 'E:\workspace\superagent\dsh-cli\dsh.cmd'
& $dsh superagent --from-default-profile web --dump-config > $null
& $dsh plugin --profile superagent add "link:E:\workspace\superagent\repo"
& $dsh plugin --profile superagent add dsh-connect-workbuddy@5.16.0

# 4) 写 machine 配置：见 cordis.patch.yml 的 webServer / stateDir / agent-default-model 三段
# 5) 用 start-superagent.cmd 启动
```

> 升级 `repo/` 后要重跑 `pnpm build`，然后 `start-superagent.cmd -Restart`。
> 注意：官方 `--from-default-profile` 会**覆盖并删除** `cordis.patch.yml`，升级时不要用。

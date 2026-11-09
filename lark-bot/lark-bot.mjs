// lark-bot.mjs —— 飞书群 @ 应答机器人（常驻进程）
// 用法：node lark-bot.mjs
// 职责：订阅 im.message.receive_v1，只处理"群里 @ 机器人"的消息，按规则回复。
// AI 接口预留：见 makeReply() 内的 TODO 分支。

import { spawn } from 'node:child_process';
import { appendFileSync, mkdirSync, existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const DATA_DIR = join(HERE, 'data');
if (!existsSync(DATA_DIR)) mkdirSync(DATA_DIR, { recursive: true });

// ── lark-cli 可执行文件（绕开 .cmd/.ps1 包装层与 shell，避免特殊字符被拆分）
const CLI_ENTRY = process.env.LARK_CLI_ENTRY
  || join(process.env.APPDATA || '', 'npm', 'node_modules', '@larksuite', 'cli', 'bin', 'lark-cli.exe');

const LOG_FILE = join(DATA_DIR, 'bot.log');
const SEEN_FILE = join(DATA_DIR, 'seen.json');

// ── 本机器人的 open_id（从实测事件 mentions[].id 确认，可用环境变量覆盖）
const BOT_OPEN_ID = process.env.LARK_BOT_OPEN_ID || 'ou_dd61c7d2f77e8ef5b4d16506bc30180d';

// ── 配置：允许回复的群（空数组 = 不限制）
const ALLOWED_CHATS = (process.env.LARK_ALLOWED_CHATS || '')
  .split(',').map((s) => s.trim()).filter(Boolean);

function log(msg) {
  const line = `[${new Date().toISOString()}] ${msg}`;
  console.log(line);
  try { appendFileSync(LOG_FILE, line + '\n', 'utf8'); } catch { /* 日志失败不影响主流程 */ }
}

// ── 消息去重（服务端可能重复推送；按 message_id 去重，不用 event_id）
const seen = new Set();
try {
  if (existsSync(SEEN_FILE)) {
    for (const id of JSON.parse(readFileSync(SEEN_FILE, 'utf8'))) seen.add(id);
  }
} catch { /* 忽略 */ }
function isDuplicate(messageId) {
  if (seen.has(messageId)) return true;
  seen.add(messageId);
  if (seen.size > 5000) { // 控制内存
    const keep = [...seen].slice(-2000);
    seen.clear(); keep.forEach((x) => seen.add(x));
    try { appendFileSync(SEEN_FILE, '', 'utf8'); } catch { /* 忽略 */ }
  }
  return false;
}

// ── 回复规则：命中即返回；返回 null 表示不回复
function makeReply(text) {
  const t = (text || '').replace(/@\S+/g, '').trim(); // 去掉 @ 占位

  // 1) 固定命令
  if (/^(帮助|help|\?)$/i.test(t)) {
    return [
      '我是飞书 CLI 机器人，可用指令：',
      '· 帮助 —— 显示本说明',
      '· 时间 —— 当前时间',
      '· ping —— 连通性测试',
      '· 复制 <内容> —— 原样回显',
      '',
      '其他内容请直接提，我会记录并回复。',
    ].join('\n');
  }
  if (/^(时间|time)$/i.test(t)) {
    return `当前时间：${new Date().toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' })}`;
  }
  if (/^ping$/i.test(t)) return 'pong 🏓';
  if (/^复制\s+/.test(t)) return t.replace(/^复制\s+/, '');

  // 2) AI 接口预留（TODO：接入本地模型或 WorkBuddy 后放开）
  // if (process.env.LARK_AI_ENABLED === '1') { return await askAI(t); }

  // 3) 默认回复
  if (!t) return '我在，有什么可以帮你？（发送「帮助」查看指令）';
  return `收到：「${t}」\n（当前为规则模式，发送「帮助」查看指令）`;
}

// ── 用 lark-cli 作为 bot 发消息（复用已有登录态，无需另配密钥）
function sendToChat(chatId, text) {
  return new Promise((resolve) => {
    const args = ['im', '+messages-send', '--as', 'bot', '--chat-id', chatId, '--text', text];
    // 关键：不用 shell。Windows 下 shell:true 会让含「」等字符的文本被错误拆分。
    const child = spawn(CLI_ENTRY, args, { windowsHide: true });
    let out = '', err = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { err += d; });
    child.on('close', (code) => {
      if (code === 0) {
        log(`回复成功 chat=${chatId} len=${text.length}`);
      } else {
        log(`回复失败 code=${code} err=${err.slice(0, 400)}`);
      }
      resolve(code === 0);
    });
    child.on('error', (e) => { log(`spawn 失败: ${e.message}`); resolve(false); });
  });
}

// ── 主循环：启动 lark-cli 事件消费子进程，逐行读取 NDJSON
function start() {
  log(`启动机器人 BOT_OPEN_ID=${BOT_OPEN_ID} chats=${ALLOWED_CHATS.length ? ALLOWED_CHATS.join(',') : '(全部)'}`);

  const consumer = spawn(
    CLI_ENTRY,
    ['event', 'consume', 'im.message.receive_v1', '--as', 'bot'],
    { windowsHide: true },
  );

  let buffer = '';

  consumer.stdout.on('data', async (chunk) => {
    buffer += chunk.toString('utf8');
    const lines = buffer.split('\n');
    buffer = lines.pop() ?? '';
    for (const line of lines) {
      const s = line.trim();
      if (!s) continue;
      let evt;
      try { evt = JSON.parse(s); } catch { continue; }
      try {
        await handleEvent(evt);
      } catch (e) {
        log(`处理事件异常: ${e.message}`);
      }
    }
  });

  consumer.stderr.on('data', (d) => {
    for (const line of d.toString('utf8').split('\n')) {
      if (line.trim()) log(`[consumer] ${line.trim()}`);
    }
  });

  consumer.on('close', (code) => {
    log(`事件消费进程退出 code=${code}，5 秒后重启`);
    setTimeout(start, 5000); // 自愈重启
  });
  consumer.on('error', (e) => {
    log(`无法启动事件消费进程: ${e.message}`);
    setTimeout(start, 5000);
  });
}

async function handleEvent(evt) {
  if (evt.type !== 'im.message.receive_v1') return;

  const { chat_id: chatId, chat_type: chatType, content, message_id: messageId, sender_id: senderId, sender_type: senderType } = evt;

  // 只处理群聊 + @ 当前机器人
  if (chatType !== 'group') return;
  if (!Array.isArray(evt.mentions) || !evt.mentions.some((m) => m.id === BOT_OPEN_ID)) return;
  if (ALLOWED_CHATS.length && !ALLOWED_CHATS.includes(chatId)) return;
  if (messageId && isDuplicate(messageId)) { log(`跳过重复消息 ${messageId}`); return; }

  const text = (content || '').trim();
  log(`收到 @ 消息 chat=${chatId} from=${senderId}(${senderType}) text=${text}`);

  const reply = makeReply(text);
  if (!reply) return;
  await sendToChat(chatId, reply);
}

process.on('SIGINT', () => { log('收到 SIGINT，退出'); process.exit(0); });
process.on('SIGTERM', () => { log('收到 SIGTERM，退出'); process.exit(0); });
process.on('uncaughtException', (e) => log(`未捕获异常: ${e.stack || e.message}`));

start();

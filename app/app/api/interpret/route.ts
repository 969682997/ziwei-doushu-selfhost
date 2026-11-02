import { NextRequest } from 'next/server';
import { getReading, readingKey } from '@/lib/server/interp-db';
import { buildSystem, DIM_LABEL, BRANCH, type PromptContext } from '@/lib/server/prompt';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';
export const maxDuration = 120;

/**
 * POST /api/interpret
 *
 * 兼容 OpenAI Chat Completions 协议的任意上游（默认对接 PackyCode）。
 * 前端按 SSE 读取 { delta: { text } }。
 *
 * 用量控制：命盘 13 维正文已由本地库给出，这里只把「当前这一维 + 命盘骨架」
 * 作为上下文送给模型，避免把 3 万字全量塞进去烧 token。
 */
const BASE_URL = (process.env.PACKYCODE_BASE_URL || 'https://www.packyapi.com/v1')
  .replace(/\/+$/, '');
const API_KEY = process.env.PACKYCODE_API_KEY || '';
const MODEL = process.env.PACKYCODE_MODEL || 'claude-sonnet-4-5';
const TIMEOUT_MS = Number(process.env.AI_TIMEOUT_MS || 90000);

/**
 * 极简 IP 限流。站点对外公开，AI 接口不设防会被刷爆额度。
 * 单进程内存计数即可——本项目是单容器部署，不需要 Redis。
 */
const RATE_LIMIT = Number(process.env.AI_RATE_LIMIT || 30); // 每小时每 IP 次数
const RATE_WINDOW = 3600_000;
const hits = new Map<string, { n: number; reset: number }>();

function allow(ip: string): boolean {
  if (RATE_LIMIT <= 0) return true;
  const now = Date.now();
  const rec = hits.get(ip);
  if (!rec || now > rec.reset) {
    if (hits.size > 5000) {
      for (const [k, v] of hits) if (now > v.reset) hits.delete(k);
    }
    hits.set(ip, { n: 1, reset: now + RATE_WINDOW });
    return true;
  }
  if (rec.n >= RATE_LIMIT) return false;
  rec.n += 1;
  return true;
}

interface Ctx {
  key?: string;
  dim?: string;
  summary?: string;
}

/** 组装上下文：命主信息 + 当前维度正文 + 命盘骨架 */
function buildContext(ctx: Ctx): PromptContext {
  const out: PromptContext = { summary: ctx.summary };
  if (!ctx.key) return out;

  const r = getReading(ctx.key);
  if (!r) return out;

  const dim = ctx.dim && DIM_LABEL[ctx.dim] ? ctx.dim : 'overview';
  const body = (r.dims as Record<string, string>)[dim] || '';
  out.reading = {
    meta: `公历 ${r.solar.year}-${r.solar.month}-${r.solar.day}，${BRANCH[r.hour]}时，`
      + `${r.gender === 'female' ? '女' : '男'}命，命宫主星 ${r.mainStar || '无（空宫）'}。`
      + `本次提问针对「${DIM_LABEL[dim]}」这一维。`,
    body: `【${DIM_LABEL[dim]}】\n${body}`,
  };
  return out;
}

export async function POST(req: NextRequest) {
  if (!API_KEY) {
    return Response.json(
      { error: '未配置 PACKYCODE_API_KEY，AI 追问不可用。请在 .env 中填写后重启。' },
      { status: 503 },
    );
  }

  const ip =
    req.headers.get('x-forwarded-for')?.split(',')[0].trim() ||
    req.headers.get('x-real-ip') ||
    'local';

  if (!allow(ip)) {
    return Response.json(
      { error: `请求过于频繁，每个 IP 每小时上限 ${RATE_LIMIT} 次，请稍后再试。` },
      { status: 429 },
    );
  }

  let payload: { messages?: { role: string; content: string }[]; context?: Ctx };
  try {
    payload = await req.json();
  } catch {
    return Response.json({ error: '请求体不是合法 JSON' }, { status: 400 });
  }

  const history = (payload.messages || [])
    .filter((m) => m && typeof m.content === 'string')
    .slice(-8)
    .map((m) => ({
      role: m.role === 'assistant' ? 'assistant' : ('user' as const),
      content: m.content.slice(0, 4000),
    }));

  if (history.length === 0) {
    return Response.json({ error: '缺少 messages' }, { status: 400 });
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  let upstream: Response;
  try {
    upstream = await fetch(`${BASE_URL}/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${API_KEY}`,
      },
      body: JSON.stringify({
        model: MODEL,
        stream: true,
        temperature: 0.5,
        max_tokens: 1600,
        messages: [{ role: 'system', content: buildSystem(buildContext(payload.context || {})) }, ...history],
      }),
      signal: controller.signal,
    });
  } catch (e) {
    clearTimeout(timer);
    const msg = e instanceof Error ? e.message : String(e);
    return Response.json({ error: `上游连接失败：${msg}` }, { status: 502 });
  }

  if (!upstream.ok || !upstream.body) {
    clearTimeout(timer);
    const detail = await upstream.text().catch(() => '');
    return Response.json(
      { error: `上游返回 ${upstream.status}`, detail: detail.slice(0, 500) },
      { status: 502 },
    );
  }

  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const reader = upstream.body.getReader();
  let buffer = '';

  const stream = new ReadableStream({
    async pull(ctrl) {
      try {
        const { done, value } = await reader.read();
        if (done) {
          clearTimeout(timer);
          ctrl.close();
          return;
        }
        buffer += decoder.decode(value, { stream: true });
        const parts = buffer.split('\n');
        buffer = parts.pop() || '';

        for (const line of parts) {
          const t = line.trim();
          if (!t.startsWith('data:')) continue;
          const data = t.slice(5).trim();
          if (!data || data === '[DONE]') continue;
          try {
            const j = JSON.parse(data);
            const delta = j.choices?.[0]?.delta?.content;
            if (delta) {
              ctrl.enqueue(encoder.encode(`data: ${JSON.stringify({ delta: { text: delta } })}\n\n`));
            }
          } catch {
            /* 上游偶发非 JSON 心跳，忽略 */
          }
        }
      } catch (e) {
        clearTimeout(timer);
        const msg = e instanceof Error ? e.message : String(e);
        ctrl.enqueue(encoder.encode(`data: ${JSON.stringify({ error: msg })}\n\n`));
        ctrl.close();
      }
    },
    cancel() {
      clearTimeout(timer);
      reader.cancel().catch(() => {});
    },
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    },
  });
}

export async function GET() {
  return Response.json({
    ok: Boolean(API_KEY),
    model: MODEL,
    baseUrl: BASE_URL,
    hint: readingKey(2000, 1, 1, 0, 'male'),
  });
}

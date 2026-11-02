'use client';

import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from 'react';
import type { ZiweiChart } from '@/lib/ziwei/types';

const DIMS = [
  'overview', 'personality', 'love', 'career', 'wealth', 'health',
  'family', 'children', 'move', 'friends', 'home', 'spirit', 'parents',
] as const;

type DimKey = (typeof DIMS)[number];

const LABEL: Record<DimKey, string> = {
  overview: '命格总览', personality: '性格', love: '感情', career: '事业',
  wealth: '财运', health: '健康', family: '兄弟', children: '子女',
  move: '迁移', friends: '人际', home: '田宅', spirit: '福德', parents: '父母',
};

const HEXAGRAM: Record<string, string> = {
  overview: '总', personality: '性', love: '情', career: '业', wealth: '财',
  health: '疾', family: '兄', children: '子', move: '迁', friends: '友',
  home: '宅', spirit: '福', parents: '父',
};

interface ReadingState {
  status: 'loading' | 'ok' | 'missing' | 'error';
  dims?: Record<string, string>;
  message?: string;
  mainStar?: string | null;
}

export default function ReadingPanel({ chart }: { chart: ZiweiChart }) {
  const { year, month, day, hour, gender } = chart.birthInfo;
  const key = `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}-${hour}-${gender}`;

  const [reading, setReading] = useState<ReadingState>({ status: 'loading' });
  const [active, setActive] = useState<DimKey>('overview');
  const [question, setQuestion] = useState('');
  const [answer, setAnswer] = useState('');
  const [asking, setAsking] = useState(false);
  const answerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let alive = true;
    setReading({ status: 'loading' });
    fetch(`/api/reading?y=${year}&m=${month}&d=${day}&h=${hour}&g=${gender}`)
      .then((r) => r.json())
      .then((j) => {
        if (!alive) return;
        if (j.found) setReading({ status: 'ok', dims: j.dims, mainStar: j.mainStar });
        else setReading({ status: 'missing', message: j.message });
      })
      .catch(() => alive && setReading({ status: 'error', message: '解读库读取失败' }));
    return () => { alive = false; };
  }, [year, month, day, hour, gender]);

  const text = reading.dims?.[active] || '';

  // 命盘骨架，作为 AI 上下文
  const summary = useMemo(() => {
    const names = ['子', '丑', '寅', '卯', '辰', '巳', '午', '未', '申', '酉', '戌', '亥'];
    const palaces = chart.palaces
      .map((p) => `${p.name}(${names[p.branch]}): ${p.stars.map((s) => s.name + (s.siHua ? '化' + s.siHua : '')).join('、') || '空宫'}`)
      .join('；');
    return `命宫在${names[chart.mingGongBranch]}，身宫在${names[chart.shenGongBranch]}。${palaces}`;
  }, [chart]);

  const ask = useCallback(async () => {
    const q = question.trim();
    if (!q || asking) return;
    setAsking(true);
    setAnswer('');
    setQuestion('');
    try {
      const res = await fetch('/api/interpret', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          messages: [{ role: 'user', content: q }],
          context: { key, dim: active, summary },
        }),
      });
      if (!res.ok || !res.body) {
        const j = await res.json().catch(() => ({}));
        setAnswer(`⚠️ ${j.error || 'AI 服务暂不可用'}`);
        return;
      }
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let acc = '';
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        const chunk = decoder.decode(value, { stream: true });
        for (const line of chunk.split('\n')) {
          if (!line.startsWith('data:')) continue;
          const raw = line.slice(5).trim();
          if (!raw) continue;
          try {
            const j = JSON.parse(raw);
            if (j.delta?.text) {
              acc += j.delta.text;
              setAnswer(acc);
            } else if (j.error) {
              setAnswer(acc + `\n\n⚠️ ${j.error}`);
            }
          } catch { /* 忽略半包 */ }
        }
      }
    } catch (e) {
      setAnswer(`⚠️ ${e instanceof Error ? e.message : '请求失败'}`);
    } finally {
      setAsking(false);
      requestAnimationFrame(() => answerRef.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest' }));
    }
  }, [question, asking, key, active, summary]);

  return (
    <aside style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
      <div style={card}>
        <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 10 }}>
          <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>十三维解读</h2>
          {reading.mainStar && (
            <span style={{ fontSize: 12, color: 'var(--color-text-tertiary, #888)' }}>
              命宫主星 · {reading.mainStar}
            </span>
          )}
        </div>

        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, marginBottom: 12 }}>
          {DIMS.map((d) => {
            const on = d === active;
            return (
              <button
                key={d}
                type="button"
                onClick={() => setActive(d)}
                style={{
                  padding: '4px 9px', fontSize: 12, cursor: 'pointer',
                  borderRadius: 6, lineHeight: 1.5,
                  border: `1px solid ${on ? '#0F6E56' : 'rgba(0,0,0,0.12)'}`,
                  background: on ? '#E1F5EE' : 'transparent',
                  color: on ? '#085041' : 'inherit',
                  fontWeight: on ? 600 : 400,
                }}
              >
                {LABEL[d]}
              </button>
            );
          })}
        </div>

        <div style={{ minHeight: 260, maxHeight: 520, overflowY: 'auto', paddingRight: 4 }}>
          {reading.status === 'loading' && <p style={dim}>读取中…</p>}
          {reading.status === 'missing' && (
            <p style={{ ...dim, color: '#a15c00' }}>{reading.message}</p>
          )}
          {reading.status === 'error' && (
            <p style={{ ...dim, color: '#A32D2D' }}>{reading.message}</p>
          )}
          {reading.status === 'ok' && <Markdown source={text} />}
        </div>
      </div>

      <div style={card}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 8 }}>
          <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>就这一条问 AI</h2>
          <span style={{ fontSize: 11, color: 'var(--color-text-tertiary, #999)' }}>
            会带上「{LABEL[active]}」作上下文
          </span>
        </div>
        <div style={{ display: 'flex', gap: 6 }}>
          <input
            value={question}
            onChange={(e) => setQuestion(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') ask(); }}
            placeholder="例：这条对宫化忌怎么看？"
            style={{
              flex: 1, padding: '8px 10px', fontSize: 13, borderRadius: 8,
              border: '1px solid rgba(0,0,0,0.15)', background: 'transparent', outline: 'none',
            }}
          />
          <button
            type="button"
            onClick={ask}
            disabled={asking || !question.trim()}
            style={{
              padding: '8px 16px', fontSize: 13, borderRadius: 8, cursor: asking ? 'default' : 'pointer',
              border: '1px solid #0F6E56', background: asking ? '#9FE1CB' : '#0F6E56', color: '#fff',
            }}
          >
            {asking ? '思考中' : '提问'}
          </button>
        </div>
        {answer && (
          <div ref={answerRef} style={{ marginTop: 12, fontSize: 13, lineHeight: 1.75 }}>
            <Markdown source={answer} />
          </div>
        )}
      </div>

      <p style={{ fontSize: 11, color: 'var(--color-text-tertiary, #999)', lineHeight: 1.6, margin: 0 }}>
        解读数据来自开源数据集 v4.0（674,976 张命盘 × 13 维），
        <a href="https://github.com/Renhuai123/ziwei-doushu" target="_blank" rel="noreferrer"
           style={{ color: 'inherit', textDecoration: 'underline' }}>
          CC BY 4.0
        </a>
        。命理内容仅供参考，不构成医疗、投资或法律建议。
      </p>
    </aside>
  );
}

const card: CSSProperties = {
  border: '1px solid rgba(0,0,0,0.1)',
  borderRadius: 12,
  padding: 16,
  background: 'var(--color-background-primary, #fff)',
};

const dim: CSSProperties = { fontSize: 13, color: 'var(--color-text-secondary, #777)', margin: 0 };

/** 轻量 Markdown：标题 / 加粗 / 列表 / 引用，够用即可 */
function Markdown({ source }: { source: string }) {
  const blocks = source.split('\n');
  return (
    <div style={{ fontSize: 13.5, lineHeight: 1.85 }}>
      {blocks.map((line, i) => {
        const t = line.trim();
        if (!t) return <div key={i} style={{ height: 6 }} />;
        if (t.startsWith('### ')) return <h4 key={i} style={h4}>{inline(t.slice(4))}</h4>;
        if (t.startsWith('## ')) return <h3 key={i} style={h4}>{inline(t.slice(3))}</h3>;
        if (t.startsWith('# ')) return <h3 key={i} style={h4}>{inline(t.slice(2))}</h3>;
        if (t.startsWith('> ')) return <blockquote key={i} style={quote}>{inline(t.slice(2))}</blockquote>;
        if (/^[-*·]\s/.test(t)) return <div key={i} style={li}><span style={{ color: '#0F6E56' }}>·</span> {inline(t.slice(2))}</div>;
        if (/^\d+[.、]\s?/.test(t)) return <div key={i} style={li}>{inline(t)}</div>;
        return <p key={i} style={{ margin: '0 0 2px' }}>{inline(t)}</p>;
      })}
    </div>
  );
}

function inline(s: string) {
  const parts = s.split(/(\*\*[^*]+\*\*)/g);
  return parts.map((p, i) =>
    p.startsWith('**') && p.endsWith('**')
      ? <strong key={i} style={{ fontWeight: 600 }}>{p.slice(2, -2)}</strong>
      : <span key={i}>{p}</span>,
  );
}

const h4: CSSProperties = { fontSize: 13.5, fontWeight: 600, margin: '14px 0 6px', color: '#085041' };
const quote: CSSProperties = {
  margin: '6px 0', padding: '6px 10px', borderLeft: '2px solid #9FE1CB',
  color: 'var(--color-text-secondary, #666)', fontSize: 13,
};
const li: CSSProperties = { paddingLeft: 12, margin: '1px 0', textIndent: -8 };

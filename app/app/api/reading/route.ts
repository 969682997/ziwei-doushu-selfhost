import { NextRequest } from 'next/server';
import { getReading, readingKey, supportsYear, DIMS, type DimKey } from '@/lib/server/interp-db';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

/**
 * GET /api/reading?y=1990&m=1&d=1&h=0&g=male[&dim=overview]
 *
 * 从本地解读数据库取该命盘的 13 维解读。不调用任何大模型，零 token 成本。
 */
export async function GET(req: NextRequest) {
  const q = req.nextUrl.searchParams;
  const y = Number(q.get('y'));
  const m = Number(q.get('m'));
  const d = Number(q.get('d'));
  const h = Number(q.get('h'));
  const g = q.get('g') === 'female' ? 'female' : 'male';

  if (![y, m, d, h].every(Number.isInteger) || h < 0 || h > 11) {
    return Response.json({ error: '参数不合法：需要 y/m/d 整数与 h 时辰序号 0–11' }, { status: 400 });
  }
  if (!supportsYear(y)) {
    return Response.json({
      found: false,
      reason: 'out-of-range',
      message: `离线解读库覆盖 1950–2026 年。${y} 年出生暂不在覆盖范围内，可使用 AI 追问生成。`,
    });
  }

  const key = readingKey(y, m, d, h, g);
  const reading = getReading(key);
  if (!reading) {
    return Response.json({
      found: false,
      reason: 'no-record',
      key,
      message: '该出生信息在离线解读库中没有对应记录（可能日期不存在或时辰越界）。',
    });
  }

  const dim = q.get('dim') as DimKey | null;
  if (dim && DIMS.includes(dim)) {
    return Response.json({
      found: true, key, solar: reading.solar, hour: reading.hour,
      gender: reading.gender, mainStar: reading.mainStar,
      dim, text: reading.dims[dim],
    });
  }

  return Response.json({ found: true, ...reading });
}

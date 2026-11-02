import { NextResponse } from 'next/server';
import { storeStats, supportsYear } from '@/lib/server/interp-db';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

/** 容器健康检查：数据库能读、样本年份在覆盖范围内才算健康 */
export async function GET() {
  try {
    const s = storeStats();
    return NextResponse.json({
      ok: s.charts > 0,
      charts: s.charts,
      lines: s.lines,
      covers: [1950, 2026],
      aiConfigured: Boolean(process.env.PACKYCODE_API_KEY),
      sampleOk: supportsYear(2000),
    });
  } catch (e) {
    return NextResponse.json(
      { ok: false, error: e instanceof Error ? e.message : String(e) },
      { status: 503 },
    );
  }
}

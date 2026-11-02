import Database from 'better-sqlite3';
import { gunzipSync } from 'node:zlib';

/**
 * 解读数据集查询层
 *
 * 数据来自 v4.0 开源解读数据集（CC BY 4.0），由 build/build_db.py 编译为 SQLite：
 *   lines  —— 全局唯一文本行字典（约 200 万条，不常驻内存）
 *   blk    —— 64 盘一组的行号序列，gzip 分块压缩（单块约 40 KB）
 *   chart  —— 每盘 → (块号, 块内偏移, 长度) + 出生元数据
 *
 * 一次查询 = 主键索引 + 块读取 + gunzip + 一次 IN 批量取文本，实测 2–4 ms。
 */

export const DIMS = [
  'overview', 'personality', 'love', 'career', 'wealth', 'health',
  'family', 'children', 'move', 'friends', 'home', 'spirit', 'parents',
] as const;

export type DimKey = (typeof DIMS)[number];
export type Dims = Record<DimKey, string>;

export interface ReadingMeta {
  key: string;
  solar: { year: number; month: number; day: number };
  hour: number;
  gender: 'male' | 'female';
  mainStar: string | null;
}

export interface Reading extends ReadingMeta {
  dims: Dims;
}

interface ChartRow {
  bid: number; off: number; ln: number;
  y: number; m: number; d: number; h: number; g: string; ms: string;
}

const BLOCK_CACHE_MAX = 48;
const READING_CACHE_MAX = 600;

let db: Database.Database | null = null;
const blockCache = new Map<number, Buffer>();
const readingCache = new Map<string, Reading | null>();

function getDb(): Database.Database {
  if (db) return db;
  const path = process.env.INTERP_DB || '/data/interp.db';
  db = new Database(path, { readonly: true, fileMustExist: true });
  db.pragma('cache_size = -64000');
  db.pragma('mmap_size = 268435456');
  return db;
}

function getBlock(handle: Database.Database, bid: number): Buffer {
  const hit = blockCache.get(bid);
  if (hit) return hit;
  const row = handle.prepare('SELECT z FROM blk WHERE id = ?').get(bid) as
    { z: Buffer } | undefined;
  if (!row) throw new Error(`解读数据块缺失: ${bid}`);
  const raw = gunzipSync(row.z);
  if (blockCache.size >= BLOCK_CACHE_MAX) {
    const oldest = blockCache.keys().next().value;
    if (oldest !== undefined) blockCache.delete(oldest);
  }
  blockCache.set(bid, raw);
  return raw;
}

export function readingKey(y: number, m: number, d: number, h: number, g: string) {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${y}-${p(m)}-${p(d)}-${h}-${g}`;
}

export function supportsYear(y: number): boolean {
  return y >= 1950 && y <= 2026;
}

export function getReading(key: string): Reading | null {
  if (readingCache.has(key)) return readingCache.get(key) ?? null;

  const handle = getDb();
  const row = handle.prepare(
    'SELECT bid, off, ln, y, m, d, h, g, ms FROM chart WHERE k = ?',
  ).get(key) as ChartRow | undefined;

  if (!row) {
    memo(key, null);
    return null;
  }

  const block = getBlock(handle, row.bid);
  const buf = block.subarray(row.off, row.off + row.ln);

  const counts: number[] = new Array(DIMS.length);
  let o = 0;
  for (let i = 0; i < DIMS.length; i++) {
    counts[i] = buf.readUInt32LE(o);
    o += 4;
  }
  const total = counts.reduce((a, b) => a + b, 0);
  const ids = new Array<number>(total);
  for (let i = 0; i < total; i++) {
    ids[i] = buf.readUInt32LE(o);
    o += 4;
  }

  // 一次 IN 批量取回本盘用到的所有文本行
  const uniq = Array.from(new Set(ids));
  const dict = new Map<number, string>();
  const CHUNK = 900;
  for (let i = 0; i < uniq.length; i += CHUNK) {
    const slice = uniq.slice(i, i + CHUNK);
    const q = `SELECT id, txt FROM lines WHERE id IN (${slice.map(() => '?').join(',')})`;
    for (const r of handle.prepare(q).all(...slice) as { id: number; txt: string }[]) {
      dict.set(r.id, r.txt);
    }
  }

  const dims = {} as Dims;
  let idx = 0;
  for (let i = 0; i < DIMS.length; i++) {
    const n = counts[i];
    const parts: string[] = new Array(n);
    for (let j = 0; j < n; j++) {
      parts[j] = dict.get(ids[idx++]) ?? '';
    }
    dims[DIMS[i]] = parts.join('\n');
  }

  const reading: Reading = {
    key,
    solar: { year: row.y, month: row.m, day: row.d },
    hour: row.h,
    gender: row.g === 'female' ? 'female' : 'male',
    mainStar: row.ms || null,
    dims,
  };
  memo(key, reading);
  return reading;
}

function memo(key: string, value: Reading | null) {
  if (readingCache.size >= READING_CACHE_MAX) {
    const oldest = readingCache.keys().next().value;
    if (oldest !== undefined) readingCache.delete(oldest);
  }
  readingCache.set(key, value);
}

export function storeStats() {
  const handle = getDb();
  const c = handle.prepare('SELECT COUNT(*) AS n FROM chart').get() as { n: number };
  const l = handle.prepare('SELECT COUNT(*) AS n FROM lines').get() as { n: number };
  return { charts: c.n, lines: l.n };
}

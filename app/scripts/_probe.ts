import { getReading, readingKey, storeStats, DIMS } from '../lib/server/interp-db';

console.log('库统计:', storeStats());

const cases = [
  [1990, 1, 1, 0, 'male'],
  [1968, 7, 22, 6, 'female'],
  [2000, 2, 29, 3, 'male'],
  [2026, 10, 30, 11, 'female'],
] as const;

let hit = 0, total = 0, empty = 0;
for (const [y, m, d, h, g] of cases) {
  const key = readingKey(y, m, d, h, g);
  const t0 = performance.now();
  const r = getReading(key);
  const ms = performance.now() - t0;
  total++;
  if (!r) { console.log(`✗ ${key} 未命中`); continue; }
  hit++;
  const lens = DIMS.map((k) => r.dims[k].length);
  const e = lens.filter((n) => n === 0).length;
  empty += e;
  console.log(`✓ ${key}  ${ms.toFixed(2)}ms  主星=${r.mainStar}  总字数=${lens.reduce((a,b)=>a+b,0)}  空维=${e}`);
}
console.log(`\n命中 ${hit}/${total}，空维合计 ${empty}`);

// 随机抽样压测
const t0 = performance.now();
let n = 0;
for (let i = 0; i < 300; i++) {
  const y = 1950 + Math.floor(Math.random() * 77);
  const m = 1 + Math.floor(Math.random() * 12);
  const d = 1 + Math.floor(Math.random() * 28);
  const h = Math.floor(Math.random() * 12);
  const g = Math.random() > 0.5 ? 'male' : 'female';
  if (getReading(readingKey(y, m, d, h, g))) n++;
}
const el = performance.now() - t0;
console.log(`随机 300 次：命中 ${n}，平均 ${(el/300).toFixed(2)} ms/次`);

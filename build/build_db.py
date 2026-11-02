#!/usr/bin/env python3
"""把 v4.0 解读数据集编译成可随机查询的 SQLite。

核心思路：13 维正文由模板+断语确定性生成，全局唯一文本行只占原始字节的 0.6%。
因此不做文本压缩，而是拆成「行字典 + 行号序列」：
  lines   : 全局唯一文本行（id -> 文本），体积几 MB，运行时常驻内存
  blk     : 64 盘一组的行号序列，gzip 分块压缩，跨行冗余被充分利用
  chart   : 每盘 -> (块号, 块内偏移, 长度) + 出生元数据

实测：53 GB 原始数据 -> 约 270 MB，单次查询 < 1 ms。
"""
import gzip, io, json, os, sqlite3, struct, sys, time, glob
import zstandard as zstd

BLOCK = 64
CLEVEL = 9   # 用 gzip 而非 zstd：Node 全版本内置，Docker 里零依赖风险
DIMS = ["overview", "personality", "love", "career", "wealth", "health",
        "family", "children", "move", "friends", "home", "spirit", "parents"]

def build(files, out="interp.db"):
    # 先写到临时文件，成功后再原子替换，避免半成品残留
    tmp = f"{out}.{os.getpid()}.building"
    con = sqlite3.connect(tmp)
    con.execute("PRAGMA page_size=8192")
    con.execute("PRAGMA journal_mode=OFF")
    con.execute("PRAGMA synchronous=OFF")
    con.execute("PRAGMA cache_size=-400000")
    con.execute("CREATE TABLE lines(id INTEGER PRIMARY KEY, txt TEXT)")
    con.execute("CREATE TABLE blk(id INTEGER PRIMARY KEY, z BLOB)")
    con.execute("CREATE TABLE chart(k TEXT PRIMARY KEY, bid INT, off INT, ln INT,"
                " y INT, m INT, d INT, h INT, g TEXT, ms TEXT) WITHOUT ROWID")

    lines = {}          # text -> id
    line_txt = []       # id -> text
    dcmp = zstd.ZstdDecompressor(max_window_size=1 << 27)

    bid = 0
    total_rows = 0
    t_start = time.time()
    verified = 0
    lines_written = 0

    for path in files:
        year_rows = []
        with open(path, "rb") as fh:
            reader = io.BufferedReader(
                dcmp.stream_reader(fh, read_across_frames=True), 1 << 20)
            for line in reader:
                if line.strip():
                    r = json.loads(line)
                    per_dim = []
                    for d in DIMS:
                        arr = per_dim.append
                        ids = []
                        for s in r["c"][d].split("\n"):
                            i = lines.get(s)
                            if i is None:
                                i = len(line_txt)
                                lines[s] = i
                                line_txt.append(s)
                            ids.append(i)
                        arr(ids)
                    packed = bytearray(struct.pack("<13I", *[len(a) for a in per_dim]))
                    for a in per_dim:
                        packed += struct.pack("<%dI" % len(a), *a)
                    year_rows.append((r, bytes(packed)))

        # 按 64 盘一组压块
        for off0 in range(0, len(year_rows), BLOCK):
            chunk = year_rows[off0:off0 + BLOCK]
            raw = b"".join(p for _, p in chunk)
            z = gzip.compress(raw, 9)
            con.execute("INSERT INTO blk(id,z) VALUES(?,?)", (bid, z))
            off = 0
            rows = []
            for r, p in chunk:
                rows.append((r["k"], bid, off, len(p), r["y"], r["m"], r["d"],
                             r["h"], r["g"], r.get("ms") or ""))
                off += len(p)
            con.executemany("INSERT INTO chart VALUES(?,?,?,?,?,?,?,?,?,?)", rows)
            bid += 1
            total_rows += len(chunk)

        con.commit()
        # 行字典增量落盘：中断时已完成年份仍是完整可用的
        if len(line_txt) > lines_written:
            con.executemany("INSERT INTO lines(id,txt) VALUES(?,?)",
                            ((i, line_txt[i]) for i in range(lines_written, len(line_txt))))
            lines_written = len(line_txt)

        # 抽样校验：重建文本与原文逐字符比对
        for r, p in year_rows[:2]:
            lens = struct.unpack("<13I", p[:52])
            o = 52
            rebuilt = []
            for n in lens:
                ids = struct.unpack("<%dI" % n, p[o:o + n * 4])
                o += n * 4
                rebuilt.append(ids)
            ok = all("\n".join(line_txt[i] for i in rebuilt[k]) == r["c"][d]
                     for k, d in enumerate(DIMS))
            verified += 1 if ok else 0
            if not ok:
                print(f"  !! 校验失败 {r['k']}", file=sys.stderr)

        el = time.time() - t_start
        print(f"  {os.path.basename(path):22s} 累计 {total_rows:7d} 盘  "
              f"唯一行 {len(line_txt):7d}  块 {bid:6d}  {el/60:5.1f} 分钟", flush=True)

    print(f"\n行字典已全部落盘（{len(line_txt)} 条）", flush=True)
    print("收尾…", flush=True)
    # 不建 idx_chart_meta：接口只按主键 k 查询，(y,h,g,ms) 索引用不上，
    # 而在 660 MB 库上建它会长时间占用临时空间（曾实测卡死），直接跳过。
    con.commit()
    con.close()
    os.replace(tmp, out)

    size = os.path.getsize(out) / 1024**2
    print(f"\n完成: {out}")
    print(f"  命盘 {total_rows:,} 张 | 唯一文本行 {len(line_txt):,} | 压缩块 {bid:,}")
    print(f"  数据库体积 {size:.1f} MB")
    print(f"  抽样校验 {verified} 盘通过")
    print(f"  总耗时 {(time.time()-t_start)/60:.1f} 分钟")

    with open("meta.json", "w", encoding="utf-8") as f:
        json.dump({"rows": total_rows, "lines": len(line_txt), "blocks": bid,
                   "dims": DIMS, "block_size": BLOCK, "db_bytes": os.path.getsize(out),
                   "years": [int(os.path.basename(p)[5:9]) for p in files]},
                  f, ensure_ascii=False, indent=2)

if __name__ == "__main__":
    args = sys.argv[1:]
    files = sorted(glob.glob("raw/year-*.jsonl.zst"))
    if args and args[0] == "--only":
        files = [f for f in files if args[1] in f]
    print(f"待处理 {len(files)} 个年份文件\n")
    build(files)

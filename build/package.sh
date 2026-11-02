#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# 打交付包：源码 + 解读数据库 + 部署脚本
# 用法：bash package.sh
# ─────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

NAME="ziwei-selfhost-1.0.0"
DIST="dist"
OUT="dist/${NAME}"

[ -f interp.db ] || { echo "缺少 interp.db，请先跑 build_db.py" >&2; exit 1; }
[ -s interp.db ] || { echo "interp.db 是空文件，构建未完成" >&2; exit 1; }
DBMB=$(( $(stat -c%s interp.db) / 1024 / 1024 ))
echo "解读数据库 ${DBMB} MB"

mkdir -p "$OUT/data" "$OUT/app"
echo "复制源码（排除 node_modules / .next / .git）…"
tar -C ../app -cf - \
    --exclude=node_modules --exclude=.next --exclude=.git \
    --exclude='*.log' --exclude=dist . | tar -C "$OUT/app" -xf -

echo "复制数据库…"
cp interp.db "$OUT/data/interp.db"
echo "生成数据库校验值…"
( cd "$OUT/data" && sha256sum interp.db > interp.db.sha256 )
cat "$OUT/data/interp.db.sha256"

echo "复制部署文件…"
# 仓库根目录即为部署目录（平铺布局），打包时直接取根目录的脚本，
# 保证「git 仓库」与「交付包」是同一套目录结构，不会出现两套布局漂移。
cp ../docker-compose.yml ../.env.example ../DEPLOY.md "$OUT/"
cp ../deploy.sh ../start.sh ../stop.sh \
   ../restart.sh ../status.sh ../check-ai.sh ../sync.sh "$OUT/"

cat > "$OUT/README.md" <<'EOF'
# 紫微斗数自建站

开箱即用的自托管紫微斗数排盘站：排盘与十三维解读全部本地完成，不消耗大模型 token，
仅「AI 追问」调用外部模型。

## 快速开始

```bash
tar xzf ziwei-selfhost-1.0.0.tar.gz
cd ziwei-selfhost-1.0.0
cp .env.example .env
vi .env            # 填 PACKYCODE_API_KEY，按需改 HOST_PORT
sudo ./deploy.sh
```

部署完会直接打印访问地址 `http://<服务器IP>:28763`。

填好 Key 之后，用一条命令确认大模型真的通：

```bash
./check-ai.sh
```

它会实际发一次请求，并按 401 / 403 / 404 / 429 / 超时分别告诉你问题在哪。

完整说明见 **DEPLOY.md**。

## 目录

| 路径 | 说明 |
|---|---|
| `app/` | 应用源码与 Dockerfile |
| `data/interp.db` | 解读数据库（674,976 张命盘 × 13 维） |
| `data/interp.db.sha256` | 数据库校验值，`deploy.sh` 会自动核对 |
| `deploy.sh` | 一键部署 |
| `check-ai.sh` | 大模型连通性自检 |
| `start.sh` / `stop.sh` / `restart.sh` / `status.sh` | 日常运维 |
| `docker-compose.yml` | 容器编排 |

## 数据来源

解读数据来自开源项目 [Renhuai123/ziwei-doushu](https://github.com/Renhuai123/ziwei-doushu)
的 v4.0 数据集（674,976 张命盘 × 13 维），作者 王多鱼AI，采用 CC BY 4.0 授权。
排盘引擎代码采用 MIT 授权。请保留页面上的来源标注。

命理内容仅供参考，不构成医疗、投资、法律或心理咨询建议。
EOF

echo "创建压缩包（约 1–2 分钟）…"

# 防线：在 Windows 上编辑过的文本文件会是 CRLF。CRLF 的 shebang 会让 Linux 上的
# ./deploy.sh 直接报 "no such file or directory"；CRLF 的 Dockerfile 会让 FROM 失效；
# CRLF 的 .env 会让端口值带上 \r。打包时统一转 LF，发生在 README 生成之后。
echo "统一换行符为 LF…"
for f in "$OUT"/*.sh "$OUT"/.env.example "$OUT"/docker-compose.yml \
         "$OUT"/DEPLOY.md "$OUT"/README.md "$OUT"/app/Dockerfile \
         "$OUT"/app/.dockerignore; do
    [ -f "$f" ] && sed -i 's/\r$//' "$f"
done
chmod +x "$OUT"/*.sh

# 自检：仍是 CRLF 就直接失败，不要带着坏包出门
BAD=0
for f in "$OUT"/*.sh "$OUT"/.env.example "$OUT"/docker-compose.yml "$OUT"/app/Dockerfile; do
    [ -f "$f" ] || continue
    if [ "$(cat "$f")" != "$(tr -d '\r' < "$f")" ]; then
        echo "  ✗ 仍含 CRLF：$f" >&2; BAD=1
    fi
done
[ "$BAD" = "0" ] && echo "  ✓ 换行符全部为 LF"
[ "$BAD" = "0" ] || { echo "打包中止：换行符未修正" >&2; exit 1; }

tar -C "$DIST" -czf "${DIST}/${NAME}.tar.gz" "$NAME"

SIZE=$(du -h "${DIST}/${NAME}.tar.gz" | cut -f1)
SHA=$(sha256sum "${DIST}/${NAME}.tar.gz" | cut -d' ' -f1)
echo
echo "────────────────────────────"
echo "  产物：dist/${NAME}.tar.gz"
echo "  大小：${SIZE}"
echo "  SHA256：${SHA}"
echo "────────────────────────────"
echo "  目录结构："
find "$OUT" -maxdepth 2 -not -path '*/app/*' | sed "s|$OUT|  ${NAME}|" | sort

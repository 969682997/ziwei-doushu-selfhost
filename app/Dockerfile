# 紫微斗数自建站 —— 生产镜像
# 目标环境：Ubuntu 22.04 / 24.04 x86_64，Docker + Docker Compose v2
#
# 国内构建加速：通过 build arg 传入镜像源（在 .env 里设置，compose 转发过来）
#   APT_MIRROR    例：mirrors.aliyun.com               替换 Debian 源，加速 apt-get
#   NPM_REGISTRY  例：https://registry.npmmirror.com   加速 npm ci
# 不设置则使用官方源（海外服务器保持默认即可）。

FROM node:22-bookworm-slim AS base
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1

ARG APT_MIRROR=
# 替换 Debian 源。bookworm 镜像可能用传统 /etc/apt/sources.list，也可能用 deb822
# 格式的 debian.sources，两种都处理。只换主机名即可——原路径里已带 /debian 与
# /debian-security，所以 deb.debian.org 与 security.debian.org 都指向同一台国内镜像。
RUN set -eux; \
    if [ -n "$APT_MIRROR" ]; then \
      for f in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources; do \
        if [ -f "$f" ]; then \
          sed -i "s|deb.debian.org|${APT_MIRROR}|g; s|security.debian.org|${APT_MIRROR}|g" "$f"; \
        fi; \
      done; \
      echo "APT 源已切换为 ${APT_MIRROR}"; \
    fi

# ── 依赖（含编译工具，better-sqlite3 若无预编译包则本地编译）──
FROM base AS deps
ARG NPM_REGISTRY=
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 make g++ ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json ./
# npm ci 是首选：严格按 lockfile 安装，结果可复现。
# 但本项目的 lockfile 存在一处 peer 依赖解析不一致（picomatch 2.3.2 / 4.0.7），
# npm ci 会报 EUSAGE 拒绝安装；而重新生成 lockfile 会把 next 16.3.8→16.4.3、
# iztro 2.6.1→2.6.3 一并升级——iztro 是排盘引擎，改动它会让排出的盘与解读库不一致，
# 不能草率升级。所以这里降级为 npm install：它同样以 lockfile 锁定版本，
# 只修复内部嵌套，实测 iztro / next / react 版本均保持不变。
RUN npm ci --no-audit --no-fund ${NPM_REGISTRY:+--registry=$NPM_REGISTRY} \
    || npm install --no-audit --no-fund ${NPM_REGISTRY:+--registry=$NPM_REGISTRY}

# ── 构建 ──
FROM base AS builder
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

# ── 仅生产依赖 ──
# 这一步的 apt 会再跑一次：proddeps 是独立阶段，复用不了 deps 的层缓存。
# 编译工具不能省——better-sqlite3 的预编译包拉取失败时要回退本地编译。
FROM base AS proddeps
ARG NPM_REGISTRY=
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 make g++ ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json ./
# 同 deps 阶段：npm ci 优先，lockfile 不一致时降级 npm install。
RUN set -eux; \
    npm ci --omit=dev --no-audit --no-fund ${NPM_REGISTRY:+--registry=$NPM_REGISTRY} \
      || npm install --omit=dev --no-audit --no-fund ${NPM_REGISTRY:+--registry=$NPM_REGISTRY}; \
    npm cache clean --force

# ── 运行 ──
FROM base AS runner
ENV NODE_ENV=production \
    PORT=3000 \
    HOSTNAME=0.0.0.0 \
    INTERP_DB=/data/interp.db

COPY --from=proddeps /app/node_modules ./node_modules
COPY --from=builder /app/.next ./.next
COPY package.json next.config.js ./
RUN mkdir -p /data

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "node_modules/next/dist/bin/next", "start", "-p", "3000", "-H", "0.0.0.0"]

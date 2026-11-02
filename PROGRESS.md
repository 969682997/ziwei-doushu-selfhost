# 紫微斗数自建站 · 交付记录

> 最后更新：2026-11-02 09:57
> 状态：**交付物已生成并通过端到端验证（端口 28763 + 提示词模块 + 部署健壮性加固）**

---

## 一、交付物

**`ziwei-selfhost-1.0.0.tar.gz`**（434 MB）

```
SHA256  9a81fcc7271e56de0aeca19883b963e8503f7dff9f25c7530c8de3370dec58bd
```

默认对外端口 **28763**（容器内仍为 3000，不暴露）。

这一版在上一版基础上补了部署健壮性，三处都是会导致「装不上」的硬伤：

1. **部署脚本是 Windows CRLF** —— `deploy.sh` / `start.sh` / `status.sh` /
   `docker-compose.yml` / `.env.example` 均为 CRLF。Linux 上 `./deploy.sh` 会因
   shebang 带 `\r` 报 `no such file or directory`。已全部转 LF，并在 `package.sh`
   里加了打包时强制转 LF + 自检，仍含 CRLF 则中止打包。
2. **数据库无完整性校验** —— 662 MB 文件上传/解压后可能损坏，而坏库的表现只是
   「查不到盘」，很难发现。现生成 `data/interp.db.sha256`，`deploy.sh` 默认校验。
3. **`.env` 编辑后带 CRLF** —— `HOST_PORT=28763\r` 会让 compose 端口解析失败。
   `deploy.sh` 与 `check-ai.sh` 会自动检测并修正。

另新增 `check-ai.sh`：实际发一次请求验证 base_url / key / model 三者是否匹配，
并按 401 / 403 / 404 / 429 / 超时分别给出原因与排查步骤。

解包后结构：

```
ziwei-selfhost-1.0.0/
├── README.md               快速上手
├── DEPLOY.md               完整部署文档
├── docker-compose.yml      容器编排
├── .env.example            配置模板
├── deploy.sh               一键部署（含数据库校验）
├── check-ai.sh             大模型连通性自检
├── start.sh / stop.sh / restart.sh / status.sh
├── data/interp.db          解读数据库（662 MB）
├── data/interp.db.sha256   数据库校验值
└── app/                    源码 + Dockerfile（131 个文件，无 node_modules）
```

部署三步：

```bash
tar xzf ziwei-selfhost-1.0.0.tar.gz && cd ziwei-selfhost-1.0.0
cp .env.example .env && vi .env      # 填 PACKYCODE_API_KEY
sudo ./deploy.sh
```

填好 Key 后跑 `./check-ai.sh` 验证大模型是否真的通。

---

## 二、核心指标（均实测）

| 项 | 数值 |
|---|---|
| 命盘覆盖 | 674,976 张（公历 1950–2026 × 12 时辰 × 男女） |
| 解读维度 | 13 维，每盘约 2.8 万字 |
| 唯一文本行 | 996,322 条 |
| 数据库体积 | 662 MB（原始 53 GB，压缩比 80x） |
| 单次查询 | **平均 1.83 ms**（300 次随机抽样） |
| 空维 | 0 |
| 交付包 | 434 MB |
| 服务器稳态占用 | 数据库 662 MB + 镜像约 1.2 GB ≈ 2 GB |

---

## 三、存储方案（为什么能做到 662 MB）

原始数据解压 53 GB。测试发现正文是模板 + 断语组合生成的，**全年 1,019 万条文本行
只有 29,397 条唯一**（字面量仅占 0.6%）。所以不存全文，改存：

- `lines` —— 全局唯一文本行字典（996,322 条）
- `blk` —— 64 张盘的「行号序列」打包，gzip-9 压缩（10,568 个块）
- `chart` —— 每盘 → (块号, 块内偏移, 长度) + 出生元数据

查询 = 主键索引 → 块读取 → gunzip → 一次 IN 批量取文本 → 拼接。

对比过但未采用的方案：zstd + 2 MB 字典可达 0.95 GB，但 Node 的 zstd 需 ≥22.15 且
不支持字典；gzip 全版本内置，Docker 里零版本风险。

---

## 四、代码改动清单

| 文件 | 说明 |
|---|---|
| `app/lib/server/interp-db.ts` | 查询层，含块 LRU(48) 与结果 LRU(600) |
| `app/lib/server/prompt.ts` | 读盘提示词（解读顺序 / 引用规则 / 禁止项 / 输出格式），改风格只动这里 |
| `app/app/api/reading/route.ts` | `GET /api/reading?y=&m=&d=&h=&g=&dim=` 纯本地查表 |
| `app/app/api/interpret/route.ts` | `POST /api/interpret` OpenAI 兼容 + SSE 流式，对接 PackyCode |
| `app/app/api/health/route.ts` | 健康检查 |
| `app/components/ReadingPanel.tsx` | 13 维标签页 + 流式 AI 追问（替代原 6 维 InsightPanel） |
| `app/app/chart/page.tsx` | 改用 ReadingPanel |
| `app/next.config.js` | `serverExternalPackages: ['better-sqlite3']` |
| `app/package.json` | 加 `better-sqlite3`，锁文件已更新 |
| `build/build_db.py` | 数据编译脚本 |
| `build/package.sh` | 打包脚本 |

验证情况：`tsc --noEmit` 通过、`npm run build` 通过、
`/api/health`、`/api/reading`、`/api/interpret`（未配 Key 时 503）、`/chart` 页面均正常，
并用**解包出来的数据库**完整跑了一遍端到端。

---

## 五、已知问题与取舍

1. **流派口径差异（未处理）**：v4.0 数据集按旧的「现代修正 v2」亮度生成，引擎
   2026-10-20 后默认改成《斗数全书》。当前保持引擎默认未动——因为回归测试是按全书
   口径校验的，改了会破坏测试。实际影响是「星曜亮度字 + 少量随亮度变化的断句」可能
   与盘面显示不完全一致。要消除的话，在 `lib/ziwei/school-config.ts` 的
   `SCHOOL_DEFAULT_CONFIG.brightnessSchool` 改成 v2 对应值，但需重跑并调整回归测试。

2. **AI 追问未实测**：接口代码完整、降级行为正确，但没有真实 Key 跑通过一次流式响应。
   部署后先跑 `./check-ai.sh`（会实际发请求并按状态码报错），再到页面问一句验证流式。

3. **`npm test` 在本地跑不过**：tarball 解压没有 `.git`，
   `scripts/regression/neutral-naming.test.ts` 调了 git 命令。与功能无关。

4. **构建脚本卡死已修**：原收尾会建 `idx_chart_meta` 索引，在 662 MB 库上会长时间
   卡住且该索引实际用不上（接口只按主键查）。已从 `build_db.py` 移除。

5. **Docker 镜像未在真实环境验证**：本机没有 Docker，Dockerfile 与 compose 是按
   Ubuntu 22.04/24.04 + node:22-bookworm-slim 写的，首次部署时留意构建日志。

---

## 六、产物清单

| 路径 | 说明 |
|---|---|
| `ziwei-selfhost-1.0.0.tar.gz` | **交付包** |
| `build/interp.db` | 编译好的数据库源文件 |
| `build/meta.json` | 构建元信息 |
| `build/build_db.py` | 数据编译脚本（可重跑，约 30 分钟） |
| `build/package.sh` | 打包脚本（含 CRLF 自检） |
| `build/raw/` | 77 个原始年份文件（155 MB，不用可删） |
| 根目录 | 部署脚本与 compose（**仓库根目录即部署目录**，与交付包布局一致） |
| `app/` | 开发目录（含 node_modules，可删） |

---

## 七、剩余工作

### 必须等你在服务器上做的（本地无法代做）

| 项 | 为什么没法本地做 | 怎么做 |
|---|---|---|
| **首次镜像构建** | 开发机是 Windows，无 Docker | `sudo ./deploy.sh`，看构建日志。最可能出问题的是 `npm ci` 拉 `better-sqlite3` 预编译包失败，Dockerfile 已装 python3/make/g++ 可回退本地编译 |
| **AI 真实流式** | 缺 Key | 填 `.env` → `./check-ai.sh` → 页面问一句 |
| **安全组放行 28763** | 云平台侧 | 控制台 → 安全组 → 入方向 TCP 28763 |
| **确认 base_url 与模型名** | 需你的账号信息 | `.env` 里 `PACKYCODE_BASE_URL` / `PACKYCODE_MODEL`。`check-ai.sh` 的 404 分支会指出是路径还是模型名的问题 |

### 你明确暂缓的

- 域名 + HTTPS（当前 IP:28763 明文访问）
- 登录/鉴权（当前完全公开，仅靠 IP 限流 30 次/小时挡刷）
- ICP 备案（国内服务器对外提供服务前需要）

### 可选优化（不影响使用）

1. **镜像瘦身**：`next.config.js` 加 `output: 'standalone'` 可把 1.2 GB 镜像降到约 300 MB。
   当前刻意没开——standalone 的输出追踪有时会漏掉 `better-sqlite3` 的 `.node` 二进制，
   本机无 Docker 无法验证，宁可大一点也要能跑。
2. **流派对齐**：见上面「已知问题 1」，需要重跑数据编译并改回归测试。
3. **13 维解读的翻页预取**：现在切维度是按需请求（单次 2 ms 左右，体感已无延迟），
   首屏一次拉满 13 维约 120 KB，可视情况改成预取。

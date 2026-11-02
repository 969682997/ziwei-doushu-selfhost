# 紫微斗数自建站

自托管的紫微斗数排盘站。**排盘与十三维解读全部在本地完成，不消耗大模型 token**，
只有「就这一条问 AI」才会调用外部模型。

- 排盘：由 [iztro](https://github.com/SylarLong/iztro) + lunar-javascript 在浏览器端完成
- 十三维解读：674,976 张命盘的解读文本编译进一个 662 MB 的 SQLite，查询约 2 ms
- AI 追问：OpenAI 兼容协议 + SSE 流式，可接任意第三方网关
- 部署：单机 Docker Compose，一条命令起来

---

## ⚠️ 先说清楚：数据集不在这个仓库里

解读数据库 `data/interp.db` 有 **662 MB**，超过 GitHub 单文件 100 MB 的上限，
因此不纳入版本控制。README 里的 `.sha256` 记录的是当前代码期望的数据集版本。

拿到数据库有三条路：

**A. 你手上有安装包**（推荐，最省事）

```bash
tar xzf ziwei-selfhost-1.0.0.tar.gz
cp ziwei-selfhost-1.0.0/data/interp.db data/
cp ziwei-selfhost-1.0.0/data/interp.db.sha256 data/
```

**B. 从 Release 下载**（若已上传为 Release 资产）

```bash
curl -L -o data/interp.db "<Release 里的直链>"
cd data && sha256sum -c interp.db.sha256
```

**C. 自己从原始数据编译**（约 155 MB 下载 + 30 分钟）

```bash
bash build/download.sh      # 拉 77 个年份文件到 build/raw/
python3 build/build_db.py   # 编译出 build/interp.db
cp build/interp.db data/
( cd data && sha256sum interp.db > interp.db.sha256 )
```

编译依赖 Python 3.8+ 与 `zstandard`：`pip install zstandard`。

原始数据来自 [Renhuai123/ziwei-doushu](https://github.com/Renhuai123/ziwei-doushu)
的 v4.0 数据集，CC BY 4.0 授权。

---

## 部署

需要 Docker 20.10+ 与 Docker Compose v2，Ubuntu 22.04 / 24.04 x86_64 验证过。

```bash
git clone <仓库地址> ziwei && cd ziwei
mkdir -p data && cp /path/to/interp.db data/     # 见上节，只做一次
cp .env.example .env && vi .env                  # 填 PACKYCODE_API_KEY
sudo ./deploy.sh
```

脚本跑完打印访问地址，形如 `http://192.168.1.10:28763`（默认端口 28763）。
**国内云服务器记得在安全组放行该端口。**

填好 Key 后验证大模型是否真的通：

```bash
./check-ai.sh
```

它会实际发一次请求，并按 401 / 403 / 404 / 429 / 超时分别指出问题在哪。

后续同步代码：

```bash
git pull && sudo ./deploy.sh
```

`deploy.sh` 幂等，重复执行只会重建镜像并滚动重启。数据库不会被改动。

完整说明、配置项含义、排障见 **[DEPLOY.md](./DEPLOY.md)**。

---

## 目录结构

```
.
├── app/                  Next.js 应用（排盘引擎 + 前端 + API）
├── build/
│   ├── download.sh       下载 v4.0 原始数据集
│   ├── build_db.py       编译解读数据库（行级去重 + 分块压缩）
│   └── package.sh        打交付包
├── data/                 运行时挂载的解读库（.db 不进 git）
├── deploy.sh             一键部署
├── check-ai.sh           大模型连通性自检
├── start.sh / stop.sh / restart.sh / status.sh
├── docker-compose.yml
├── .env.example
├── DEPLOY.md             部署文档
└── PROGRESS.md           设计与实现记录（含取舍与已知问题）
```

**仓库根目录就是部署目录**，也是交付包解压后的目录——两者结构完全一致，
不会出现「按文档找不到文件」的情况。

---

## 关于成本的架构选择

命理类应用最容易失控的是调用模型的开销。这里的取舍是：

| 能力 | 实现 | 成本 |
|---|---|---|
| 排盘 | 浏览器端计算 | 0 |
| 十三维解读 | 本地 SQLite 查表 | 0 token |
| AI 追问 | 调外部模型 | 按量计费 |

十三维解读是模板化文本，用查表替代生成，既省 token 又比模型逐次生成稳定——
同一张盘每次打开看到的解读完全一致。代价是解读不能自由发散，
所以把「深问」这件事交给了 AI 追问，并加了 `AI_RATE_LIMIT`（默认每 IP 每小时 30 次）
防止公开站被刷爆额度。

---

## 授权

- **代码**：MIT，见 [LICENSE](./LICENSE)。排盘引擎来自
  [Renhuai123/ziwei-doushu](https://github.com/Renhuai123/ziwei-doushu)（MIT），
  本仓库在其之上增加了十三维解读库、AI 追问与部署方案。
- **数据集**：CC BY 4.0，作者 王多鱼AI。可商用，
  **但必须保留署名**——页面页脚已标注来源，请勿删除。
- 页面上另有免责声明，同样请保留。

---

## 免责

命理内容仅供参考，不构成医疗、投资、法律或心理咨询建议。
AI 生成内容按《生成式人工智能服务管理暂行办法》需作显著标识，页面已注明。
面向公众提供服务时，请自行确认所在地对命理类内容的监管要求；
国内服务器对外提供网站服务需完成 ICP 备案。

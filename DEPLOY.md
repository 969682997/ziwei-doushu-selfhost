# 紫微斗数自建站 · 部署说明

一套可离线部署的紫微斗数排盘 + 十三维解读站点。基于开源项目
[Renhuai123/ziwei-doushu](https://github.com/Renhuai123/ziwei-doushu) 的排盘引擎，
配合本地编译的解读数据库，**排盘与解读全部在服务器本地完成，不消耗大模型 token**；
只有「就这一条问 AI」会调用外部模型。

---

## 一、这台机器需要什么

| 项 | 要求 |
|---|---|
| 系统 | Ubuntu 22.04 / 24.04 x86_64 |
| 配置 | 2 核 2 GB 内存起（推荐 2 核 4 GB） |
| 磁盘 | 峰值约 5 GB，稳态约 2 GB（10 GB 盘足够，详见下表） |
| 软件 | Docker 20.10+ 与 Docker Compose v2 |
| 网络 | 首次部署需能访问 npm registry 与 Docker Hub |

### 磁盘账（10 GB 盘的实际占用）

| 阶段 | 占用 |
|---|---|
| 安装包 tar.gz | 约 700 MB |
| 解压后的数据库 `data/interp.db` | 约 700 MB |
| 运行镜像 | 约 1.2 GB |
| 应用源码 | 约 3 MB |
| 构建期临时缓存 | 约 2–3 GB（`deploy.sh` 结束时自动清理） |
| **稳态合计** | **约 2 GB** |

`deploy.sh` 跑完会自动执行 `docker builder prune` 清掉构建缓存，并在结尾打印当前
磁盘占用。安装包确认部署成功后可以直接删除，再省 700 MB。

已安装 Docker 可跳过，否则一行装好：

```bash
curl -fsSL https://get.docker.com | sh
```

---

## 二、三步上线

```bash
# 1. 解压
tar xzf ziwei-selfhost-1.0.0.tar.gz
cd ziwei-selfhost-1.0.0

# 2. 填写大模型配置（唯一必改的地方）
cp .env.example .env
vi .env          # 填 PACKYCODE_API_KEY，按需改 HOST_PORT

# 3. 一键部署
sudo ./deploy.sh

# 4. 验证大模型是否真的通（可选，建议做）
./check-ai.sh
```

脚本跑完会直接打印访问地址，形如 `http://192.168.1.10:28763`。

**国内云服务器记得去安全组放行 `HOST_PORT`**（默认 28763），否则外网打不开。

> 不填 API Key 也能用：排盘、画盘、十三维解读全部正常，只有 AI 追问会提示未配置。

`deploy.sh` 会先校验 `data/interp.db` 的 SHA256。662 MB 的文件经上传、解压后有可能
损坏，而坏库的表现只是「查不到盘」，不容易发现。校验失败会直接停下并提示重新上传
（确认文件无误时可用 `SKIP_DB_VERIFY=1 sudo ./deploy.sh` 跳过）。

---

## 三、日常命令

| 命令 | 作用 |
|---|---|
| `./check-ai.sh` | 验证 base_url / key / model 三者是否真的能通，失败给出具体原因 |
| `./start.sh` | 启动（幂等，可反复执行） |
| `./stop.sh` | 停止（保留容器，快速恢复） |
| `./restart.sh` | 改完 `.env` 后重启生效 |
| `./status.sh` | 看状态、健康检查、内存占用、最近日志 |
| `docker compose logs -f` | 跟踪实时日志 |
| `docker compose down` | 彻底移除容器（数据不受影响） |

---

## 四、配置项

全部在 `.env` 里：

| 变量 | 说明 |
|---|---|
| `HOST_PORT` | 对外端口，默认 28763 |
| `PACKYCODE_BASE_URL` | OpenAI 兼容端点，默认 `https://www.packyapi.com/v1` |
| `PACKYCODE_API_KEY` | 令牌。**必须选支持第三方接入的分组** |
| `PACKYCODE_MODEL` | 模型名，默认 `claude-sonnet-4-5` |
| `AI_TIMEOUT_MS` | 单次 AI 请求超时，默认 90000 |
| `AI_RATE_LIMIT` | 每个 IP 每小时 AI 追问上限，默认 30；填 0 不限（不建议） |

### 关于分组，这一条最重要

PackyCode 的 **CC 分组、Codex 分组、Codex-sale 分组明确不支持第三方接入**，
网页端调用会触发环境审查，结果是**封号并进入退款流程**。

可用于本站的分组：`cc-sale`、`cc-expensive`、`claude-officially`、`aws-q`、
`azure-officially`、`deepseek-sale`、`glm-sale`、`kimi-sale` 等。

改完模型配置后先自检：

```bash
./check-ai.sh
```

它会真的发一次请求，并按状态码告诉你是哪一环坏了：401 是 Key 无效、403 是分组不允许
第三方接入、404 是路径或模型名写错、429 是额度用尽、超时则给出出网排查步骤。

只想确认容器读到了配置（不验证上游）：

```bash
curl -s http://127.0.0.1:28763/api/interpret
# 返回 {"ok":true,"model":"...","baseUrl":"..."} 表示已读到配置
```

---

## 五、接口

| 路由 | 方法 | 说明 |
|---|---|---|
| `/` | GET | 首页 |
| `/chart` | GET | 排盘页（排盘在浏览器本地完成） |
| `/api/reading` | GET | 取 13 维解读，**不调模型** |
| `/api/interpret` | POST | AI 追问，SSE 流式 |
| `/api/health` | GET | 健康检查（数据库与 AI 配置状态） |

取一条解读看效果：

```bash
curl -s "http://127.0.0.1:28763/api/reading?y=1990&m=1&d=1&h=0&g=male&dim=overview" \
  | head -c 800
```

参数：`y` 年 `m` 月 `d` 日（公历），`h` 时辰序号 `0–11`（子=0 … 亥=11），
`g` 取 `male` / `female`，`dim` 可选（不传则返回全部 13 维）。

---

## 六、数据说明

解读数据库由 v4.0 开源数据集编译而来：

- **覆盖**：公历 1950–2026 年每一个真实日期 × 12 时辰 × 男女 = 674,976 张命盘
- **维度**：命格总览、性格、感情、事业、财运、健康、兄弟、子女、迁移、人际、田宅、福德、父母
- **来源**：`https://github.com/Renhuai123/ziwei-doushu`，作者 王多鱼AI
- **许可**：CC BY 4.0，可商用，**保留来源标注即可**

体积优化说明：原始数据解压后 53 GB，正文高度模板化——全量 1,019 万条文本行里只有
约 3 万条在单年内不重复。因此不存全文，而是存「唯一文本行字典 + 每盘的行号序列」，
再把 64 张盘的行号序列打包成块压缩。最终约 700 MB，单次查询 2–4 ms。

---

## 七、排障

**起不来 / 502**

```bash
docker compose logs --tail=100
```

**`/api/health` 返回 ok:false**
数据库没挂上。检查 `data/interp.db` 是否存在、`docker-compose.yml` 里
`./data:/data:ro` 是否被改动。

**AI 追问报「上游返回 401/403」**
令牌或分组不对。先跑 `./check-ai.sh` 看具体状态码。确认用的是支持第三方接入的分组，
且 `PACKYCODE_API_KEY` 没有多余空格或引号。

**AI 追问报「上游返回 404」**
`PACKYCODE_BASE_URL` 不对。注意 `www.packyapi.ai` 是控制台网页地址，不能当接口地址；
尝试 `https://www.packyapi.com/v1` 或 `https://cf.api.fan/v1`。也可能是模型名写错——
去控制台核对 `PACKYCODE_MODEL`，注意版本号后缀。

**内存不够**
容器平时占用约 200–300 MB。若服务器只有 1 GB，建议在 `docker-compose.yml` 里
加 `deploy.resources.limits.memory: 700m` 并开 swap。

**换端口**
改 `.env` 的 `HOST_PORT`，然后 `./restart.sh`。

---

## 八、合规提醒

- 页面已保留数据集署名与免责声明，**请勿删除**。
- 命理内容仅供参考，不得作为医疗、投资、法律或心理咨询依据；面向公众提供服务时
  请自行确认所在地对宗教/命理类内容的监管要求，国内服务器需完成 ICP 备案。
- AI 生成内容按《生成式人工智能服务管理暂行办法》需作显著标识，页面已注明。
- **不要爬取 metisziwei.com 的任何内容**。其服务条款明确禁止抓取、禁止用于模型训练、
  禁止复制前后端代码自营同类服务，违约金 100 万/例，且输出文本嵌有指纹水印。
  本项目的数据来源是作者以 CC BY 4.0 明确授权开放的数据集，不要混用。

---

## 九、更新与卸载

本站**不写入任何用户数据**——解读库是只读挂载，排盘在浏览器端完成，服务端不留存
记录。所以没有需要备份的东西，升级时直接替换即可。

**改代码后更新**（在开发机上重新打包，上传后）:

```bash
tar xzf ziwei-selfhost-1.0.1.tar.gz
cd ziwei-selfhost-1.0.1
cp ../ziwei-selfhost-1.0.0/.env .          # 沿用旧配置
sudo ./deploy.sh
```

新旧目录不要同时跑（容器名都是 `ziwei`，端口也相同）。旧目录确认新版正常后可直接删。

**只改了 `.env`**：`./restart.sh`。

**彻底卸载**：

```bash
docker compose down
docker image rm ziwei-selfhost:1.0.0
cd .. && rm -rf ziwei-selfhost-1.0.0
```

数据库文件在 `data/` 里，删目录即一并删除。

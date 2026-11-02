#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# AI 追问连通性自检
# 验证 .env 里的 BASE_URL / API_KEY / MODEL 三者是否真的能通，
# 并且给出具体的失败原因（而不是让用户在网页上猜）。
#
# 用法：./check-ai.sh
# ─────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; DIM=$'\e[2m'; RST=$'\e[0m'
ok()   { printf '%s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s!%s %s\n' "$YEL" "$RST" "$*"; }
bad()  { printf '%s✗%s %s\n' "$RED" "$RST" "$*"; }

[ -f .env ] || { bad "缺少 .env，请先 cp .env.example .env"; exit 1; }
# Windows 换行的 .env 会让 KEY/MODEL 末尾带上 \r，导致 401 或 404
if [ "$(cat .env)" != "$(tr -d '\r' < .env)" ]; then
  sed -i 's/\r$//' .env
  warn ".env 是 Windows 换行（CRLF），已自动转为 Unix 换行"
fi
set -a; . ./.env; set +a

BASE="${PACKYCODE_BASE_URL:-}"
KEY="${PACKYCODE_API_KEY:-}"
MODEL="${PACKYCODE_MODEL:-}"
TIMEOUT_S=$(( ${AI_TIMEOUT_MS:-90000} / 1000 ))
[ "$TIMEOUT_S" -lt 10 ] && TIMEOUT_S=10

echo ""
echo "AI 追问连通性自检"
echo "─────────────────────────────────────────────"

# ── 1. 配置项是否齐全 ──
MISSING=0
if [ -z "$BASE" ]; then bad "PACKYCODE_BASE_URL 未填"; MISSING=1; fi
if [ -z "$KEY" ]; then  bad "PACKYCODE_API_KEY 未填";  MISSING=1; fi
if [ -z "$MODEL" ]; then bad "PACKYCODE_MODEL 未填";    MISSING=1; fi
[ "$MISSING" = "1" ] && { echo ""; echo "填好 .env 后重新执行本脚本。"; exit 1; }

# base 去掉尾部斜杠，避免拼出 //chat/completions
BASE="${BASE%/}"
ok "配置齐全"

MASKED="$(printf '%s' "$KEY" | cut -c1-6)…$(printf '%s' "$KEY" | tail -c 5)"
printf '    %-22s %s\n' "base_url" "$BASE"
printf '    %-22s %s\n' "api_key" "$MASKED"
printf '    %-22s %s\n' "model" "$MODEL"
printf '    %-22s %ss\n' "timeout" "$TIMEOUT_S"

# ── 2. 真的发一次非流式请求 ──
echo ""
echo "发送测试请求（非流式，约 10–30 秒）…"

BODY="$(mktemp)"
ERRF="$(mktemp)"
trap 'rm -f "$BODY" "$ERRF"' EXIT

CODE="$(curl -sS -o "$BODY" -w '%{http_code}' \
  --max-time "$TIMEOUT_S" \
  -H "Authorization: Bearer ${KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"max_tokens\":64,\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"只回复两个字：收到\"}]}" \
  "${BASE}/chat/completions" 2>"$ERRF")"

# curl 自己的报错往往比 HTTP 码更有信息量（证书、连接被拒、DNS）
CURLERR="$(tr -d '\r' < "$ERRF" | sed 's/^curl: //' | head -3)"

case "$CODE" in
  200)
    if command -v python3 >/dev/null 2>&1; then
      PARSED="$(python3 - "$BODY" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception as e:
    print("PARSE_FAIL\t"+str(e)); sys.exit()
if "error" in d:
    print("API_ERR\t"+str(d["error"])[:300]); sys.exit()
ch=(d.get("choices") or [{}])[0]
msg=(ch.get("message") or {}).get("content","")
usage=d.get("usage") or {}
print("OK\t%s\t%s\t%s" % (str(msg).strip().replace("\n"," ")[:60],
                          usage.get("prompt_tokens","?"), usage.get("completion_tokens","?")))
PY
)"
    else
      PARSED="OK	$(head -c 200 "$BODY" | tr -d '\n')	?	?"
    fi

    case "$PARSED" in
      OK*)
        REPLY="$(printf '%s' "$PARSED" | cut -f2)"
        PIN="$(printf '%s' "$PARSED" | cut -f3)"
        POUT="$(printf '%s' "$PARSED" | cut -f4)"
        echo ""
        ok "连通成功"
        printf '    %-22s %s\n' "模型回复" "${REPLY:-（空）}"
        printf '    %-22s in %s / out %s tokens\n' "用量" "$PIN" "$POUT"
        echo ""
        echo "${DIM}下一步：打开站点 → 排一张盘 → 在「AI 追问」里问一句，确认浏览器端流式正常。${RST}"
        ;;
      API_ERR*)
        echo ""
        bad "接口返回错误：$(printf '%s' "$PARSED" | cut -f2)"
        ;;
      *)
        echo ""
        warn "HTTP 200 但响应无法解析，原始内容前 300 字节："
        head -c 300 "$BODY"; echo
        ;;
    esac
    ;;
  401)
    echo ""
    bad "401 未授权 —— API Key 无效、已过期，或不属于这个 base_url 对应的平台。"
    echo "    ${DIM}先确认 KEY 是从 ${BASE} 对应控制台复制的。${RST}"
    ;;
  403)
    echo ""
    bad "403 禁止访问 —— 最常见的原因是「分组不支持第三方接入」。"
    echo "    ${DIM}CC 分组、Codex 分组会触发环境审查，不要用。${RST}"
    echo "    ${DIM}改用 cc-sale / deepseek-sale / claude-officially / aws-q 等分组。${RST}"
    echo "    ${DIM}若返回内容是一段 HTML，基本可以确认是被网关拦了。${RST}"
    head -c 200 "$BODY"; echo
    ;;
  404)
    echo ""
    bad "404 路径或模型不存在。"
    echo "    ${DIM}base_url 应以 /v1 结尾，实际请求的是：${BASE}/chat/completions${RST}"
    echo "    ${DIM}也可能是 PACKYCODE_MODEL 写错，去控制台核对模型名（注意版本号后缀）。${RST}"
    head -c 200 "$BODY"; echo
    ;;
  429)
    echo ""
    bad "429 频率或额度受限 —— 该 Key 的额度用尽，或短时间请求过多。"
    ;;
  000)
    echo ""
    bad "请求超时或无法连接（${TIMEOUT_S}s）。"
    [ -n "$CURLERR" ] && echo "    ${DIM}curl: ${CURLERR}${RST}"
    echo "    ${DIM}1) 服务器出网是否正常：curl -I https://www.baidu.com${RST}"
    echo "    ${DIM}2) base_url 域名是否可解析：getent hosts $(printf '%s' "$BASE" | sed 's|https\?://||; s|/.*||')${RST}"
    echo "    ${DIM}3) 是否被云厂商出网限制或需要代理${RST}"
    echo "    ${DIM}4) 若 curl 报 SSL/证书错误，检查服务器时间是否准确（date -u）${RST}"
    ;;
  *)
    echo ""
    bad "HTTP ${CODE}"
    [ -n "$CURLERR" ] && echo "    ${DIM}curl: ${CURLERR}${RST}"
    head -c 300 "$BODY"; echo
    ;;
esac

echo ""
echo "─────────────────────────────────────────────"

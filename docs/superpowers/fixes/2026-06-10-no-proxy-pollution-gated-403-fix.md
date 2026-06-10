# 代理与 gated 分类:no_proxy 被污染致 fetch 断网 + 403 gated 误判 gated_ok

## 元信息

- **Fix ID**: `2026-06-10-no-proxy-pollution-gated-403-fix`
- **创建日期**: 2026-06-10
- **级别**: P0(断网)+ P1(gated 误判)
- **状态**: 已闭环
- **负责人 / session**: Claude session @ 2026-06-10

---

## 人话版

**一句话**：配置文件叫快递员"送 HF 的件不要走代理通道",但本楼只有代理通道能出门。

**打比方**：公司大门只有一个有门禁的通道(代理)。有人在通讯录里写了"去 huggingface 的人走侧门"——但侧门是堵死的墙(本机无直连外网)。于是所有去 HF 拉权重的请求都撞墙:`Network is unreachable`。

**现在怎样**：fetch-weights 一启动就断网失败;且就算修了配置,SKILL.md 里还留着一条过时规则教 agent 在运行时"重新把 huggingface.co 加进 no_proxy / unset 代理",会把修复现场再破坏一次。另外 gated 仓库返回 403 "requires approval" 时,preflight 只认 "401/Unauthorized",把 Eagle2.5-8B 误判为 `gated_ok: true` 放进了流水线。

**要做什么**：① `.env` 的 `no_proxy` 去掉外网域名;② 删掉 SKILL.md 里教 agent 绕代理的过时规则;③ preflight/fetch 把 403/"Access denied"/"requires approval" 也归类为 gated 阻断,转 pending_human。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | eagle(NVlabs/Eagle → nvidia/Eagle2.5-8B) |
| **触发 run_id** | `cron-2026-06-10-111701` |
| **触发时间** | 2026-06-10 11:17(+08:00) |
| **触发阶段** | fetch-weights |
| **workspace 路径** | `workspace/eagle/` |
| **runs 路径** | `runs/cron-2026-06-10-111701/` |

---

## 现象

- 现象 1: fetch-weights 启动即失败 `Error: Local entry not found. [Errno 101] Network is unreachable`
  - 证据: `workspace/eagle/logs/fetch_weights.log` 末尾
- 现象 2: 修好网络后,同 repo 下载报 `Error: Access denied. This repository requires approval.`(403,HF 账号未接受 NVIDIA license),但 `workspace/eagle/results/intake.json` 里 `preflight.gated_ok: true`
- 现象 3: 一次性 crontab 条目 `40 11 10 6 *` 从未触发(`logs/cron.log` 无新输出、无 run 目录)——在 11:40 当分钟才写入 crontab,cron 按分钟扫描已错过

---

## 触发条件 / 复现步骤

1. 本机无直连外网(`env -i curl -sI https://huggingface.co` → exit 非 0 / http_code 000),仅代理 `http://172.16.6.179:61080/` 可出网(同 curl 带 `https_proxy` → 200)
2. `.env` 中 `no_proxy=...,huggingface.co,...` → huggingface_hub 的 requests 对 HF 域名绕开代理直连
3. 任意 `hf download` → `[Errno 101] Network is unreachable`
4. gated 复现: `hf download nvidia/Eagle2.5-8B config.json --token $HF_TOKEN` → `Access denied. This repository requires approval.`(非 401,preflight 旧规则不识别)

---

## 影响

- **影响范围**: 可靠性 — fetch-weights 阶段 100% 失败,整条 10:00 cron 链路无法过 fetch;gated 误判浪费一整个 run 名额(MVP N=1 即当日全部产能)
- **影响下游**: auto-daily → fetch-agent → 所有依赖权重的后续阶段;intake preflight 的 `gated_ok` 字段不可信
- **严重程度**: P0 — 用户要求 2026-06-11 cron 必须端到端跑通,此问题是唯一硬阻断

---

## 根因

- **是否已确认**: ✅
- **简述**: 三层同源:
  > ① `fetch-weights/SKILL.md` 历史规则 8("代理绕过":把 `huggingface.co` 加入 `no_proxy` 以避免代理 503)是在错误假设"本机可直连"下写的,与后来的 `2026-06-08-proxy-hf-download-503-fix`(结论:不能 unset proxy/no_proxy,只能禁 Xet+降并发)直接矛盾,但旧条目没删,文件里同时存在两条编号都是 8 的矛盾规则;
  > ② 用户 2026-06-10 给 `.env` 加代理时照着旧规则把 `huggingface.co` 写进了 `no_proxy`;
  > ③ preflight-gpu-disk 的 gated 试探只匹配 "401/Unauthorized",HF 对 "已 gated 但账号未获批" 返回 403 "Access denied...requires approval",未被分类 → intake 在断网环境下试探 inconclusive,落了 `gated_ok: true`。

---

## 修复方案

### 设计层修改

- [x] `fetch-weights/SKILL.md`:删除过时规则 8(教 agent 把 huggingface.co 加 no_proxy / unset 代理);加 gated 403 即停规则 + 反模式;ChangeLog
- [x] `preflight-gpu-disk/SKILL.md`:gated 试探分类扩展 — 403/"Access denied"/"requires approval" → `gated_needs_approval`(blocked);网络不可达时不许给 `gated_ok: true`(inconclusive → blocked network_error);ChangeLog

### 实现层修改

- [x] `.env`:`no_proxy` 去掉 `huggingface.co,hacker-news.firebaseio.com`,补 `NO_PROXY` 大写副本,加注释说明"外网域名禁入 no_proxy"
- [x] crontab:删除已过期的一次性条目 `40 11 10 6 *`

### 文档层修改

- [x] 本 fix + fixes/README.md 索引 + master plan 索引

---

## 验证步骤

1. `env -i PATH=<crontab PATH> HOME=/root bash -c 'cd /root/ai-auto-harness && set -a && source .env && set +a && HF_HUB_DISABLE_XET=1 HF_HOME=/tmp/hf_proxy_test hf download openai-community/gpt2 config.json --local-dir /tmp/hf_proxy_test/dl'`
2. 期望输出:`✓ Downloaded`(实测 ✅ 2026-06-10 14:20)
3. 同环境 `git ls-remote https://github.com/NVlabs/Eagle HEAD`
4. 期望输出:commit hash(实测 ✅)
5. gated 验证:同环境 `hf download nvidia/Eagle2.5-8B config.json` → 期望 `Access denied. This repository requires approval.`(403 而非断网,实测 ✅)
6. e2e:手动按 cron 等价环境跑 `cron/daily.sh`,期望 eagle 被 fetch-agent 识别 gated → `paused_for_human` + `pending_human/eagle.md`,报告生成

---

## 修复结果

- **状态**: ✅ 成功
- **验证证据**: 上节 1-5 实测通过;e2e 见 runs/ 当日 manual run
- **commit hash**: 待 commit 后回填
- **commit message**: `ai-auto: P0 fix — no_proxy 污染致 HF 断网 + gated 403 分类 + 过时绕代理规则删除`

---

## 证据指针

- workspace: `workspace/eagle/`
- runs: `runs/cron-2026-06-10-111701/`
- 日志:`workspace/eagle/logs/fetch_weights.log`
- 相关 SKILL:`.claude/skills/fetch-weights/SKILL.md`、`.claude/skills/preflight-gpu-disk/SKILL.md`
- 相关 R 规则:`.claude/CLAUDE.md` R7(HF 下载姿势)
- 网络事实:`env -i curl https://huggingface.co` → 000(无直连);经 `172.16.6.179:61080` → 200

---

## 关联

- **关联 fix**:`2026-06-08-proxy-hf-download-503-fix`(本 fix 删除与其矛盾的旧规则)
- **关联 spec/plan ChangeLog 条目**:`fetch-weights/SKILL.md`、`preflight-gpu-disk/SKILL.md` 2026-06-10 条目

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → ✅
- [x] **Master Plan Fix 索引区已更新** → ✅
- [ ] **是否提升到 memory/lessons** → 否(`.env` 注释 + SKILL 反模式已覆盖)
- [ ] **是否需要 L1 / L2 重测验证** → 是(手动 e2e daily.sh,本日完成)
- [ ] **是否需要写 pending_human** → 是 — eagle 需人工在 HF 上接受 NVIDIA license(由 fetch-agent 在 e2e run 中落 `pending_human/eagle.md`)

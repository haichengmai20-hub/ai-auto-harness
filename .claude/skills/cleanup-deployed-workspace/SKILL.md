---
name: cleanup-deployed-workspace
description: 部署成功且 runbook 已写后,白名单清理 workspace 的可重建产物(venv/.cache/repo),保留 state/results/logs/output,把磁盘从 ~30GB 降到 ~50MB
allowed-tools: [Read, Bash]
agent: cleanup-agent
---

# cleanup-deployed-workspace

## 落盘约定(必读)

- **日志**:`$WORKSPACE/logs/cleanup.log` — 每条删除/保留 + 总结
- **结果**:`$WORKSPACE/results/cleanup.json` — return schema
- **state 更新**:`$WORKSPACE/state.json` — `phase: "done" → "archived"`,加 `archived_at` + `freed_bytes`
- **决策**:`runs/$RUN_ID/decisions.md` — append 一行

```bash
mkdir -p "$WORKSPACE/logs" "$WORKSPACE/results"
LOG="$WORKSPACE/logs/cleanup.log"
echo "==== cleanup start at $(date -Iseconds) ====" >> "$LOG"
# R8: PHASE_START/END 必须同时写到 stdout(ndjson 监控)和 cleanup.log(审计)
echo "=== PHASE_START phase=cleanup slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ===" | tee -a "$LOG"
```

注:你**只 Read + Bash**(无 Edit/Write),所以"写日志"也只能通过 `>> "$LOG"` 或 `tee -a`,"写 JSON"用 `bash -c 'cat > $WORKSPACE/results/cleanup.json <<JSON ... JSON'`。

## 你的输入(主 agent 传入)

```json
{
  "slug": "song-generation",
  "workspace_path": "/root/ai-auto-harness/workspace/song-generation",
  "run_id": "songgen-e2e-20260525-143000",
  "verify_passed": true,
  "runbook_path": "reports/runbooks/song-generation-2026-05-25.md",
  "dry_run": false,
  "force_cleanup_incomplete": false
}
```

- `dry_run`:默认 `false`(生产模式真删);可传 `true` 走预演,不真删但 log 输出 "would rm"
- `force_cleanup_incomplete`:仅在 verify_passed=false 时由主 agent 显式传 true 才允许清(默认 false,verify 没过就保留 workspace)

## 工作流(分 5 步)

### 第 1 步:4 道防护(任一不过 = 整个 cleanup 跳过)

#### G1: workspace 路径前缀校验

```bash
case "$WORKSPACE" in
    /root/ai-auto-harness/workspace/*) : ;;
    *) 
        echo "REFUSED G1: workspace_path 不在安全前缀 (/root/ai-auto-harness/workspace/)" >> "$LOG"
        echo "  实际: $WORKSPACE" >> "$LOG"
        # 立刻 raise,绝不动磁盘
        SKIPPED=true
        SKIPPED_REASON="G1_prefix_check_failed"
        ;;
esac

# 进一步:workspace_path 必须包含 slug
case "$WORKSPACE" in
    *"/$SLUG"|*"/$SLUG/") : ;;
    *)
        echo "REFUSED G1: workspace_path 不包含 slug=$SLUG" >> "$LOG"
        SKIPPED=true
        SKIPPED_REASON="G1_slug_mismatch"
        ;;
esac
```

#### G2: trace 完整校验

```bash
TRACE_DIR="runs/$RUN_ID"
if [ ! -d "$TRACE_DIR" ]; then
    echo "REFUSED G2: trace 目录不存在: $TRACE_DIR" >> "$LOG"
    SKIPPED=true
    SKIPPED_REASON="G2_trace_dir_missing"
fi
# trace 文件检查:launch_worker.sh 产 harness.stdout.ndjson,交互式 session 产 transcript.jsonl
# 两种格式都算 trace 完整(见 Fix 2026-05-29-g2-trace-format-flexible-fix)
if [ ! -f "$TRACE_DIR/harness.stdout.ndjson" ] && [ ! -f "$TRACE_DIR/transcript.jsonl" ]; then
    echo "REFUSED G2: trace 文件缺失(harness.stdout.ndjson 和 transcript.jsonl 都不存在)" >> "$LOG"
    SKIPPED=true
    SKIPPED_REASON="G2_trace_file_missing"
fi
if [ ! -f "$TRACE_DIR/meta.json" ]; then
    echo "REFUSED G2: meta.json 缺失" >> "$LOG"
    SKIPPED=true
    SKIPPED_REASON="G2_meta_missing"
fi
# 若 G2 失败 → 还要写 pending_human,提示 trace 不完整可能 run 出问题
if [ -n "$SKIPPED_REASON" ] && [[ "$SKIPPED_REASON" == G2_* ]]; then
    cat > "pending_human/$SLUG.md" <<EOF
# Cleanup 跳过:$SLUG

**原因**: $SKIPPED_REASON
**Run ID**: $RUN_ID
**时间**: $(date -Iseconds)

trace 不完整,workspace 保留供事后排查。
若确认可清理,手动 \`rm -rf $WORKSPACE\` 即可。
EOF
fi
```

#### G3: runbook 已写校验

**`runbook_path` 路径约定**:主 agent 传入的 `runbook_path` **统一相对于 `$HARNESS_ROOT=/root/ai-auto-harness/`**(即 `reports/runbooks/<slug>-<date>.md` 这种相对 root 的形式)。检查存在性时必须拼接 `$HARNESS_ROOT/$RUNBOOK_PATH`,不依赖 CWD。

```bash
# 标准化 runbook 检查路径(handle 相对/绝对两种输入)
HARNESS_ROOT="${HARNESS_ROOT:-/root/ai-auto-harness}"
case "$RUNBOOK_PATH" in
    /*) RUNBOOK_CHECK="$RUNBOOK_PATH" ;;       # 绝对路径直接用
    *)  RUNBOOK_CHECK="$HARNESS_ROOT/$RUNBOOK_PATH" ;;  # 相对路径拼 root
esac

if [ ! -f "$RUNBOOK_CHECK" ]; then
    echo "REFUSED G3: runbook 文件不存在: $RUNBOOK_CHECK" >> "$LOG"
    SKIPPED=true
    SKIPPED_REASON="G3_runbook_missing"
elif [ $(wc -c < "$RUNBOOK_CHECK") -lt 1024 ]; then
    echo "REFUSED G3: runbook 文件 < 1KB,可能是半成品: $RUNBOOK_CHECK" >> "$LOG"
    SKIPPED=true
    SKIPPED_REASON="G3_runbook_too_small"
fi
```

**为什么 runbook 必须先在**:cleanup 删了 workspace 就没法重新抽 runbook。runbook 是清理后唯一的"如何复现"依据。

#### G4: verify_passed 或 explicit force

```bash
if [ "$VERIFY_PASSED" != "true" ] && [ "$FORCE_CLEANUP_INCOMPLETE" != "true" ]; then
    echo "REFUSED G4: verify_passed=false 且 force_cleanup_incomplete=false,跳过清理" >> "$LOG"
    SKIPPED=true
    SKIPPED_REASON="G4_verify_not_passed"
fi
```

**任一 G1-G4 不过** → 直接进第 5 步,return `{skipped: true, ...}`,**不动磁盘**。

### 第 2 步:白名单删(严格 bash,不用 `*` 展开 root)

**绝不**用 `rm -rf $WORKSPACE/$VAR/*`(`$VAR` 空就清根)。**必须**显式枚举。

**白名单 targets**(写死,**严禁** LLM 临时增减):
```
venv .cache hf_cache repo weights
```

注:
- `.cache` 和 `hf_cache` 都列入是因为不同 launch_worker 版本环境变量(`HF_HOME` / `PIP_CACHE_DIR`)落点可能不同。两个都尝试,不存在的标 NOT EXIST 跳过。
- `weights` 列入是因为 fetch-weights 阶段下载的模型权重通常放在 `workspace/<slug>/weights/` 或 `workspace/<slug>/repo/weights/`,这是可重建产物(可重新 `hf download`)。
- `runs/<run-id>/.cache/`(本 run 的 launch_worker isolated cache)由**第 2.5 步**独立处理 — **只清本 run 的**,不递归清其他 run 的 cache(R1 隔离)。

```bash
FREED_BYTES=0
REMOVED=()
WOULD_REMOVE=()           # dry_run 模式累计
SKIPPED_NOT_EXIST=()

# 白名单(只清这 5 个目录,严禁改)
TARGETS=(venv .cache hf_cache repo weights)

for target in "${TARGETS[@]}"; do
    TARGET_PATH="$WORKSPACE/$target"
    if [ -d "$TARGET_PATH" ]; then
        # 抽尺寸(供日志/return)
        SIZE_BYTES=$(du -sb "$TARGET_PATH" 2>/dev/null | awk '{print $1}')
        SIZE_HUMAN=$(du -sh "$TARGET_PATH" 2>/dev/null | awk '{print $1}')

        if [ "$DRY_RUN" = "true" ]; then
            echo "[DRY] would rm -rf $TARGET_PATH ($SIZE_HUMAN)" >> "$LOG"
            WOULD_REMOVE+=("$target")
            FREED_BYTES=$((FREED_BYTES + SIZE_BYTES))   # dry_run 也累计 would-be 释放量
        else
            rm -rf "$TARGET_PATH"
            if [ $? -eq 0 ]; then
                echo "removed $TARGET_PATH ($SIZE_HUMAN, $SIZE_BYTES bytes)" >> "$LOG"
                FREED_BYTES=$((FREED_BYTES + SIZE_BYTES))
                REMOVED+=("$target")
            else
                echo "ERROR removing $TARGET_PATH" >> "$LOG"
            fi
        fi
    else
        # P4-6: 不存在的 target 也明确写日志(审计完整性,防止人误以为已删)
        if [ "$DRY_RUN" = "true" ]; then
            echo "[DRY] would rm -rf $TARGET_PATH (NOT EXIST, skip)" >> "$LOG"
        else
            echo "skipped $TARGET_PATH (NOT EXIST)" >> "$LOG"
        fi
        SKIPPED_NOT_EXIST+=("$target")
    fi
done

# 总结(P4-4: 同时给 GiB 单位与 du -sh 对齐,GB 单位用 SI 1e9)
FREED_GIB=$(awk -v b=$FREED_BYTES 'BEGIN{printf "%.2f", b/1073741824}')   # 1024^3
FREED_HUMAN=$(awk -v b=$FREED_BYTES 'BEGIN{
    if (b > 1e9) printf "%.1fGB", b/1e9;
    else if (b > 1e6) printf "%.1fMB", b/1e6;
    else printf "%dKB", b/1e3
}')
if [ "$DRY_RUN" = "true" ]; then
    echo "[summary] would_free $FREED_HUMAN ($FREED_GIB GiB) total (dry_run, not actually freed)" >> "$LOG"
else
    echo "[summary] freed $FREED_HUMAN ($FREED_GIB GiB) total" >> "$LOG"
fi
```

### 第 2.5 步:清本 run 的 isolated cache(runs/$RUN_ID/.cache/)

launch_worker.sh 为每个 cron run 创建一个 isolated cache 在 `runs/$RUN_ID/.cache/`(用 `HF_HOME` / `PIP_CACHE_DIR` env 隔离)。这部分 launch_worker 自己不清,长期积累可能十几 GB(实测 13G+9G 残留)。

**边界严格**:只清**本 run** 的 `runs/$RUN_ID/.cache/`,**绝不**递归清其他 run 的 cache(那是别人 run 的产物,R1 隔离)。

```bash
RUN_CACHE_FREED_BYTES=0
RUN_CACHE_REMOVED=false

# 安全检查:RUN_ID 非空 + 路径标准化 + 严格前缀(防 path traversal)
if [ -z "$RUN_ID" ]; then
    echo "WARN run-cache: RUN_ID 为空,跳过 run cache 清理" >> "$LOG"
elif [[ "$RUN_ID" == *..* || "$RUN_ID" == */* ]]; then
    echo "REFUSED run-cache: RUN_ID 含 ../ 或 /,拒绝清理 (RUN_ID=$RUN_ID)" >> "$LOG"
else
    HARNESS_ROOT="${HARNESS_ROOT:-/root/ai-auto-harness}"
    RUN_CACHE="$HARNESS_ROOT/runs/$RUN_ID/.cache"

    # 必须精确前缀,防变量空时清根
    case "$RUN_CACHE" in
        "$HARNESS_ROOT/runs/$RUN_ID/.cache")
            if [ -d "$RUN_CACHE" ]; then
                RC_SIZE_BYTES=$(du -sb "$RUN_CACHE" 2>/dev/null | awk '{print $1}')
                RC_SIZE_HUMAN=$(du -sh "$RUN_CACHE" 2>/dev/null | awk '{print $1}')
                if [ "$DRY_RUN" = "true" ]; then
                    echo "[DRY] would rm -rf $RUN_CACHE ($RC_SIZE_HUMAN, run-isolated cache)" >> "$LOG"
                    RUN_CACHE_FREED_BYTES=$RC_SIZE_BYTES
                else
                    rm -rf "$RUN_CACHE"
                    if [ $? -eq 0 ]; then
                        echo "removed $RUN_CACHE ($RC_SIZE_HUMAN, $RC_SIZE_BYTES bytes, run-isolated cache)" >> "$LOG"
                        RUN_CACHE_FREED_BYTES=$RC_SIZE_BYTES
                        RUN_CACHE_REMOVED=true
                    else
                        echo "ERROR removing $RUN_CACHE" >> "$LOG"
                    fi
                fi
            else
                if [ "$DRY_RUN" = "true" ]; then
                    echo "[DRY] would rm -rf $RUN_CACHE (NOT EXIST, skip)" >> "$LOG"
                else
                    echo "skipped $RUN_CACHE (NOT EXIST, run-isolated cache)" >> "$LOG"
                fi
            fi
            # 累加到总 freed
            FREED_BYTES=$((FREED_BYTES + RUN_CACHE_FREED_BYTES))
            FREED_GIB=$(awk -v b=$FREED_BYTES 'BEGIN{printf "%.2f", b/1073741824}')
            FREED_HUMAN=$(awk -v b=$FREED_BYTES 'BEGIN{
                if (b > 1e9) printf "%.1fGB", b/1e9;
                else if (b > 1e6) printf "%.1fMB", b/1e6;
                else printf "%dKB", b/1e3
            }')
            ;;
        *)
            echo "REFUSED run-cache: 路径不在 $HARNESS_ROOT/runs/$RUN_ID/.cache (拒绝)" >> "$LOG"
            ;;
    esac
fi
```

**严禁**:
- ❌ 用 `find runs/ -name .cache -exec rm` 或 `rm -rf runs/*/.cache` — 会动其他 run 的 cache(R1 违反)
- ❌ RUN_ID 为空时还硬清(会清成 `$HARNESS_ROOT/runs//.cache` = 不存在,但万一 shell 解释器有 bug 就危险)
- ❌ 不写日志直接删 — 必须 echo 到 `$LOG`

### 第 3 步:保留清单审计(查不该删的没删)

```bash
KEPT=()
PRESERVE=(state.json results logs output progress.md)

for item in "${PRESERVE[@]}"; do
    KEEP_PATH="$WORKSPACE/$item"
    if [ -e "$KEEP_PATH" ]; then
        KEPT+=("$item")
    fi
done

echo "[summary] kept: ${KEPT[*]}" >> "$LOG"
```

### 第 4 步:更新 state.json → archived(dry_run 模式跳过这步)

```bash
if [ "$DRY_RUN" != "true" ]; then
    NOW=$(date -Iseconds)
    jq --arg p "archived" \
       --arg ts "$NOW" \
       --argjson fb $FREED_BYTES \
       '.phase = $p | .status = $p | .archived_at = $ts | .freed_bytes = $fb | .updated_at = $ts' \
       "$WORKSPACE/state.json" > /tmp/state-new && mv /tmp/state-new "$WORKSPACE/state.json"
    echo "state.json: phase=done → archived" >> "$LOG"
fi
```

### 第 5 步:写 results/cleanup.json + 返回

```bash
# 写 cleanup.json
# P4-2: dry_run 模式用 would_remove 字段(语义清晰),生产模式用 removed
if [ "$DRY_RUN" = "true" ]; then
    REMOVED_FIELD="would_remove"
    REMOVED_ARR=("${WOULD_REMOVE[@]}")
    FREED_HUMAN_FIELD="$FREED_HUMAN (dry_run, not actually freed)"
else
    REMOVED_FIELD="removed"
    REMOVED_ARR=("${REMOVED[@]}")
    FREED_HUMAN_FIELD="$FREED_HUMAN"
fi

bash -c "cat > '$WORKSPACE/results/cleanup.json' <<JSON
{
  \"slug\": \"$SLUG\",
  \"$REMOVED_FIELD\": [$(printf '\"%s\",' "${REMOVED_ARR[@]}" | sed 's/,$//')],
  \"skipped_not_exist\": [$(printf '\"%s\",' "${SKIPPED_NOT_EXIST[@]}" | sed 's/,$//')],
  \"kept\": [$(printf '\"%s\",' "${KEPT[@]}" | sed 's/,$//')],
  \"freed_bytes\": $FREED_BYTES,
  \"freed_gib\": $FREED_GIB,
  \"freed_human\": \"$FREED_HUMAN_FIELD\",
  \"run_cache_freed_bytes\": $RUN_CACHE_FREED_BYTES,
  \"run_cache_removed\": $RUN_CACHE_REMOVED,
  \"dry_run\": $DRY_RUN,
  \"skipped\": ${SKIPPED:-false},
  \"skipped_reason\": ${SKIPPED_REASON:+\"$SKIPPED_REASON\"},
  \"runbook_path\": \"$RUNBOOK_PATH\",
  \"completed_at\": \"$(date -Iseconds)\"
}
JSON"

# decisions.md append
if [ "$DRY_RUN" = "true" ]; then
    echo "- $(date -Iseconds) by cleanup-agent: DRY-RUN would free $FREED_HUMAN (${REMOVED[*]})" >> "runs/$RUN_ID/decisions.md"
else
    echo "- $(date -Iseconds) by cleanup-agent: freed $FREED_HUMAN, archived $SLUG" >> "runs/$RUN_ID/decisions.md"
fi

echo "==== cleanup end at $(date -Iseconds) ====" >> "$LOG"
# R8: 必须同时写到 stdout 和 cleanup.log。tee -a 缺一不可,**严禁只 echo 到 stdout**(L1 实测漏写过)
echo "=== PHASE_END   phase=cleanup slug=$SLUG status=${SKIPPED:+skipped}${SKIPPED:-done} ts=$(date -Iseconds) ===" | tee -a "$LOG"
```

## 返回 schema

成功 case(生产模式 `dry_run=false`):

```json
{
  "slug": "song-generation",
  "removed": ["venv", ".cache", "hf_cache", "repo", "weights"],
  "skipped_not_exist": [],
  "kept": ["state.json", "results", "logs", "output"],
  "freed_bytes": 48567890123,
  "freed_gib": 45.23,
  "freed_human": "48.6GB",
  "run_cache_freed_bytes": 14000000000,
  "run_cache_removed": true,
  "dry_run": false,
  "skipped": false,
  "skipped_reason": null,
  "runbook_path": "reports/runbooks/song-generation-2026-05-25.md",
  "completed_at": "2026-05-25T14:35:00+08:00"
}
```

注:`freed_bytes` 已**包含** `run_cache_freed_bytes`(workspace targets + run-isolated cache 总和)。`run_cache_*` 字段是细分,审计用。

跳过 case(任一 G1-G4 失败):

```json
{
  "slug": "song-generation",
  "removed": [],
  "skipped_not_exist": [],
  "kept": [],
  "freed_bytes": 0,
  "freed_gib": 0.00,
  "freed_human": "0KB",
  "dry_run": false,
  "skipped": true,
  "skipped_reason": "G3_runbook_missing",
  "runbook_path": "reports/runbooks/song-generation-2026-05-25.md",
  "completed_at": "2026-05-25T14:35:00+08:00"
}
```

dry_run case(注意字段名是 `would_remove`,不是 `removed`):

```json
{
  "slug": "song-generation",
  "would_remove": ["venv", "hf_cache"],
  "skipped_not_exist": [".cache", "repo"],
  "kept": ["state.json", "results", "logs", "output"],
  "freed_bytes": 8573045260,
  "freed_gib": 7.98,
  "freed_human": "8.6GB (dry_run, not actually freed)",
  "dry_run": true,
  "skipped": false,
  "skipped_reason": null,
  "runbook_path": "...",
  "completed_at": "..."
}
```

注:
- dry_run 模式下 `freed_bytes` / `freed_gib` 是**估算的 would-be 释放量**,不是实际释放
- `freed_bytes` 用 SI 单位(1 GB = 1e9 bytes),`freed_gib` 用二进制单位(1 GiB = 2^30 bytes),与 `du -sh` 对齐
- 生产模式输出 `removed` 字段,dry_run 模式输出 `would_remove` 字段,**不混用**

## 🔴 反模式(L1 实测出现过的真实问题,**严禁重演**)

- ❌ **绝不**用 `rm -rf $WORKSPACE/$VAR/*` 或 `rm -rf "$WORKSPACE"/*`(变量空就清根)— 必须显式枚举 `for target in venv .cache hf_cache repo`
- ❌ **绝不**临时增减白名单 targets — 写死 `venv .cache hf_cache repo weights` 这 5 个,新增需要改 SKILL.md
- ❌ **绝不**清 G1-G4 任一不过的 workspace — return skipped
- ❌ **绝不**删 PRESERVE 清单内的项(state.json / results / logs / output / progress.md)
- ❌ **绝不**触动其他 workspace(R1 隔离)— `$WORKSPACE` 必须以 `/root/ai-auto-harness/workspace/` 起头
- ❌ **绝不**在 dry_run=true 时真删 — 只写 "would rm" 日志
- ❌ **绝不**漏写 `=== PHASE_END phase=cleanup ... ===` 到 cleanup.log(P4-1 L1 实测漏过)— **必须** `| tee -a "$LOG"`
- ❌ **绝不**在 dry_run 模式输出 `removed` 字段 — 用 `would_remove` 字段(P4-2 语义清晰)
- ❌ **绝不**递归清 `runs/*/.cache/`(其他 run 的 cache,R1 隔离);**只清本 run 的** `runs/$RUN_ID/.cache/`,见第 2.5 步
- ❌ **绝不**修问题或重跑 — cleanup 只清不修(出错就写 pending_human,主 agent 处理)

## 我做错了什么?常见诱惑

- ❌ "为了快,用 `rm -rf $WORKSPACE/{venv,.cache,repo}` 一行搞定" — **不**.bash brace expansion 在某些 shell 有兼容问题,且不易扩展(加 `output` 进白名单时容易写错). 显式 for 循环更安全
- ❌ "看到 venv 大,先 rm 几个 site-packages 试试" — **不**.白名单原则就是要么整目录删,要么不动. 部分删可能破坏依赖关系导致诊断混乱
- ❌ "verify_passed=false 但我看 runbook 写了 success,应该可以清" — **不**.verify_passed 是主 agent 传的事实,你无权重判. 严格按 G4 防护走
- ❌ "我顺便把 pending_human/$SLUG.md 也清了,反正部署成功了" — **不**.pending_human 是另一个 skill 的产物,不在你白名单内
- ❌ "为了省 log,把 cleanup.log 写成单行" — **不**.每个 target 单独一行,审计需要明细
- ❌ "我看 dry_run=true,顺手再 du -sh 一遍 workspace 总大小" — **可以**.dry_run 模式下额外查询是 OK 的,因为不真删. 但要把这些 query 也 echo 到 log

## 与 R 规则的关系

- **R1 workspace 隔离**:G1 防护就是 R1 在 cleanup 场景的硬化实现
- **R8 PHASE 标记**:进出 echo PHASE_START/END 必须有
- **R9 主 agent 严禁亲自 rm -rf**:你的存在就是让主 agent 不必自己干这事

## 测试时怎么用

### L1 单测(用 song-generation-run2 现成 workspace)

```bash
./bin/claude-haha -p "
按 cleanup-deployed-workspace skill 跑:
- slug: song-generation-run2
- workspace_path: /root/ai-auto-harness/workspace/song-generation-run2
- run_id: songgen-e2e-run3-resume-20260522-094040
- verify_passed: true
- runbook_path: reports/runbooks/song-generation-run2-2026-05-25.md
- dry_run: true
"
```

期望:
- 4 道防护全过(G1 prefix ✓ / G2 trace ✓ / G3 runbook ✓ / G4 verify ✓)
- log 输出 "[DRY] would rm venv (9.2GB), .cache (6.1GB), repo (180MB)"
- state.json 不更新(dry_run 模式)
- 磁盘大小不变
- return `dry_run: true, freed_bytes: ~16GB(estimated)`

## ChangeLog

- **2026-06-02** — 白名单 targets `venv .cache hf_cache repo` → 加 `weights`(4→5)
  - 变更类型: 硬约束(白名单枚举)
  - 影响范围: 白名单 targets 段 / TARGETS 数组 / return schema 示例 / 反模式段
  - 动机: omnivoice cleanup 留下 `weights/` 3.1GB 可重建产物未清(P7-1/问题13)
  - 证据: [fixes/2026-06-02-runbook-cleanup-artifact-accuracy-fix.md](../../../docs/superpowers/fixes/2026-06-02-runbook-cleanup-artifact-accuracy-fix.md)

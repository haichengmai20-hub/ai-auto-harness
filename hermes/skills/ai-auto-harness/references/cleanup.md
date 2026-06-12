# cleanup playbook(Hermes 子代理)

部署成功且 runbook 已写后,白名单清理 workspace 可重建产物(~30GB→~50MB)。**保留** state.json/results/logs/output/runs。

## 🔴 G1-G4 安全门(任一不过 → return {skipped:true},不动磁盘)

```bash
source /root/ai-auto-harness/hermes/scripts/guard.env.sh
echo "=== PHASE_START phase=cleanup slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ==="
```

- **G1 路径前缀**:workspace_path 必须以 `/root/ai-auto-harness/workspace/` 开头**且**包含 `$SLUG`,否则 REFUSED
- **G2 trace 完整**:`$RUN_DIR` 存在 + meta.json 在 +(events/transcript 至少一种 trace 在;Hermes 下 session 记录在 Hermes DB,trace 文件缺失时检查 `results/` 五阶段 json 齐全替代)。不过 → REFUSED + 写 pending_human(trace 不完整可能 run 有问题)
- **G3 runbook 已写**:`state.json.runbook_path` 指向的文件存在且 ≥1KB(删了 workspace 就没法重抽 runbook)
- **G4 verify 通过**:`jq -r '.passed' results/verify.json` == true,或主 agent 显式传 `force_cleanup_incomplete=true`

## 白名单删(写死 5 个,严禁增减;绝不 `rm -rf $WORKSPACE/$VAR/*` 之类变量展开)

```bash
TARGETS=(venv .cache hf_cache repo weights)
for target in "${TARGETS[@]}"; do
    TARGET_PATH="$WORKSPACE/$target"
    if [ -d "$TARGET_PATH" ]; then
        SIZE_BYTES=$(du -sb "$TARGET_PATH" 2>/dev/null | awk '{print $1}')
        if [ "$DRY_RUN" = "true" ]; then
            echo "[DRY] would rm -rf $TARGET_PATH" >> "$LOG"
        else
            rm -rf "$TARGET_PATH" && echo "removed $TARGET_PATH ($SIZE_BYTES bytes)" >> "$LOG"
        fi
        FREED_BYTES=$((FREED_BYTES + SIZE_BYTES))
    else
        echo "skipped $TARGET_PATH (NOT EXIST)" >> "$LOG"   # 审计完整性,不存在也记
    fi
done
```

注意:删之前每个 target 记 size;`.cache` 里含 handoff sentinel — 项目 archived 后 sentinel 没意义,可随 .cache 删。

## 保留审计

删完检查必须还在:`state.json` `results/` `logs/` `runs/`(若有 output/artifacts 也留)。缺了 → 立即报告,不掩盖。

## 收尾

- 非 dry_run:jq 更新 state `phase=archived, status=done` + phases_done += cleanup
- `results/cleanup.json`(heredoc 求值):

```json
{"skipped":false,"skipped_reason":null,"removed":["venv",".cache","repo"],
 "freed_bytes":0,"freed_human":"28.4GB","dry_run":false,"completed_at":"..."}
```

PHASE_END。**summary 原样含 cleanup.json 全文**。

## 反模式

- ❌ verify 没过还清(G4;失败现场唯一)
- ❌ 白名单外的任何路径(尤其 `runs/`、别人的 workspace、`$HARNESS_ROOT` 级目录)
- ❌ 变量展开式 rm(`$VAR` 空 = 清根)
- ❌ 不写日志直接删;❌ runbook 没落盘就清(G3)

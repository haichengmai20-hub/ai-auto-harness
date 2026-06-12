# run-and-repair playbook(Hermes 子代理)

试跑 entry_script + 自主修复循环。**你就是 repair loop**:每轮 = 观察→决策→执行→验收。

## 落盘

运行日志 `logs/run_and_repair.log`;修复轨迹 `logs/fixes.log`(每修一行);详细决策 `$RUN_DIR/decisions.md`;结果 `results/run.json`。

## 第 0 步(每条 bash 前缀)

```bash
source /root/ai-auto-harness/hermes/scripts/guard.env.sh
source "$VENV_PATH/bin/activate"
export CUDA_VISIBLE_DEVICES="<gpu_picks 逗号串>"
export HF_HOME="$WORKSPACE/.cache/huggingface" HF_HUB_CACHE="$WORKSPACE/.cache/hf_hub"
echo "=== PHASE_START phase=run-and-repair slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ==="
```

R2:state `phase=running, status=running`。

## 第 0.5 步:GPU pre-flight(必做)

```bash
python -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_capability(), torch.cuda.get_arch_list())"
```
`cuda_available=False` 或 5090 上 capability 无 (12,0) → **不要继续试跑**,pending_human(install 装错了)。

## 第 1 步:试跑

- 短任务:`cd "$WORKSPACE/repo" && $ENTRY_SCRIPT >> "$LOG" 2>&1; echo exit=$?`
- 长任务(>10min 推理):setsid nohup 后台 + `echo $! > "$WORKSPACE/.cache/run.pid"` + poll

## 第 2 步:观察(每轮决策前必做)

`tail -50 run.log` + `nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader` + `ls 输出目录` + PID 死活。

## 第 3 步:决策

- **成功**:exit 0 + 预期输出文件存在且大小合理 → passed=true
- **还在跑**:PID 活 + GPU util >10% + log 有新输出 → 不修不动,继续 poll。**R4.6 动态间隔**:健康时 30s→45s→60s,可 `sleep 55 && tail -5 "$LOG"` 合并为一次 poll(单次 sleep ≤60s 不变);已知长耗时步骤(resharding/编译 5-10min)预计超 8 次 poll 预算 → 直接 paused_in_progress return
- **卡死**:PID 活但 30min GPU 0% + 无新输出 + 无新文件 → kill(自有 PID)重启或换 GPU
- **真出错**:看 stderr root cause,优先读 `memory/lessons/*.md` 找同类。常见:CUDA OOM→减 batch/量化;No module→pip install;NaN+5090→sm_12(lessons/torch-sm12.md);ImportError flash_attn→try/except fallback(lessons/flash-attn-build.md);exit 137/-9→OOMKill 减负载;401→pending_human

## 第 4 步:修复(每修必记两笔)

修代码(先读后小改,**不重写整文件**)/修 env(写 state.env_overrides)/修配置/修依赖。

```bash
echo "$(date -Iseconds) round=$ROUND error=<类> fix=<动作> file=<路径>" >> "$WORKSPACE/logs/fixes.log"
# + decisions.md 一段:时间/轮次/类型/检测到什么/改了什么/期望
```

## 第 5 步:验收与轮次纪律

**3 轮上限 + 轮次分类(P11)**:
- **依赖缺失类**(ModuleNotFoundError / import 期 ImportError/AssertionError)→ **不计轮**,额外最多 2 次(一条 pip 能解决的问题不烧修复轮)
- **框架 bug 类**(tensor mismatch / OOM / segfault / RuntimeError)→ 计入 3 轮
- decisions.md 每轮标注:`(round 2/3, 类型=框架bug)` 或 `(依赖补装 1/2, 不计轮)`

**🔴 R11 分支纪律**:**严禁 git checkout/switch 切分支当修复手段**(丢已打补丁 + 新分支结构不兼容,SCAIL 实测;guard 会直接拒绝)。`git checkout -- <file>` 恢复单文件豁免。当前分支跑不通 → paused_for_human,把"建议试 X 分支"写进 next_steps_suggested。

3 轮(按分类口径)用完未过 → 写 pending_human(stuck_repair_3x,含 what_tried 每轮一行/what_blocked/next_steps_suggested),return `{"passed":false,"blocked":true,"paused_for_human":true}`。**不要硬试第 4 轮**。

## 第 6 步:写经验

项目特有(entry 位置/项目 own 配置)→ `memory/projects/<slug>.md`;同类 stack 通用 → `memory/lessons/<topic>.md` append;常识性微调 → 不写。

## 落盘 + 返回

`results/run.json`(bash heredoc 求值):

```json
{"passed":true,"error_class":null,"repair_count":1,"stdout_tail":"<最后50行>",
 "gpu_snapshot":{"memory_used_mb":0,"utilization_pct":0,"gpu_index":0},
 "fixes_applied":[...],"post_conditions_met":{...},"blocked":false,"paused_for_human":false,"completed_at":"..."}
```

🔴 **统计口径**:为跑通做的**一切适配都算修复**(改 import/版本/config/patch 代码/wrapper/entry 参数),每个动作进 fixes_applied,repair_count=轮数(omnivoice 实测 52 处适配写 repair_count=0,下游全失真)。
更新 state(`phase=verifying`)+ PHASE_END。**summary 原样含 run.json 全文**。

## 反模式

- ❌ 长任务同步阻塞跑;❌ Edit 不先读;❌ 修了不记 fixes.log/decisions.md
- ❌ 修第 4/5/6 轮;❌ 重写整文件;❌ 不看 nvidia-smi 就说"在跑"
- ❌ 有适配却 repair_count=0;❌ git checkout/switch 切分支(R11)

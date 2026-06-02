# Monitor 经验库

> 本文件由 monitor-ride-along agent 的 post-mortem 审计自动追加。
> 新的 monitor agent 启动时读本文件获取历史经验，不需要每次重新交代。

---

## CONCURRENT_HF: 多个 hf download 进程写同一 local-dir 导致锁竞争

**首次发现**: 2026-05-26 ControlFoley run
**现象**: 3 个 `hf download` 进程（PID 1655045, 1705343, 1751992）同时写 `--local-dir`，下载速度 0 MB/s
**根因**: LLM agent 发现下载慢后"重试"，但没 kill 旧进程。新版 `hf` CLI 用文件锁，多进程写同一目录产生锁竞争
**检测方法**: `pgrep -f 'hf download' | wc -l > 1` + 检查是否有多个进程指向同一 `--local-dir`
**建议修复**: fetch-weights SKILL.md 加硬规则"严禁在已有 hf download 进程时再启动新的"；加 `flock` 文件锁

## HOOK_COUNTER_BUG: PostToolUse hook 计数器全为 0

**首次发现**: 2026-05-26 ControlFoley run
**现象**: `.hook_state.json` 显示 `bash_count=0, poll_count=0, sleep_streak=0, task_called=0`，但实际有 43 次 Bash
**根因**: PostToolUse hook 可能未正确触发，或 hook 脚本读取 stdin event 格式与实际输出不匹配
**检测方法**: 对比 `hook_state.bash_count` 与 `transcript.jsonl` 中 tool_name=Bash 的行数，差异 > 5 即判定 hook 失效
**建议修复**: 排查 hook 脚本的 stdin 读取逻辑；加 hook 自检（SessionEnd 输出最终 hook_state 到 stderr）

## R9_VIOLATION: 主 agent 直接 Bash 而非 Task() dispatch

**首次发现**: 2026-05-26 ControlFoley run
**现象**: 43 次 Bash、0 次 Task()，所有工作主 agent 亲自执行
**根因**: auto-deploy SKILL.md 虽写了 R9 规则，但 hook 没有强制执行（因 HOOK_COUNTER_BUG）
**检测方法**: `hook_state.bash_count > 10 && hook_state.task_called == 0`
**建议修复**: 修复 hook 计数器后，R9 检测自然生效；考虑 bash_count > 10 时拒绝后续 Bash

## DEPRECATED_HF_CLI: huggingface-cli 命令已废弃

**首次发现**: 2026-05-21 SongGen run（R7 规则来源）
**持续出现**: 2026-05-26 ControlFoley run — fetch-weights SKILL.md 仍引用 `huggingface-cli`
**现象**: `huggingface-cli download` 产生 deprecation warning，且不支持 hf_transfer 加速
**根因**: 旧版 huggingface_hub 的 CLI，新版已改名为 `hf`
**检测方法**: `grep -r 'huggingface-cli' workspace/$SLUG/logs/`
**建议修复**: 全局替换 `huggingface-cli` → `hf`；fetch-weights SKILL.md 更新

## DEPRECATED_RESUME_FLAG: --resume-download flag 在新版 hf CLI 中不存在

**首次发现**: 2026-05-26 ControlFoley run
**现象**: `hf download --resume-download` 报错 "unrecognized arguments: --resume-download"
**根因**: 新版 `hf` CLI 移除了 `--resume-download`，默认行为就是断点续传
**检测方法**: `grep -r '\-\-resume-download' workspace/$SLUG/logs/`
**建议修复**: fetch-weights SKILL.md 移除 `--resume-download`；加已知踩坑条目

## DEPRECATED_HF_TRANSFER_ENV: HF_HUB_ENABLE_HF_TRANSFER 已被 Xet 替代

**首次发现**: 2026-05-26 ControlFoley run
**现象**: 日志出现 FutureWarning: "The HF_HUB_ENABLE_HF_TRANSFER environment variable is deprecated"
**根因**: hf_transfer 已被 Xet 协议替代，旧环境变量不再生效
**检测方法**: `grep -r 'HF_HUB_ENABLE_HF_TRANSFER' workspace/$SLUG/logs/`
**建议修复**: launch_worker.sh 改 `HF_XET_HIGH_PERFORMANCE=1`；fetch-weights SKILL.md 更新

## STATE_STALE: state.json phase 长时间不更新

**首次发现**: 2026-05-26 ControlFoley run
**现象**: state.json 停在 `phase=fetch-weights`，从未更新到后续阶段
**根因**: 各 phase agent 没有在完成时更新 state.json（R2 违反）
**检测方法**: `state.updated_at` 距今 > 30 分钟且 phase ∉ {done, archived, paused_for_human}
**建议修复**: 每个 phase SKILL.md 加硬规则"完成时必须 jq 更新 state.json"；主 agent 检查 phase 推进

## ZOMBIE_HF_PROCS: 僵尸 hf 进程累积

**首次发现**: 2026-05-26 ControlFoley run
**现象**: 17 个 `<defunct>` hf 进程从 May21 残留
**根因**: nohup/setsid 起的子进程 parent 退出后未被 wait，变成 zombie
**检测方法**: `ps aux | grep '<defunct>' | grep -v grep | wc -l`
**建议修复**: launch_worker.sh 的 cleanup_zombies() 加 `pkill -9 -f 'hf download'`；每次 run 结束清理

## RUNBOOK_COST_MISLEADING: total_cost_usd=0.0 表示数据不可用而非免费

**首次发现**: 2026-05-29 hunyuan3d-2 runbook
**现象**: runbook 写 `total_cost_usd: 0.0`，实际是交互式 session 无 cost 数据
**根因**: 交互式 session 的 transcript.jsonl 无 cost 事件，LLM 填了 0.0 而非 null
**检测方法**: runbook 中 `total_cost_usd == 0.0 && turns > 0` → 数据不可用
**建议修复**: runbook SKILL.md 已加规则写 null；模板示例改为 null

## CLEANUP_WEIGHTS_LEAK: weights/ 不在白名单导致清理后磁盘泄漏

**首次发现**: 2026-05-29 omnivoice cleanup
**现象**: cleanup freed 7.9GB 但留下 3.1GB weights/ 目录
**根因**: cleanup 白名单只有 `venv .cache hf_cache repo`，缺少 `weights`
**检测方法**: cleanup 后 `du -sh $WORKSPACE/*/` 检查是否有 > 100MB 的目录残留
**建议修复**: 白名单已加 `weights`；加白名单审计步骤

## MCP_SCAN_SKIPPED: e2e run 未调用 MCP scan

**首次发现**: 2026-05-26 ControlFoley e2e run
**现象**: 0 次 MCP 工具调用，项目选择靠 slug_override 手动指定
**根因**: e2e_pipeline_test.sh 的 slug_override 绕过了 scan 流程
**检测方法**: transcript.jsonl 中无 `mcp__ai_daily_scan__` 工具调用
**建议修复**: e2e test 加 --require-scan flag；主 agent prompt 加硬规则

## PIP_TIMEOUT: 大包下载撞 poll 预算被暂停

**首次发现**: 2026-05-29 omnivoice run
**现象**: torch wheel ~4GB 下载撞 poll 预算，pip 中断后需重入 3 次
**根因**: torch+cu128 wheel 体积巨大，下载耗时长
**检测方法**: install_env.log 中出现多次 `pip install torch` 起始行
**建议修复**: 拆 pip download + pip install 两步；加 PIP_TIMEOUT 环境变量

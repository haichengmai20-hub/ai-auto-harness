# ai-auto-harness 框架完善 — 整体 Prompt（给 CC 做）

> 用途：把这份 prompt 喂给 Claude Code，让它理解框架全貌后按优先级实现改进
> 日期：2026-06-15
> 来源：paddleocr 全流程试跑 + khala 深度踩坑 + CC/Hermes 双版对比 + 17 个项目历史数据

---

## 一、框架是什么

ai-auto-harness 是一个 **cron 驱动的 AI 项目自动部署平台**，每天自动：
1. 从 ai-daily-scan 的 findings.jsonl 发现新 AI 项目
2. 按流水线部署：intake → fetch-weights → install-env → run-and-repair → verify → write-deploy-runbook → cleanup
3. 验证项目能否真正跑通推理
4. 产出公司视角建议 + 回填结果到 scan 系统

**核心设计**：主 agent 只做调度（dispatch SubAgent / 调 phase 脚本），不亲自执行任何 git clone / pip install / python 推理。每个 phase 由独立 SubAgent 或 bash 脚本执行，主 agent 负责状态流转和快照。

**两个版本**：
- CC 版（Claude Code + crontab）：SubAgent 执行，PostToolUse hook 实时拦截违规
- Hermes 版（Hermes Agent + cronjob）：delegate_task 执行，guard.env.sh bash 函数拦截
- 两者共用 workspace/state/sentinel/validate 脚本，同一时刻只能开一边的 cron

## 二、环境事实（必须知道）

| 事实 | 影响 |
|---|---|
| 本机无直连外网，一切经代理（.env 的 http_proxy） | HF/GitHub 下载必须走代理；严禁 unset proxy 或把外网域名加 no_proxy |
| Privoxy 代理拦截 localhost 通信 | 所有 curl http://127.0.0.1 被拦截，必须加 `--noproxy '*'` 或设 `no_proxy=127.0.0.1,localhost` |
| 8×RTX 5090 (32GB)，6 张常驻 vLLM | GPU 0-5 被占满，推理只能用 GPU 6-7；用户训练严禁 kill |
| 容器 PID 1 是 tail -f /dev/null 不收尸 | 僵尸进程 kill -0 误判活，判死要查 /proc/<pid>/stat |
| 磁盘 free < 150GB 不起新 run | 训练优先，部署让路 |
| .bashrc 第 139 行语法错误 + openclaw.bash 不存在 | 每次 source venv/bin/activate 都报两行错，污染日志 |

## 三、硬规则 R1-R11（违反 = 跑挂/作弊）

- **R1 隔离**：只动自己 $WORKSPACE；kill 只许动 $WORKSPACE/.cache/*.pid 登记的 PID
- **R2 state 双轴**：每 phase 起止 jq 原子更新 state.json（phase 轴 × status 轴）+ updated_at
- **R3 wall-clock**：intake 15' / fetch 180' / install 60' / run 45'×3 / verify 30'；超时走暂停
- **R4 等待纪律**：单次 sleep ≤60s，连续 sleep 禁，poll ≤8 次/phase；跨 cron 长任务必须 setsid nohup + sentinel
- **R4b setsid nohup 放行**：guard 审计但不拦截；必须写 PID 文件 + handoff sentinel
- **R5 串行带宽**：fetch 完全 done 才 install；下载与 pip 绝不并行
- **R6 pip**：禁 --no-cache-dir；禁并行 pip 写同一 venv
- **R7 HF 下载**：用 hf 不用 huggingface-cli；HF_HUB_DISABLE_XET=1 + CONCURRENCY=2；严禁 unset proxy
- **R8 phase 标记**：SubAgent 进出各 echo === PHASE_START|PHASE_END ===
- **R9 主 agent 只 dispatch**：严禁亲自 git clone / hf download / pip install / python 推理
- **R10 sentinel**：跨 cron 后台任务必写 handoff sentinel；PID 死立即补写终态
- **R11 分支纪律**：run-and-repair 严禁 git checkout/switch 切分支

**verify 独立判定**：verify SubAgent 禁读 state.json 的 run_result。

## 四、历史试跑数据（17 个项目）

| 项目 | 结果 | 失败原因 |
|---|---|---|
| hojo-asr | ✅ verify_passed | — |
| hunyuan3d-2 | ✅ verify_passed | — |
| magenta-realtime | ✅ verify_passed | — |
| omnivoice | ✅ verify_passed | — |
| song-generation-run2 | ✅ verify_passed | — |
| toonflow-app | ✅ verify_passed | — |
| paddleocr | ❌ verify_failed | PaddlePaddle CPU OneDNN bug（框架问题非 harness） |
| scail | ⏸ paused_for_human | flash_attn 缺失 + 切分支丢补丁 |
| khala | ❌ 跑不通 | Megatron TE 依赖链 + GPU 资源不足 + 服务型推理不支持 |
| eagle | ⏸ paused_for_human | gated repo 需审批 |
| ideogram4 | ⏸ paused_for_human | gated repo 需审批 |
| qwen3 | ⏸ paused_in_progress | 后台下载进行中 |
| gemma-pytorch | ⏸ intake done | 未继续 |
| controlfoley | archived | 主 agent 亲自跑了 165 条 bash、0 次派发（R9 违反） |
| deepseek-v4-pro | done(api_route) | >30B 走 api-skeleton |

**成功率**：6/17 = 35%（verify_passed），3/17 gated 需审批（非框架问题），实际可部署项目成功率 6/11 = 55%。

## 五、框架缺陷清单（按优先级）

### P0 — 不修就跑不通新项目类型

**F1. 服务型推理支持（entry_type=service）**

当前 run-and-repair 只认 `python3 script.py` 单次执行模式。但 Khala/vLLM/Gradio/Flask 类项目需要「启动服务 → 等 health check → 发 API 请求 → 取结果 → 停服务」。

需要：
- intake 增加 `entry_type` 字段：`script`（默认）/ `service`
- service 类型的 entry_script 改为描述服务启动+请求+停止的 JSON
- run-and-repair 对 service 类型走不同执行路径
- verify 对 service 类型做服务级验证
- cleanup 对 service 类型清理后台进程

**F2. Privoxy 拦截 localhost 通信**

所有 `curl http://127.0.0.1` 被 Privoxy 拦截。修复：所有 phase 脚本启动推理前设 `export no_proxy="127.0.0.1,localhost"` + `export NO_PROXY="127.0.0.1,localhost"`。写入环境事实段。

**F3. GPU 资源竞争检测**

preflight 不查 GPU 占用，默认 GPU 0 被训练占满直接 OOM。修复：preflight 输出可用 GPU 列表（已用 < 25GB 的卡），intake 从中选卡。无可用 GPU → paused_for_human。

### P1 — 不修就降低成功率

**F4. 后台进程 PID 注册机制**

R-guard 要求 kill 的 PID 必须在 $WORKSPACE/.cache/*.pid 登记。项目自带脚本（run_backend.sh 等）后台启动的进程不在登记体系内，cleanup 杀不掉。修复：run-and-repair 启动后台服务后立即 `pgrep -f <pattern> > $WORKSPACE/.cache/<task>.pid`。

**F5. Megatron/DeepSpeed 隐式依赖链检测**

requirements.txt 不含 TE/pybind11/six，逐轮发现逐轮装太慢。修复：install 阶段增加深度 import 探针 + 常见框架预设依赖套餐。

**F6. --use-checkpoint-args 与本地环境不兼容**

Megatron checkpoint 加载的 TE 参数和本地环境冲突。修复：检测 TE 是否可用，不可用则自动追加 `--no-rope-fusion --transformer-impl local --no-persist-layer-norm`。

**F7. 批量依赖修复**

连续 2 轮 dep_missing → 触发深度依赖扫描（pip check + 全量 import 检测），批量装。

**F9. 错误分类扩展**

当前只有 5 种分类（dep_missing / file_not_found / paddle_onednn / cuda_oom / unknown）。需要增加：te_missing / te_spec_missing / incompatible_checkpoint_arg / distributed_env_missing / port_conflict / shell_config_corrupt。对 unknown 类提取 traceback 最后一行关键信息。

### P2 — 不修也能跑，但体验差

**F8. 子进程错误日志丢失**：one-shot 子进程崩溃时日志文件经常没创建。修复：RUN_OUTPUT 为空但 exit code != 0 时查 dmesg。

**F10. .bashrc 污染检测**：preflight 检测 `bash -n ~/.bashrc` 语法错误。

**F11. verify 服务型验证**：依赖 F1。

**F12. cleanup 清理后台进程**：依赖 F4。

**F13. intake 项目类型推断**：依赖 F1。

**F14. setsid nohup 统一模板**：所有跨 cron 后台进程统一用 setsid nohup + sentinel。

### P3 — 历史遗留

**F15. CC/Hermes 双引擎互斥**：统一用 agent-heartbeat 或靠 crontab 注释/cron pause。

**F16. Hermes cron 续跑机制**：CC 版有 30min 续跑配额，Hermes 版没有。

**F17. outcomes 回填未验证**：MCP record_outcome 从未实际跑过。

**F18. validate-artifacts.sh 未写**：SKILL.md 引用了但不存在的脚本。

**F19. reconcile-state.sh / enforce-wallclock.sh 未验证**：preflight 调了但没测过。

**F20. 多模型策略未实现**：SKILL.md 提到但没做。

## 六、关键文件路径

| 文件 | 用途 |
|---|---|
| `.claude/CLAUDE.md` | CC 版主 agent 上下文（R1-R11 + 资源约束 + 工作流） |
| `.claude/skills/auto-daily/SKILL.md` | CC 版主编排 skill |
| `.claude/skills/{intake,fetch-weights,install-env,run-and-repair,verify,write-deploy-runbook,cleanup-deployed-workspace}/SKILL.md` | CC 版各阶段 skill |
| `AGENTS.md` | Hermes 版主 agent 上下文（symlink 自 hermes/AGENTS.md） |
| `hermes/skills/ai-auto-harness/SKILL.md` | Hermes 版主编排 skill |
| `hermes/scripts/phase-*.sh` | Hermes 版各阶段 bash 脚本（方案A：terminal 直跑） |
| `hermes/scripts/guard.env.sh` | Hermes 版 R-guard（bash 函数拦截） |
| `hermes/scripts/harness-preflight.sh` | Hermes 版 0-token 预检 |
| `cron/daily.sh` | CC 版 cron 入口（flock + 续跑 + bg_recheck） |
| `scripts/check-bg-downloads.sh` | 后台下载健康检查 |
| `scripts/reconcile-sentinels.sh` | sentinel 兜底修复 |
| `scripts/enforce-wallclock.sh` | wall-clock 超时强制暂停 |
| `workspace/<slug>/state.json` | 项目状态（phase × status 双轴） |
| `workspace/<slug>/results/<phase>.json` | 阶段结果 |
| `workspace/<slug>/logs/<phase>.log` | 阶段日志 |
| `docs/framework-improvements-for-cc.md` | 本文档的详细版（含代码示例和建议方案） |
| `docs/hermes-migration-gaps.md` | Hermes 迁移完善清单（12 项，大部分已完成） |

## 七、实现优先级建议

1. **先做 F2 + F3 + F10**（0.5 天 × 3 = 1.5 天）— 环境修复，所有项目受益
2. **再做 F1 + F13 + F11 + F12**（2 天）— 服务型推理全链路支持
3. **然后 F4 + F5 + F6 + F9**（2.5 天）— 依赖和错误处理增强
4. **最后 F7 + F8 + F14 + F15-F20**（2 天）— 效率和历史遗留

总计约 8 天工作量。

## 八、Khala 项目判定

Khala（Megatron 音乐生成）在当前环境下**无法跑通**，根因：
1. Transformer Engine 需从源码编译 CUDA kernel（PyPI 空包）
2. 6/8 GPU 被 vLLM 占满，单卡不够
3. 依赖链过深（Megatron → TE → Apex → pybind11 → six）

**建议**：intake 检测到 `from megatron` + 无 TE → `paused_for_human`，reason=`needs_preinstalled_te`。不在单机 cron 流水线中处理。

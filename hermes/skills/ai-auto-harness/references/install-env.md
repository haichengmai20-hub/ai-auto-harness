# install-env playbook(Hermes 子代理)

venv + pip + torch sm_12 检测/修复。

## 🔴 硬规则

- **前置(R5)**:`state.phases_done` 必须含 fetch-weights,否则 exit(下载与 pip 抢同一根管道)
- **R6 禁 `--no-cache-dir`**(PIP_CACHE_DIR 已隔离,加了反而重下;guard 会自动剥除并警告)
- **串行 pip**:同一 venv 严禁并行 pip(site-packages 元数据损坏);每条 pip foreground + tee 等完成
- **GPU 必检**:装完 torch 必须 `torch.cuda.is_available()`;False 绝不放行到 run 阶段

## 落盘

日志 `logs/install_env.log`;结果 `results/install.json` + `results/environment.json`。

## 第 0 步(每条 bash 前缀)

```bash
source /root/ai-auto-harness/hermes/scripts/guard.env.sh
LOG="$WORKSPACE/logs/install_env.log"
echo "=== PHASE_START phase=install-env slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ==="
```

R2:state `phase=installing, status=running`。

## 先读经验

```bash
ls /root/ai-auto-harness/memory/lessons/
cat /root/ai-auto-harness/memory/lessons/torch-sm12.md        # 装 torch 必读
cat /root/ai-auto-harness/memory/projects/$SLUG.md 2>/dev/null # 该项目历史经验
```

## 工作流

1. **venv**:`cd "$WORKSPACE" && python -m venv venv && source venv/bin/activate`(验证 which python 指向 workspace 内)
2. **核心工具**:`pip install --upgrade pip setuptools wheel 2>&1 | tee -a "$LOG"`
3. **项目依赖**(优先级:`pip install -e .` → `pip install -r requirements.txt` → README quickstart 逐条):
   - 长安装(编译类)用 setsid nohup 后台 + sentinel(同 fetch 模板,sentinel 名 `install-env-pip.json`,PID 记 `.cache/install_pip.pid`),poll ≤8 次,超了 paused_in_progress
   - 普通安装 foreground + tee 等完成
4. **torch sm_12 检测(5090 必做)**:
   ```bash
   python -c "import torch; archs=torch.cuda.get_arch_list(); ok=any('120' in a for a in archs); print(archs, ok); exit(0 if ok else 1)"
   ```
   不过 → 按 lessons/torch-sm12.md:卸载 torch 三件套 → 装 nightly cu128/cu124 → 重验。max 3 次,仍不行 → pending_human(torch_sm12_unavailable)
5. **常见 build 修复**:flash-attn → lessons/flash-attn-build.md 找 prebuilt wheel;bitsandbytes → 版本回退;缺 nvcc → 不 sudo apt,评估是否真需要;deepspeed/xformers → prebuilt
6. **import 验证 + P9 深度预检**(lazy import 的推理依赖必须现在扫出来,SCAIL 实测 flash_attn 缺失烧掉末轮修复):
   ```bash
   for dep in flash_attn xformers deepspeed accelerate diffusers transformers; do
       if grep -rq "import $dep\|from $dep" "$WORKSPACE/repo/" --include="*.py" 2>/dev/null; then
           python -c "import $dep" 2>/dev/null || pip install "$dep" 2>&1 | tee -a "$LOG" \
               || echo "[P9] $dep 装失败 → install.json.warnings += dep_install_failed: $dep" >> "$LOG"
       fi
   done
   ```
   装失败**不阻塞**本 phase,但必须写进 warnings 让 run 阶段知情
7. **写经验**:项目特有 → `memory/projects/<slug>.md` append;任何 5090 项目通用 → `memory/lessons/<topic>.md` append;琐碎微调 → 不写

## 落盘 + 返回

`results/environment.json`(venv_path/python/torch/cuda/torch_archs/sm_12_supported/captured_at)+ `results/install.json`:

```json
{"venv_path":"...","deps_ok":true,"fixes_applied":[...],"warnings":[...],"blocked":false,"completed_at":"..."}
```

🔴 两个 JSON 必须 bash heredoc 求值写(`$(date -Iseconds)` 等),**严禁文件写工具原样落模板**(hunyuan3d-2 实测落成字面量,validate-artifacts 会 FAIL)。
更新 state(`phase=running` / phases_done += install-env / install_result / status=done)+ PHASE_END。**summary 原样含 install.json 全文**。

## 反模式

- ❌ sudo pip / pip --user / 改 ~/.bashrc PATH
- ❌ 并行 pip;❌ fetch 没 done 就 pip;❌ 第 4 次重装 torch(必须 pending_human)
- ❌ cuda_available=False 还放行;❌ 不读 lessons 就硬装

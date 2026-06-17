---
name: install-env
description: venv + pip + torch sm_12 检测/修复 + 常见 build issue 处理
allowed-tools: [Read, Write, Edit, Bash, Grep]
agent: install-agent
---

# install-env

## 🔴 硬规则(必须遵守)

### 前置:fetch 必须完全 done 才能进 install(R5 串行带宽)

启动 install 前,**必须** 校验 `$WORKSPACE/state.json`:

```bash
PHASE=$(jq -r .phase "$WORKSPACE/state.json")
STATUS=$(jq -r .status "$WORKSPACE/state.json")
PHASES_DONE=$(jq -r '.phases_done // [] | .[]' "$WORKSPACE/state.json")

if ! echo "$PHASES_DONE" | grep -q "fetch-weights"; then
    echo "ERROR: fetch-weights 未完成,不能进 install-env (R5: 带宽串行)" >> "$LOG"
    exit 1
fi
```

**禁止** 在 fetch-weights 还在 background 跑时启动 pip install(2GB CUDA wheels 与 28GB 权重抢同一根管道,两边都慢一倍)。

### 禁止 `--no-cache-dir`

`launch_worker.sh` 已 env-level 把 `PIP_CACHE_DIR=$LOG_DIR/.cache/pip` 隔离,**已经不污染系统 cache**。再加 `--no-cache-dir` 反而每次都重下 wheel,慢 + 浪费带宽 + 抢 fetch 带宽。

```bash
# ❌ pip install torch --no-cache-dir
# ✅ pip install torch  # PIP_CACHE_DIR 已隔离,放心用 cache
```

### 串行 pip(禁止并行)

**Never run multiple pip installs for the same venv in parallel.**

错误做法:
```bash
pip install torch &
pip install transformers &
wait
# 同一 venv 并行写,site-packages 元数据损坏,某些包看似装上但 import 失败
```

正确做法:
```bash
pip install torch 2>&1 | tee -a "$LOG"          # 等完成
pip install transformers 2>&1 | tee -a "$LOG"   # 再下一个
pip install -r requirements.txt 2>&1 | tee -a "$LOG"
```

每个 pip 命令必须 **foreground + tee + 等完成**,再发下一个.

### GPU pre-flight(装完 torch 必做)

装完 torch 之后,**真用 GPU 前必须 verify**:

```bash
python -c "
import torch
print('cuda_available:', torch.cuda.is_available())
print('device_count:', torch.cuda.device_count())
print('capability:', torch.cuda.get_device_capability())
print('archs:', torch.cuda.get_arch_list())
" 2>&1 | tee -a "$LOG"
```

异常情况 → 第 4 步 sm_12 修复.若 `cuda_available=False` 就装错了,**绝不要**继续到 run-and-repair 让它在 CPU 上跑(GPU 利用率 0% verify 会 fail).

## 落盘约定(必读)

- **日志**:`$WORKSPACE/logs/install_env.log` — venv 创建 + pip install + sm_12 检测 + 修复尝试 全输出
- **结果**:`$WORKSPACE/results/install.json` — return schema
- **环境快照**:`$WORKSPACE/results/environment.json` — torch / cuda / python / sm_arch / venv 路径(便于后续诊断)

```bash
mkdir -p "$WORKSPACE/logs" "$WORKSPACE/results"
LOG="$WORKSPACE/logs/install_env.log"
echo "==== install-env start at $(date -Iseconds) ====" >> "$LOG"
echo "=== PHASE_START phase=install-env slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ==="

# 所有 bash 命令都用这个模式: cmd 2>&1 | tee -a "$LOG"
```

## 你的输入(主 agent 传入)

```json
{
  "slug": "<project-slug>",
  "workspace_path": "/root/ai-auto-harness/workspace/<slug>",
  "entry_script": "python -m flux t2i ...",
  "requirements_files": ["requirements.txt", "..."]
}
```

## 启动前先读 lessons(关键)

```bash
ls memory/lessons/
cat memory/lessons/torch-sm12.md       # 装 torch 必读
cat memory/lessons/flash-attn-build.md # 项目用 flash-attn 时读
cat memory/projects/<slug>.md          # 若该项目之前装过有经验
```

## 工作流

### 第 1 步:创建 venv

```bash
cd "$WORKSPACE"
python -m venv venv 2>&1 | tee -a "$LOG"
source venv/bin/activate
which python 2>&1 | tee -a "$LOG"  # 验证指向 workspace/<slug>/venv/bin/python
# F10: ~/.bashrc 若有语法错误,会在每次 source venv/activate 时吐两行错,污染日志+干扰错误检测。
# 检测到就本 phase 起 export BASH_ENV=/dev/null 绕过(只影响本 SubAgent,不改全局 .bashrc — R1)。
bash -n ~/.bashrc 2>/dev/null || { echo "[F10] ~/.bashrc 语法错误 → 本 phase export BASH_ENV=/dev/null 绕过" | tee -a "$LOG"; export BASH_ENV=/dev/null; }
```

### 第 2 步:升级核心工具

```bash
pip install --upgrade pip setuptools wheel 2>&1 | tee -a "$LOG"
```

### 第 3 步:装项目依赖

**pip 长任务必须后台 + 短 poll**(R4 防 sleep loop):

```bash
# 错:pip install -e . 2>&1 | tee -a "$LOG"  — 占住 foreground,LLM 只能 sleep 等
# 对:后台跑,LLM 下个 turn tail 判活,绝不连续 sleep
mkdir -p "$WORKSPACE/.cache/handoff"
SENTINEL="$WORKSPACE/.cache/handoff/install-env-pip.json"
setsid nohup bash -c "
  set +e
  STARTED_AT=\$(date -Iseconds)
  pip install -e . 2>&1
  RC=\$?
  echo PIP_EXIT=\$RC >> '$LOG'
  python3 -c 'import json,sys,time; path,rc,pid=sys.argv[1],int(sys.argv[2]),int(sys.argv[3]); json.dump({\"status\":\"done\" if rc==0 else \"failed\",\"slug\":\"'$SLUG'\",\"phase\":\"install-env\",\"pid\":pid,\"exit_code\":rc,\"started_at\":\"'\"\$STARTED_AT\"'\",\"completed_at\":time.strftime(\"%Y-%m-%dT%H:%M:%S%z\"),\"log_path\":\"'$WORKSPACE/logs/install_env.log'\"}, open(path,\"w\"), ensure_ascii=False, indent=2)' '$SENTINEL' \"\$RC\" \"\$BASHPID\"
  exit \$RC
" >> "$LOG" 2>&1 &
PIP_PID=$!
echo $PIP_PID > "$WORKSPACE/.cache/install_pip.pid"
```

后续 turn 用 `tail -50 $LOG` + `kill -0 $PIP_PID && echo alive` 判活,**禁止连续 sleep**(R4.2)。8 turn 没装完 → `paused_in_progress` return,主 agent 下次接续(R4.5)。

优先级(**注意:每次只跑一个 pip 命令,foreground + tee,等完成再下一个**):

```bash
cd "$WORKSPACE/repo"

# (a) 如果有 setup.py 或 pyproject.toml
if [ -f "setup.py" ] || [ -f "pyproject.toml" ]; then
    pip install -e . 2>&1 | tee -a "$LOG"
# (b) 否则 requirements.txt
elif [ -f "requirements.txt" ]; then
    pip install -r requirements.txt 2>&1 | tee -a "$LOG"
# (c) 否则看 README quickstart
else
    grep -A 5 "pip install" README.md | tee -a "$LOG"
    # 手抄出来执行,**一条一条来**,每条 2>&1 | tee -a "$LOG"
fi
```

**禁止**:`pip install A &; pip install B &; wait`(并行写同一 venv 损坏 site-packages)
**禁止**:把 pip 放 background(`run_in_background=true`)— pip 必须 foreground

记录用的方案 + 任何失败到 `$RUN_DIR/decisions.md`(`$RUN_DIR` = `${AI_HARNESS_RUN_DIR:-runs/$RUN_ID}`,slug 已知时即 `workspace/<slug>/runs/<id>/`)。

### 第 4 步:torch sm_12 检测(5090 必做)

```bash
python -c "import torch; archs = torch.cuda.get_arch_list(); print('archs:', archs); ok = any('120' in a or '12.0' in a for a in archs); print('sm_12_ok:', ok); exit(0 if ok else 1)" 2>&1 | tee -a "$LOG"
```

**不通过**:
1. 读 `memory/lessons/torch-sm12.md` 的方案 A
2. 卸载现 torch:`pip uninstall -y torch torchvision torchaudio`
3. 装 nightly cu124(方案 A):
   ```bash
   pip install --index-url https://download.pytorch.org/whl/nightly/cu124 \
       torch torchvision torchaudio
   ```
4. 重新验证 sm_12 是否在 list

最多 3 次重装尝试,仍不行 → `blocked.append("torch_sm12_unavailable")` 调 request-human-intervention.

### 第 5 步:常见 build issue 修复(read lessons + 应用)

逐个 stderr 排查常见模式:

- **flash-attn 装失败** → 看 `memory/lessons/flash-attn-build.md`,试 prebuilt wheel(方案 A)
- **bitsandbytes 不兼容** → 版本回退到匹配 torch 的(`pip install bitsandbytes==X.Y`)
- **缺 nvcc** → 不要 sudo apt 装,改:
  - 看是否项目真的需要 nvcc(只是编译时需要,推理时不一定)
  - 如不是必须,跳过该 dep
- **deepspeed / xformers 编译失败** → 同 flash-attn 思路找 prebuilt
- **typing-extensions 冲突** → `pip install --upgrade typing-extensions`

### 第 6 步:验证 entry_script 至少能 import

```bash
cd "$WORKSPACE/repo"
python -c "<from entry_script 推断的顶层 import,比如 import flux 或 from songgen import generate>" 2>&1 | head -20
```

失败 → 看 stderr 缺什么 module → pip install 补 → 重试

**import 深度预检 (P9 fix, 2026-06-11)**:仅验证顶层 import 不够，很多依赖（如 flash_attn、xformers、deepspeed）在推理时才被 lazy import。必须在 install-env 阶段主动扫描代码中 `import` 语句，对常见推理关键依赖做预检：

```bash
# 扫描 repo 中 import 的关键推理依赖（不在 requirements.txt 里也可能被代码引用）
COMMON_INFERENCE_DEPS="flash_attn xformers deepspeed accelerate diffusers transformers"
for dep in $COMMON_INFERENCE_DEPS; do
    if grep -rq "import $dep\|from $dep" "$WORKSPACE/repo/" --include="*.py" 2>/dev/null; then
        echo "[P9 precheck] 代码引用了 $dep，验证 import..." >> "$LOG"
        if ! python -c "import $dep" 2>/dev/null; then
            echo "[P9 precheck] $dep 缺失，尝试安装" >> "$LOG"
            pip install "$dep" 2>&1 | tee -a "$LOG" || echo "[P9 precheck] $dep 安装失败，记录到 warnings" >> "$LOG"
        fi
    fi
done
```

如果安装失败（如 flash-attn 需要编译），**不阻塞 install-env**，但在 `install.json.warnings` 加 `"dep_install_failed: <dep>"`，让 run-and-repair 知道这个依赖可能缺失。

### 第 6.5 步:apt 系统依赖检测(H3)

有些 Python 包(sox/librosa/pydub/av/cv2/pytesseract/pdf2image/wand)需要**系统级命令行工具**,`pip install` 只装 Python wrapper、**不装系统命令** → 运行时报 `sox not found` / `SoX could not be found` 之类(qwen3-tts 实测烧了一轮)。pip 装完后扫一遍 import,缺系统包就 `apt-get install`:

```bash
declare -A APT_DEPS=(
  ["sox"]="sox libsox-dev"
  ["pydub"]="ffmpeg"
  ["librosa"]="ffmpeg"
  ["soundfile"]="libsndfile1"
  ["av"]="ffmpeg libavcodec-dev libavformat-dev libavdevice-dev"
  ["cv2|opencv"]="libgl1-mesa-glx libglib2.0-0"
  ["pytesseract"]="tesseract-ocr"
  ["pdf2image"]="poppler-utils"
  ["wand"]="libmagickwand-dev"
)
for PY_MOD in "${!APT_DEPS[@]}"; do
  grep -rqE "import ${PY_MOD}|from ${PY_MOD}" "$WORKSPACE/repo/" --include="*.py" 2>/dev/null || continue
  PKGS="${APT_DEPS[$PY_MOD]}"; NEED=false
  for PKG in $PKGS; do dpkg -s "$PKG" &>/dev/null || { NEED=true; break; }; done
  [ "$NEED" = true ] || continue
  echo "[H3] $PY_MOD 需系统依赖,装: $PKGS" | tee -a "$LOG"
  apt-get install -y $PKGS 2>&1 | tail -3 | tee -a "$LOG" \
    || echo "[H3] apt 装 $PKGS 失败 → install.json.warnings 记 apt_install_failed:$PKGS" | tee -a "$LOG"
done
```

装失败**不阻塞**(同 P9),在 `install.json.warnings` 记 `apt_install_failed: <pkgs>`,run-and-repair 的 `system_dep_missing` 分类(F9)是运行期兜底。

### 第 7 步:写经验(lesson 写入机制)

修复成功后,**判断 3 问**(同 run-and-repair):

| 问题 | yes → 写哪里 |
|---|---|
| 修复是这个项目特有的(项目 own 的依赖 pin / 配置)? | `memory/projects/<slug>.md` 追加 |
| 修复方法任何 5090 项目都可能用上? | `memory/lessons/<topic>.md` 追加段落(append,不覆盖) |
| 都不是(只是版本微调)? | **不写**(noise) |

**项目专属经验例子**(写 projects/):

```markdown
# <slug> install 经验

- 用 nightly cu124 torch(项目 requirements pin torch==2.5,与默认 stable 不兼容)
- flash-attn 装的 2.7.4 prebuilt wheel(cu124 + torch 2.7 + abiFALSE + cp310)
- bitsandbytes 退到 0.43.x(与 torch 2.7 兼容)
- 项目自带 install.sh 用法:`bash install.sh --skip-flash-attn`
```

**通用经验例子**(写 lessons/):

- 5090 sm_12 → 改 `memory/lessons/torch-sm12.md`(若有新方案)
- 某新 build 工具失败的修复套路 → 新建 `memory/lessons/<topic>.md`

**已有 lesson append 格式**:看 `memory/lessons/torch-sm12.md` 末尾追加新章节,不要重写整个文件.

### 第 8 步:return 前落盘 results JSON + environment.json

```bash
# 环境快照 — 给 verify 和后续诊断用
# 先在 heredoc 外求值 bash 命令替换,再 export 进 python heredoc
export V_VENV_PATH="$WORKSPACE/venv"
export V_PYTHON_VER="$(python --version 2>&1)"
export V_PIP_VER="$(pip --version 2>&1)"
export V_TORCH_VER="$(python -c 'import torch; print(torch.__version__)' 2>&1)"
export V_CUDA_VER="$(python -c 'import torch; print(torch.version.cuda)' 2>&1)"
export V_TORCH_ARCHS="$(python -c 'import torch,json; print(json.dumps(torch.cuda.get_arch_list()))' 2>&1)"
export V_SM12="$(python -c 'import torch; print("true" if any("120" in a or "12.0" in a for a in torch.cuda.get_arch_list()) else "false")' 2>&1)"
export V_TIMESTAMP="$(date -Iseconds)"

python3 << 'PYEOF'
import json, os

venv_path = os.environ["V_VENV_PATH"]
python_ver = os.environ["V_PYTHON_VER"]
pip_ver = os.environ["V_PIP_VER"]
torch_ver = os.environ["V_TORCH_VER"]
cuda_ver = os.environ["V_CUDA_VER"]
torch_archs = json.loads(os.environ.get("V_TORCH_ARCHS", "[]"))
sm_12_supported = os.environ.get("V_SM12", "false") == "true"
timestamp = os.environ["V_TIMESTAMP"]

obj = {
    "venv_path": venv_path,
    "python": python_ver,
    "pip": pip_ver,
    "torch": torch_ver,
    "cuda": cuda_ver,
    "torch_archs": torch_archs,
    "sm_12_supported": sm_12_supported,
    "captured_at": timestamp
}
with open(os.environ.get("WORKSPACE", ".") + "/results/environment.json", "w") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PYEOF

# install 结果
export V_VENV_PATH2="$WORKSPACE/venv"
export V_DEPS_OK="<true|false>"
export V_FIXES_APPLIED="<json array string>"
export V_WARNINGS="<json array string>"
export V_BLOCKED="<true|false>"
export V_TIMESTAMP2="$(date -Iseconds)"

python3 << 'PYEOF'
import json, os

def env(key, default=None):
    val = os.environ.get(key, default)
    if val is None:
        return None
    if val == "null" or val == "":
        return None
    if val == "true":
        return True
    if val == "false":
        return False
    return val

venv_path = os.environ["V_VENV_PATH2"]
deps_ok = env("V_DEPS_OK") == True
fixes_applied = json.loads(env("V_FIXES_APPLIED") or "[]")
warnings = json.loads(env("V_WARNINGS") or "[]")
blocked = env("V_BLOCKED") == True
timestamp = os.environ["V_TIMESTAMP2"]

obj = {
    "venv_path": venv_path,
    "deps_ok": deps_ok,
    "fixes_applied": fixes_applied,
    "warnings": warnings,
    "blocked": blocked,
    "completed_at": timestamp
}
with open(os.environ.get("WORKSPACE", ".") + "/results/install.json", "w") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PYEOF

echo "==== install-env end at $(date -Iseconds) ====" >> "$LOG"
echo "=== PHASE_END   phase=install-env slug=$SLUG status=done ts=$(date -Iseconds) ==="
```

> 🔴 上面两个 heredoc **必须用 Bash 工具执行**(单引号 `'PYEOF'` 分隔符,`$(date)` / `$(python ...)` 在 heredoc 外的 export 行求值)。
> **绝不要把模板原文用 Write 工具直接写成 .json 文件** — 那样 `$(date -Iseconds)` / `<true|false>`
> 会变成字面量字符串落盘(hunyuan3d-2 实测翻车;`scripts/validate-artifacts.sh` 现在会 FAIL 这种值)。

## 返回 schema

```json
{
  "venv_path": "/root/ai-auto-harness/workspace/<slug>/venv",
  "deps_ok": true,
  "fixes_applied": ["torch_nightly_cu124", "flash_attn_prebuilt_wheel"],
  "warnings": ["bitsandbytes 退到 0.43.x"],
  "blocked": false
}
```

## 反模式

- ❌ `sudo pip install` / `pip install --user`(打破隔离)
- ❌ 卸载系统级 python / 改 ~/.bashrc 改 PATH
- ❌ 强装某个特定版本而没看 lessons(浪费时间)
- ❌ 第 4 次重装 torch 还没好 → 必须 raise pending_human
- ❌ 用 Write 工具把含 `$(date)` / `<占位符>` 的 JSON 模板原样写盘 — 时间戳必须经 Bash heredoc 求值或 `jq --arg ts "$(date -Iseconds)"` 注入
- ❌ **用 `<<JSON`(无引号 heredoc)** — bash 变量内插导致 `null` 泄漏(Python 看到 `null` 不是 `None`,json.loads() 崩)和引号截断(`$FIXES_APPLIED` 含引号时截断)。必须用 `<<'PYEOF'`(单引号不插值)+ `export` 传参 + `os.environ` 读参 + `if val == "null": val = None`

## ChangeLog

- **2026-06-17** — H1 heredoc null 泄漏修复:无引号 heredoc→单引号 + export/os.environ + null→None
  - 变更类型: 模板(heredoc 写法)+ 反模式
  - 影响范围: 第 8 步 environment.json + install.json 两个 heredoc 模板(从 `<<JSON` bash 内插改为 `<<'PYEOF'` python3 + export/os.environ + null→None 转换;`$(python --version)` 等命令替换在 heredoc 外 export 行求值)/ 反模式段新增无引号 heredoc 禁令
  - 动机: `<<JSON` 无引号 heredoc 让 bash 内插 `$FAILED_AT_VAL=null` → Python 看到 `null`(不是 `None`),`$FIXES_APPLIED` 含引号时截断,`json.loads()` 崩溃。Hermes 版已修,CC 版 SKILL.md 同步
  - 证据: Hermes 版修法见 `hermes/scripts/phase-install.sh`;CC 版同步
  - 验证: 模板 bash -n 合规;grep `<<JSON` 无残留

- **2026-06-16** — H3 apt 系统依赖检测 + F10 .bashrc 污染绕过(CC 同步,batch #2)
  - 变更类型: 流程(新增第 6.5 步 + 第 1 步 F10 检测)
  - 影响范围: 第 1 步(`bash -n ~/.bashrc` 失败→`BASH_ENV=/dev/null`)/ 新增第 6.5 步(9 组 Python↔apt 映射,缺系统命令则 apt 装,失败记 warnings 不阻塞)
  - 动机: qwen3-tts 实测 `pip install sox` 只装 wrapper,系统 `sox` 命令缺失→运行期才炸(H3);.bashrc 第 139 行语法错误污染每条 bash 输出(F10)。Hermes 6d 已有,CC 同步
  - 证据: [fixes/2026-06-16-cc-batch2-h3-f7-f8-f10-fix.md](../../../docs/superpowers/fixes/2026-06-16-cc-batch2-h3-f7-f8-f10-fix.md)
  - 验证: SKILL 自查(映射与 Hermes 6d 一致;装失败不阻塞走 warnings)

- **2026-06-10** — 时间戳/占位符字面量防呆
  - 变更类型: 反模式 + 验证
  - 影响范围: 第 8 步落盘块注意事项 / 反模式段 / `scripts/validate-artifacts.sh`(通用字面量扫描)
  - 动机: hunyuan3d-2 的 install.json `completed_at` 落成 `$(date -Iseconds)` 字面量 — 模板被 Write 工具原样写盘而非 Bash 求值
  - 证据: [fixes/2026-05-29-completed-at-literal-not-evaluated-fix.md](../../../docs/superpowers/fixes/2026-05-29-completed-at-literal-not-evaluated-fix.md)
  - 验证: ✅ validate-artifacts.sh fixture 双向测试(坏值 FAIL / 干净 PASS)
- **2026-06-04** — pip 长任务写 handoff sentinel
  - 变更类型: 流程 / schema
  - 影响范围: 第 3 步后台 pip wrapper
  - 动机: 长任务退出后需要由 SessionStart/SessionEnd hook 发现和交接,不能只靠即将离开的观察者 poll
  - 证据: [fixes/2026-05-29-polling-handoff-mechanism-fix.md](../../../docs/superpowers/fixes/2026-05-29-polling-handoff-mechanism-fix.md)
  - 验证: ⬜ 待验证(handoff sentinel fixture)
- **2026-06-11** — import 深度预检(P9)
  - 变更类型: 流程
  - 影响范围: 第 6 步后新增预检块
  - 动机: SCAIL 实测 — wan 分支代码 import flash_attn 但 requirements.txt 没列,run 阶段才炸,烧掉最后一轮修复;lazy import 的推理依赖必须 install 阶段扫出来
  - 证据: specs/2026-06-11-试跑复盘与验证清单.md(P9)

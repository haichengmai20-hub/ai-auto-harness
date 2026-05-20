---
name: install-env
description: venv + pip + torch sm_12 检测/修复 + 常见 build issue 处理
allowed-tools: [Read, Write, Edit, Bash, Grep]
agent: install-agent
---

# install-env

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
python -m venv venv
source venv/bin/activate
which python  # 验证指向 workspace/<slug>/venv/bin/python
```

### 第 2 步:升级核心工具

```bash
pip install --upgrade pip setuptools wheel
```

### 第 3 步:装项目依赖

优先级:

```bash
cd "$WORKSPACE/repo"

# (a) 如果有 setup.py 或 pyproject.toml
if [ -f "setup.py" ] || [ -f "pyproject.toml" ]; then
    pip install -e .
# (b) 否则 requirements.txt
elif [ -f "requirements.txt" ]; then
    pip install -r requirements.txt
# (c) 否则看 README quickstart
else
    # 读 README.md 找 pip install 命令
    grep -A 5 "pip install" README.md
    # 手抄出来执行
fi
```

记录用的方案 + 任何失败到 decisions.md.

### 第 4 步:torch sm_12 检测(5090 必做)

```bash
python -c "import torch; archs = torch.cuda.get_arch_list(); print('archs:', archs); ok = any('120' in a or '12.0' in a for a in archs); print('sm_12_ok:', ok); exit(0 if ok else 1)"
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

# torch sm_12 兼容性(RTX 5090)

> 这是 ai-auto-harness 平台的通用经验文件,任何 SubAgent 在装 torch 或跑模型遇到 NaN/inf 时都可读本文件做参考。

## 现象

- pip install torch 装完跑模型,推理输出 **NaN / inf / 全 0** / 重复无意义 token
- 或者 `python -c "import torch; print(torch.cuda.get_arch_list())"` 输出不含 `sm_120` / `compute_120`
- 或者跑 `torch.randn(8, 8, device='cuda') @ torch.randn(8, 8, device='cuda')` 结果是 NaN

## 根因

RTX 5090 是 sm_12.0(compute capability 12.0),许多 stable 版 torch wheel **没编译 sm_12 内核**。

- 默认 `pip install torch`(stable channel)装的 cu121 wheel 通常编到 sm_90 / sm_100
- 没 sm_12 → CUDA runtime 找不到匹配的 kernel,但不会报错,只会跑出错误的数值(NaN/全 0)

## 验证当前 torch 是否支持 sm_12

```bash
python -c "import torch; archs = torch.cuda.get_arch_list(); print(archs); print('sm_12 ok:', any('120' in a or '12.0' in a for a in archs))"
```

期望输出含 `sm_120` 或 `compute_120`,且 "sm_12 ok: True"。

## 修复方案(按优先级)

### 方案 A:nightly cu124 wheel(推荐,验证有效)

```bash
pip uninstall -y torch torchvision torchaudio
pip install --index-url https://download.pytorch.org/whl/nightly/cu124 \
    torch torchvision torchaudio
# 再次验证
python -c "import torch; print(torch.cuda.get_arch_list())"
```

### 方案 B:cu126 stable wheel(2026-Q1 起,若已发布)

```bash
pip uninstall -y torch
pip install --index-url https://download.pytorch.org/whl/cu126 torch
```

### 方案 C:源码编译(最后手段,慢,约 2-4 小时)

```bash
TORCH_CUDA_ARCH_LIST="12.0" pip install torch --no-binary torch
```

## 完整 smoke test

```python
import torch
assert torch.cuda.is_available(), "no CUDA"
archs = torch.cuda.get_arch_list()
assert any("120" in a or "12.0" in a for a in archs), f"sm_12 not in {archs}"
x = torch.randn(128, 128, device='cuda')
y = torch.randn(128, 128, device='cuda')
z = x @ y
assert torch.isfinite(z).all(), "got NaN/Inf — likely sm_12 unsupported"
print("torch sm_12 OK, mean=", z.mean().item())
```

## 已知踩坑

- **某些项目 `requirements.txt` pin 了旧 torch 版本**(如 `torch==2.1.0`)—— 必须先按本 lesson 修 torch,再做 pip install -e .,否则 deps 会装错
- **如果项目用了 flash-attn**:它也要重编,见 `flash-attn-build.md`

## 踩坑追加:requirements.txt pin torch == 2.6.0+cu126(SongGen run2,2026-05-21)

**现象**:`requirements.txt` 第一行 `torch==2.6.0`(cu126)。装完 verify 时 `torch.cuda.is_available() == False` 或 `get_arch_list()` 不含 sm_120。

**踩坑路径**(LLM 来回卷):
1. 先 `pip install -r requirements.txt` 装 torch==2.6.0 cu126 → 不支持 sm_12
2. 卸了装 nightly cu124 → OK
3. 又 `pip install -r requirements.txt` 让其他 deps 起来 → **torch 被 requirements 降回 2.6.0,sm_12 又没了**
4. 反复卷,浪费 ~$5 + 1h

**正确做法**(intake / install-env 必须做):

```bash
# 1. 把 requirements.txt 里的 torch / torchvision / torchaudio 行抽出来另存
grep -E "^(torch|torchvision|torchaudio)([=<>!~]|$)" requirements.txt > /tmp/torch_pins.txt
sed -i -E "/^(torch|torchvision|torchaudio)([=<>!~]|$)/d" requirements.txt

# 2. 装其他 deps(不含 torch pin)
pip install -r requirements.txt 2>&1 | tee -a "$LOG"

# 3. 单独装 nightly torch(本 lesson 方案 A)
pip install --index-url https://download.pytorch.org/whl/nightly/cu124 \
    torch torchvision torchaudio 2>&1 | tee -a "$LOG"

# 4. verify sm_12
python -c "import torch; assert any('120' in a or '12.0' in a for a in torch.cuda.get_arch_list())"
```

**注意**:第 1 步要恢复 requirements.txt 让项目自身的 setup.py 能引用(可在 install 完后 `git checkout requirements.txt`)。

## 踩坑追加:torch nightly 拉 numpy>=2,与 requirements.txt 的 numpy<2 冲突(SongGen run2)

**现象**:装 torch nightly 后再 `pip install -r requirements.txt`,**numpy 被降级 2.4.4 → 1.26.4**。某些 torch nightly build 的 cython 扩展 require numpy>=2 → 运行时报 `ImportError: numpy.core.multiarray failed to import`。

**正确做法**:

```bash
# 装完所有 deps 后,显式拉回 numpy>=2
pip install -U "numpy>=2.0,<3.0"

# 或在 requirements.txt 已 pin numpy<2 的情况下,加 --force-reinstall
pip install --upgrade --force-reinstall numpy>=2.0
```

**判定该不该升 numpy**:

```bash
python -c "
import torch, numpy
# 看 torch 的 C 扩展能不能 import — 这才是真验证
try:
    torch.empty(1, device='cpu').numpy()
    print('OK')
except ImportError as e:
    print('NUMPY ABI MISMATCH:', e)
    print('numpy:', numpy.__version__, 'torch:', torch.__version__)
"
```

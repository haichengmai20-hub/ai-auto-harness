# flash-attn 编译失败

> 通用经验:install-env 或 run-and-repair 阶段遇到 flash-attn 安装问题都读本文件。

## 现象

- `pip install flash-attn` 编译几十分钟后失败
- 常见错误:
  - `nvcc not found` — 缺 CUDA toolkit
  - `unsupported gpu_arch sm_120` — 5090 sm 不支持
  - `RuntimeError: CUDA out of memory` (build 时编译占大量显存)
  - `error: Microsoft Visual C++ ...` — 错误平台
  - OOM kill (build 进程被 killed)

## 修复方案(按优先级)

### 方案 A:prebuilt wheel(推荐,几乎一定工作)

```bash
# 找匹配 torch / python / cuda 版本的 wheel
# https://github.com/Dao-AILab/flash-attention/releases
# 例:python 3.10 + torch 2.7 + cu124 + abiFALSE
wget https://github.com/Dao-AILab/flash-attention/releases/download/v2.7.4/flash_attn-2.7.4+cu124torch2.7cxx11abiFALSE-cp310-cp310-linux_x86_64.whl

pip install flash_attn-2.7.4+cu124torch2.7cxx11abiFALSE-cp310-cp310-linux_x86_64.whl
```

**关键**:wheel 文件名必须匹配你装的:
- python 版本(cp310 = python3.10,cp311 = 3.11)
- torch 版本(看 `pip show torch | grep Version`)
- CUDA 版本(看 `nvidia-smi` Driver Version 行 + torch 编时的 cuda)
- abi(`torch.compiled_with_cxx11_abi()` → True 用 abiTRUE,否则 abiFALSE)

### 方案 B:容忍缺 flash-attn 跑慢

许多项目支持 fallback 到 PyTorch native attention(慢 2-5x 但能跑)。

读项目 README / config 看有没有 `--no-flash-attn` 之类的 flag,或者改代码:

```python
# 找到 from flash_attn import ... 的地方,改成
try:
    from flash_attn import flash_attn_func
except ImportError:
    flash_attn_func = None  # 让代码走 fallback path

# 然后 inference loop 里:
if flash_attn_func is not None:
    out = flash_attn_func(q, k, v)
else:
    out = torch.nn.functional.scaled_dot_product_attention(q, k, v)
```

### 方案 C:容忍 sm_12 不支持 — 退到旧版 flash-attn

flash-attn v2.x 对 sm_12 的支持还在迭代。若 v2.7 不行,退到 v2.5:

```bash
pip install flash-attn==2.5.8 --no-build-isolation
```

性能略差但能跑.

### 方案 D:**绝对不要**做的

- ❌ 不要从源码 build flash-attn(`pip install flash-attn --no-binary flash-attn`)— 慢、易 OOM、且 sm_12 没编也徒劳
- ❌ 不要 sudo apt install cuda-toolkit 全装一遍(80GB 磁盘 + 5090 sm 仍可能不被该版本支持)

## 智能选择

```bash
PYTHON_VER=$(python -c "import sys; print(f'cp{sys.version_info.major}{sys.version_info.minor}')")
TORCH_VER=$(python -c "import torch; print('.'.join(torch.__version__.split('.')[:2]))")  # e.g. "2.7"
CUDA_VER=$(python -c "import torch; print(torch.version.cuda)" | tr -d '.')  # e.g. "124"
ABI=$(python -c "import torch; print('TRUE' if torch.compiled_with_cxx11_abi() else 'FALSE')")

# 装时构造合适的 wheel URL
echo "需要 wheel: flash_attn-X.Y.Z+cu${CUDA_VER}torch${TORCH_VER}cxx11abi${ABI}-${PYTHON_VER}-${PYTHON_VER}-linux_x86_64.whl"
```

## 注意

- 不装 flash-attn **通常推理慢 2-5x**,但**不是必须**
- 若 entry_script 直接死在 `from flash_attn import ...` import error → 找代码改 try/except fallback,**绝不要**为了能 import 而强装

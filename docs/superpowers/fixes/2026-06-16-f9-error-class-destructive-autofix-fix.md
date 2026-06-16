# Fix: F9 错误分类自动修复会毁 entry_script 源码

**日期**: 2026-06-16
**严重度**: P0（数据破坏：3/7 个新分类的自动修复会损坏被部署项目的 Python 入口文件）
**触发**: 审查上一轮 `be54e47`(Q4/Q5/F9/F2/P3)实现时发现
**关联**: [framework-issues-cc-complete.md](../../framework-issues-cc-complete.md) F9；[framework-improvements-for-cc.md](../../framework-improvements-for-cc.md) F6/F9

---

## 问题

`be54e47` 给 `hermes/scripts/phase-run-and-repair.sh` 加了 7 种新错误分类。其中 3 种用 `sed -i` 往 **Python 入口文件**里塞 Megatron CLI flag —— 根因误判：以为 entry 是「带 argv 的命令行」，实际是 `python3 entry.py`。结果不是修复而是**毁文件**：

| 分类 | 原实现 | 后果 |
|---|---|---|
| `incompatible_checkpoint_arg` | `sed 's/\(args\|argparse\|sys.argv\)/# Added compatibility flags\n/g'` | 把文件里每个 `args`/`argparse`/`sys.argv` token 全替换成注释，整脚本报废；而且根本没加上声称的 flag。**正是 framework-improvements F6 警告过的「sed 替换 argparse 可能破坏脚本」** |
| `te_spec_missing` | `sed 's/\(transformer.*impl\)/--transformer-impl local /g'` | 往 Python 源码插 CLI flag = SyntaxError；正则乱匹配任意含该串的行 |
| `port_conflict` | `sed "s/$CONFLICT_PORT/$NEW_PORT/g"` | 全局替换那个数字，误伤 batch_size/维度等任何等于该端口号的地方 |

另外两个非毁灭但有缺陷：

| 分类 | 缺陷 |
|---|---|
| `te_missing` | `pip install transformer-engine[pytorch]` —— PyPI 的 TE 是空 meta 包，需源码编译 CUDA kernel(>10min)。安装失败后下一轮同错再装，最多空跑 20 轮 pip(framework-improvements 自己的 Khala 复盘已点明 TE 装不上) |
| `distributed_env_missing` | prepend `import os...` 到文件头，破坏 shebang / `from __future__` / 编码声明；且用共享 `/tmp/entry_tmp.py`(并发竞争) |

salvageable：`shell_config_corrupt`(✅)、`system_dep_missing`(✅，仅 SoX/sox 大小写重复的无害小瑕疵)。

## 根因

「修复」假设 entry 是可追加 flag 的 CLI 调用。但 run-and-repair 的执行模型是 `timeout python3 "$ENTRY_FILE"` —— 一个 Python 源文件。对它做盲 `sed` 注入 CLI 参数在语义上不可能正确，只会破坏文件。Megatron 类的 `--transformer-impl local` / `--no-persist-layer-norm` 是**启动命令层**的参数，不是 Python 源码层能 sed 进去的东西。

## 方案

按「能不能安全自动修」分两档：

- **可安全自动修（保留/加固，走环境变量不动源码）**：
  - `distributed_env_missing` → 在 **shell** 里 `export MASTER_ADDR/MASTER_PORT/RANK/WORLD_SIZE/LOCAL_RANK`（被 `timeout python3` 子进程继承），不再 prepend 文件；加 `DIST_ENV_SET` once-guard，二次仍失败转人工
  - `port_conflict` → `export MASTER_PORT=<random high>` 重试（不 sed 源码）；`PORT_RETRY` once-guard，二次转人工
  - `te_missing` → 仅尝试一次 pip（`TE_INSTALL_TRIED` guard），仍缺则转人工并给「需源码编译」诊断
  - `system_dep_missing` / `shell_config_corrupt` → 不动（本就安全）
- **不能安全自动修（下调为分类+诊断+转人工，绝不动源码）**：
  - `te_spec_missing` / `incompatible_checkpoint_arg` → 设 `ERROR_CLASS` + 写精确 `SUGGESTED_FIX`(建议在启动命令处加哪些 flag) + `NEEDS_HUMAN` + `break`

落盘补 `error_class` / `suggested_fix` 字段，`NEEDS_HUMAN` 时强制 `paused_for_human=true` + `state.status=paused_for_human`（不再误推进到 verify）。

## 影响范围

- `hermes/scripts/phase-run-and-repair.sh`：F9 五个分类重写 + 落盘补字段
- CC 版同步时**只移植安全集**，三个毁灭性 sed 绝不进 CC

## 验证

| 场景 | 预期 |
|---|---|
| `bash -n` 语法 | 通过 |
| 构造 `incompatible_checkpoint_arg` 输出 | entry_script **零改动**（diff 为空），分类→paused_for_human + suggested_fix |
| 构造 `MASTER_ADDR not set` | shell 设了 MASTER_ADDR，entry_script 不变 |
| 构造 `Address already in use` | MASTER_PORT 改 env，entry_script 不变 |
| te_missing 两轮 | 第 1 轮装 1 次，第 2 轮转人工不再 pip |

## 状态

- [x] 审查发现 + fix.md
- [x] phase-run-and-repair.sh 重写五分类(te_missing once-guard / te_spec+incompatible_ckpt 下调转人工 / distributed+port 走 env var)
- [x] bash -n + 毁文件回归测试(5 分类全 entry=UNCHANGED;前三类转人工;distributed/port 设 MASTER_ADDR/PORT)
- [x] 更新 framework-issues-cc-complete.md F9 状态注记 + fixes/README 索引
- [ ] commit + 回填 hash
- [ ] (跟进,非本 fix) 行 221 paddle_onednn prepend 同样有 shebang/__future__ 破坏 + 共享 /tmp 竞争风险

## 修复结果

- **commit hash**: (待回填)

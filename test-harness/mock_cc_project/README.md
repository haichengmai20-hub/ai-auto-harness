# Mock CC Project (for Qwen API + CC Harness)

这是一个用于兼容性测试的虚假小项目，目标是让你快速验证以下能力：

- 读取上下文并理解项目结构
- 修改代码并保持风格一致
- 运行测试并修复失败
- 生成可追踪的变更说明

## 项目结构

- `src/order_calc.py`: 订单计算核心逻辑
- `src/text_utils.py`: 文本清洗与格式化
- `src/report.py`: 报表生成
- `tests/test_order_calc.py`: 单元测试
- `data/sample_orders.json`: 示例输入数据
- `TASKS.md`: 建议喂给 Harness 的测试任务

## 快速开始

```bash
cd /home/ps/dcr/claudecode/claudecode_sourcecode1/test-harness/mock_cc_project
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
pytest -q
```

## 运行示例

```bash
python -m src.report
```

该命令会读取 `data/sample_orders.json`，并输出汇总信息。

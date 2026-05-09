# Suggested Harness Tasks

你可以将下面任务作为兼容性测试输入，逐条验证 Qwen API 接入后的行为一致性。

## Task 1: 读代码并解释

请解释 `src/order_calc.py` 的 `calculate_order_total` 逻辑，并给出边界条件。

## Task 2: 修改代码

为 `calculate_order_total` 增加参数 `round_to=2`，用于控制最终金额的小数位。

## Task 3: 补测试

为 `round_to=0` 和 `round_to=3` 增加单元测试。

## Task 4: 数据清洗

增强 `src/text_utils.py`：

- 将连续空白压缩为单个空格
- 保留中文和英文标点
- 去掉首尾空白

## Task 5: 生成说明

总结改动点，并列出涉及文件与测试结果。

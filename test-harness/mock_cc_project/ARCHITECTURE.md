# Architecture — mock_cc_project

## 目录结构

```
mock_cc_project/
├── data/
│   └── sample_orders.json       # 订单样本数据（2 条）
├── src/
│   ├── __init__.py              # 空包标记
│   ├── order_calc.py            # 订单计算核心模块
│   ├── text_utils.py            # 文本清洗工具
│   ├── report.py                # 报表入口（CLI 可执行）
│   ├── unrelated_guard.py       # 误改检测守卫文件
│   └── refactor_case/           # HTTP 客户端迁移案例
│       ├── api_client_a.py      # 用户画像接口
│       ├── api_client_b.py      # 商品列表接口
│       ├── api_client_c.py      # 健康检查接口
│       └── non_target_mentions.py  # 误改检测文件
└── tests/
    └── test_order_calc.py       # 订单计算单元测试
```

## 模块职责

### order_calc.py — 订单计算核心

| 函数 | 输入 | 输出 | 说明 |
|------|------|------|------|
| `apply_coupon` | amount, coupon | float | 优惠码折扣（SAVE10 → 9 折, SAVE20 → 8 折） |
| `calculate_order_total` | order dict | float | 汇总 items 价格 × 数量，再应用优惠码 |
| `summarize_totals` | orders list | dict | 统计 count / sum / avg / max |
| `layer2_broken_func` | — | str | 测试用占位函数 |

### text_utils.py — 文本清洗

| 函数 | 输入 | 输出 | 说明 |
|------|------|------|------|
| `clean_title` | text | str | 合并连续空白为单空格并 strip |

### report.py — 报表入口

从 `data/sample_orders.json` 加载订单 → 调用 `summarize_totals` 汇总 → 调用 `clean_title` 清洗标题 → 打印结果。可 `python -m src.report` 直接运行。

### refactor_case/ — HTTP 客户端（已迁移至 httpx）

| 文件 | 函数 | HTTP 方法 | 特殊参数 |
|------|------|-----------|----------|
| api_client_a.py | `fetch_profile` | GET | headers, timeout=10 |
| api_client_b.py | `fetch_items` | GET | params, timeout=8 |
| api_client_c.py | `fetch_status` | GET | timeout=5 |

### unrelated_guard.py — 误改守卫

常量 `FLAG = "DO_NOT_EDIT"`, `VALUE = 42`。用于验证工具不会误改无关文件。

### non_target_mentions.py — 误改检测

包含字符串和注释中的 `requests` 引用（`"pip install requests"` 等），用于验证重构工具不会误改非目标位置。

## 数据流

```
sample_orders.json
        │
        ▼
   load_orders()  ←── report.py
        │
        ▼
   calculate_order_total()  ←── order_calc.py
        │
        ▼
   apply_coupon()
        │
        ▼
   summarize_totals()
        │
        ▼
   clean_title()  ←── text_utils.py
        │
        ▼
     print()
```

## 依赖关系

```
report.py ──→ order_calc.py
          ──→ text_utils.py
```

`refactor_case/` 和 `unrelated_guard.py` 无内部依赖，各自独立。

## 外部依赖

| 包 | 使用模块 | 用途 |
|----|----------|------|
| httpx | refactor_case/api_client_*.py | HTTP GET 请求（已从 requests 迁移） |
| re | text_utils.py | 正则空白匹配 |
| json / pathlib | report.py | 数据文件读取 |

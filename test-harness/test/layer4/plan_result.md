# test-harness 目录总结

test-harness 是 Claude Code 的功能测试框架，包含三部分：

1. **启动脚本与工具**：harness 启动（start_harness.sh）、代理配置（start_proxy_deepseek.sh）、Web 栈检查（check_web_stack.sh）、Python 工具（disturb.py, test.py）
2. **mock_cc_project**：模拟 Python 项目，用于测试 CC 的代码读写和重构能力；含 src/（order_calc, text_utils, refactor_case 重复代码重构用例）、tests/、data/
3. **分层测试套件**：
   - layer1：基础虚拟化测试（Jupyter notebook）
   - layer3：初始化与记忆会话测试（init_sandbox, memory_session）
   - layer4：多 Agent 任务编排与 worktree 隔离测试（agent_tasks, preflight, task_scripts, worktree_sandbox）

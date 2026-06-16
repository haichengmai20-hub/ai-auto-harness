# Fix: 服务型推理支持(entry_type=service)

**日期**: 2026-06-16
**严重度**: P0(最大架构缺口,服务型项目全挂)
**触发**: khala/vLLM/Gradio/Flask 类项目跑不通(只认 python3 script.py)
**Spec**: [2026-06-16-service-type-inference-design.md](../specs/2026-06-16-service-type-inference-design.md)
**关联**: framework-issues-cc-complete.md F1/F4/F11/F12/F13/F14

## 人话版
平台原来只会跑「一条命令出结果」的脚本。很多 AI 项目得先把后端服务起起来、等它就绪、再发请求拿结果、最后关掉。这次让四个阶段都认识「服务型」项目:intake 把启动/就绪/请求/停止四件事写清楚,run 真跑一遍往返,verify 独立再验一遍,cleanup/preflight 保证服务不会变成占着 GPU 的孤儿。

## 三决策(brainstorm)
1. 真实推理往返(降级 verify_level L0=仅就绪 / L1=真往返)
2. intake 全包 descriptor(run 只执行,请求错=普通修复轮)
3. ephemeral within-run(必停、不跨 cron;孤儿靠 reconcile 兜底)

## 影响范围
- 新增 `scripts/service-lifecycle.sh`(start/wait-ready/stop,可测)
- `.claude/skills/{intake,run-and-repair,verify,cleanup-deployed-workspace}/SKILL.md`
- `scripts/reconcile-sentinels.sh`(孤儿回收)

## 验证
见 spec「成功标准/验证」表 + 各任务 fixture。

## 状态
- [ ] T2 helper + fixture
- [ ] T3 intake / T4 run / T5 verify / T6 cleanup
- [ ] T7 reconcile 孤儿回收
- [ ] T8 治理 + 回填
- [ ] 实战:一个真实服务型项目走完 L1

## 修复结果
- **commit hash**: (待回填)

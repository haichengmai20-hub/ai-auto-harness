# Layer 4 前置检查清单

执行 Layer 4 前，逐项打钩：

- [ ] 已在仓库根目录启动可用的 harness 会话
- [ ] 当前会话执行过 /clear
- [ ] 当前目录可写
- [ ] git 仓库可用（用于 4.7）
- [ ] 不在生产目录执行实验命令
- [ ] 已确认 4.8 若不支持 cron 则记为 N/A

建议命令：

- pwd
- git rev-parse --is-inside-work-tree
- ls -la test-harness/test/layer4

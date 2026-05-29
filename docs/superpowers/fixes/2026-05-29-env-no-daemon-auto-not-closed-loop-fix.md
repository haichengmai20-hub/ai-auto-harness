# 环境无 daemon,自动化从未闭环 — cron / supervisord / init 全缺

## 元信息

- **Fix ID**: `2026-05-29-env-no-daemon-auto-not-closed-loop-fix`
- **创建日期**: 2026-05-29(回填自 2026-05-26 分析)
- **级别**: P0(自动化基础设施缺失,所有 cron-driven 设计形同虚设)
- **状态**: 进行中(环境问题,需运维层改动)
- **负责人 / session**: 用户实测发现 + Claude session @ 2026-05-29 回填

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | hunyuan3d-2(首发);全项目共用 |
| **触发 run_id** | `runs/` 下无任何 `cron-*` 目录(证据) |
| **触发时间** | 2026-05-19(项目立项)至今 |
| **触发阶段** | ops / 全阶段 |
| **workspace 路径** | N/A(环境级) |
| **runs 路径** | N/A |

---

## 现象

- 现象 1: 当前环境 PID 1 是 `tail -f /dev/null`(站桩占位进程),不是 systemd/init
  - 证据: `cat /proc/1/cmdline | tr '\0' ' '` → `tail -f /dev/null`
- 现象 2: `crontab` / `cron` / `crond` 命令不存在,无 cron 守护进程
  - 证据: `which crontab cron crond 2>/dev/null` → 空
- 现象 3: supervisord 已安装(`/home/ubuntu/miniconda3/bin/supervisord`)但**未运行**
  - 证据: `ps aux | grep supervisord | grep -v grep` → 空
- 现象 4: `runs/` 下**无任何 `cron-*` 目录**,所有 run 的 trigger 全是手动(`/auto-deploy`、`/auto-recover`)
  - 证据: `find runs/ -maxdepth 1 -name "cron-*"` → 空;各 `runs/*/meta.json` 的 `trigger` 字段
- 现象 5: ai-daily-scan 的"cron 定时驱动"只存在于设计文档,从未在这台机器上运行

---

## 触发条件 / 复现步骤

1. 任何需要 cron 自动触发的场景(每日 10:30 auto-daily、auto-recover 自动接续)
2. 当前环境:无 cron → `cron/daily.sh` 永远不会被自动触发
3. 只能靠人手动跑 `/auto-daily` 或 `/auto-recover`
4. 人不在时,所有自动化逻辑处于休眠状态

---

## 影响

- **影响范围**: 平台所有自动化能力(定时扫描 / 自动接续 / 定时清理)
- **影响下游**: auto-daily 的 cron 触发、auto-recover 的自动接续、cleanup 的定时磁盘回收——全部失效
- **严重程度**: P0 — 设计文档里的"cron-driven"在当前环境从未真正接通;所有"自动化"实为"半自动化(需人触发)"

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > 容器构建时 PID 1 设为 `tail -f /dev/null`(保活容器但不跑任何服务),没有安装/启动 cron,没有启动 supervisord。设计文档假设了 cron 存在,但环境从未满足这个前提。这是基础设施/运维层问题,不是代码 bug。

---

## 修复方案

> 三档方案,见 `workspace/hunyuan3d-2/results/2026-05-26-polling-handoff-analysis.md` §4。

### 设计层修改

- [ ] (第 1 档,MVP)不依赖 daemon,靠 SessionStart/End hook 自愈 — 见 [2026-05-29-polling-handoff-mechanism-fix.md](2026-05-29-polling-handoff-mechanism-fix.md) ①②
- [ ] (第 2 档,加固)`apt install cron` + 手动启动 crond + `crontab -e` 加 `30 10 * * * /root/ai-auto-harness/cron/daily.sh`;或启动 supervisord 托管看门狗
- [ ] (第 3 档,根治)改容器 entrypoint 为 `supervisord`,开机自起 + 保活 cron/看门狗
- [ ] `.claude/CLAUDE.md` 加环境前提声明:列出"本平台需要 cron 或等效 daemon"

### 实现层修改

- [ ] (第 2 档)`apt install cron && systemctl start cron`(或 `service cron start`);加 crontab 条目
- [ ] (第 2 档)启动 supervisord:写 `supervisord.conf` + `/home/ubuntu/miniconda3/bin/supervisord -c supervisord.conf`
- [ ] (第 3 档)改 Dockerfile/容器启动配置,设 `ENTRYPOINT ["/home/ubuntu/miniconda3/bin/supervisord", "-c", "/root/ai-auto-harness/supervisord.conf"]`

### 文档层修改

- [ ] 在设计文档中标注环境前提:需要 cron 或 supervisord
- [ ] 在 README 加"环境要求"段

---

## 验证步骤

1. **第 2 档验证**:
   ```bash
   # 装 cron 后
   crontab -l  # 期望看到 daily.sh 条目
   sudo service cron status  # 期望 active
   # 等 10:30 或手动触发,看 runs/ 下是否出现 cron-* 目录
   ```
2. **第 3 档验证**:容器重启后 `ps aux | grep supervisord` 应有结果,看门狗自动运行

---

## 修复结果

- **状态**: ❌ 未落地(MVP 方案见关联 fix,环境层改动待运维执行)
- **验证证据**: 环境现状如"现象"段 5 条证据
- **commit hash**: 待落地

---

## 证据指针

- 环境证据: `cat /proc/1/cmdline`; `which crontab`; `ps aux | grep supervisord`
- runs 证据: `find runs/ -maxdepth 1 -name "cron-*"` → 空
- 设计假设: `.claude/skills/auto-daily/SKILL.md`(假设 cron 10:30 触发)
- 实际触发: 各 `runs/*/meta.json` 的 `trigger` 字段(全是手动)

---

## 关联

- **关联 fix**: [2026-05-29-polling-handoff-mechanism-fix.md](2026-05-29-polling-handoff-mechanism-fix.md)(交接机制断裂是本问题的直接后果)
- **关联 fix**: [2026-05-19-cron-driven-architecture-fix.md](2026-05-19-cron-driven-architecture-fix.md)(架构假设 cron 存在的前提)
- **关联分析**: `workspace/hunyuan3d-2/results/2026-05-26-polling-handoff-analysis.md` §5

---

## 后续动作

- [ ] **spec/plan ChangeLog 已加** → ⬜ 待加
- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 是(环境前提声明是通用教训)
- [ ] **是否需要 L1 / L2 重测验证** → 是(cron 装通后验证 `runs/` 下出现 cron-* 目录)
- [ ] **是否需要写 pending_human** → 是(第 3 档改 entrypoint 需运维权限决策)

---
name: auto-status
description: 看 workspace / pending_human / recent reports — 不跑 agent,只读状态
---

显示当前平台状态:

1. **In-progress 项目**(workspace 中尚未 done 的)
   ```bash
   find workspace -maxdepth 2 -name state.json -exec jq -c '{slug, phase, phases_done, updated_at}' {} \; 2>/dev/null
   ```

2. **待人手处理积压**
   ```bash
   ls pending_human/*.md 2>/dev/null
   ```

3. **最近 5 份报告**
   ```bash
   ls -t reports/*.md 2>/dev/null | head -5
   ```

4. **GPU 状况**
   ```bash
   nvidia-smi --query-gpu=index,memory.used,memory.free --format=csv,noheader
   ```

5. **磁盘 free**
   ```bash
   df -h /root | tail -1
   ```

用 1-2 句话给用户做总结(状态是 idle 还是有积压等)。

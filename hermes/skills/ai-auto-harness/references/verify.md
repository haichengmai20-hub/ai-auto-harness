# verify playbook(Hermes 子代理)

独立判定项目是否真能跑。**只判定,不修**。

## 🔴 独立性原则

- 你的输入**不含** run_result/修复历史;**禁止**读 state.json 的 `run_result` 字段(不被修复历史污染)
- 任何失败 → 记 evidence 后返回 false,**不重试不修**(装依赖是 install 的事,修代码是 runner 的事)

## 落盘

日志 `logs/verify.log`;结果 `results/verify.json`。只用 bash 写文件(tee/heredoc)。

## 第 0 步(每条 bash 前缀)

```bash
source /root/ai-auto-harness/hermes/scripts/guard.env.sh
source "$VENV_PATH/bin/activate"
export HF_HOME="$WORKSPACE/.cache/huggingface"
echo "=== PHASE_START phase=verify slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ==="
```

## 三步判定

1. **启动检查**:`cd "$WORKSPACE/repo" && $ENTRY_SCRIPT --help`(或顶层 import)。exit≠0 → `passed=false, failed_at="startup"`,停
2. **smoke test**:README 里最小 demo 命令,`timeout 600` 跑;GPU 用 `jq -r '.intake_result.gpu_picks[0]' state.json`(不读 run_result)。输出合理性判定:文本=连贯非重复;图像=大小合理非纯色;视频=ffprobe 有 stream;音频=采样率/时长合理。失败 → `failed_at="smoke_test"`
3. **GPU 利用率**:`nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader -l 2 | head -10`。判定:mem >1GB 且至少一次 util >10%。否则 `failed_at="gpu_utilization"`(CPU fallback = 没部署对,**严格 fail,出了文件也不算过**)

**L1 内容级抽查**(环境有现成工具才做,不为 L1 新装包):TTS→ASR 回环比对;3D→trimesh 面数>1000;图像→像素方差/CLIP;文本→语义相关。做了且过 → `verify_level="L1"`;只做 3 步 → `"L0"`;L1 失败 → `passed=false, failed_at="content_check"`。

## 落盘(🔴 7 字段 schema,严禁自创)

下游 cleanup G4 / 报告用 `jq -r '.passed'` 读,字段缺失 = 下游误判(hunyuan3d-2/omnivoice 实测自创 {status,checks} 翻车)。**必须且只许**这 7 个根字段:

```bash
bash -c "cat > '$WORKSPACE/results/verify.json' <<JSON
{
  \"passed\": true,
  \"failed_at\": null,
  \"evidence\": {\"startup_exit_code\": 0, \"smoke_stdout_snippet\": \"...\", \"smoke_exit_code\": 0,
                \"gpu_stats\": {\"memory_used_mb\": 0, \"utilization_pct\": 0}, \"output_files\": []},
  \"notes\": \"一句话判定说明\",
  \"confidence\": \"high\",
  \"verify_level\": \"L0\",
  \"completed_at\": \"$(date -Iseconds)\"
}
JSON"
# 写完立即自检:
for f in passed failed_at evidence notes confidence verify_level completed_at; do
    jq -e --arg k "$f" 'has($k)' "$WORKSPACE/results/verify.json" >/dev/null || { echo "FATAL 缺字段 $f"; exit 1; }
done
jq -e '.passed | type == "boolean"' "$WORKSPACE/results/verify.json" >/dev/null || { echo "FATAL passed 必须 boolean"; exit 1; }
```

- passed 必须 boolean(不许 "true" 字符串,不许 null — 不确定就 false + failed_at)
- passed=true 时 failed_at 为 JSON null;false 时为 "startup"|"smoke_test"|"gpu_utilization"|"content_check"

decisions.md append 一行判定;PHASE_END 标记。**summary 原样含 verify.json 全文**。

## 反模式

- ❌ 自创 schema({status,verdict,checks}…);❌ passed 写字符串/null
- ❌ smoke fail 改 config 重跑(你不修);❌ GPU 0% 但出了文件就算过
- ❌ 读 run_result 看人家怎么修的

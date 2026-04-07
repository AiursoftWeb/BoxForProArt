# vLLM 部署与调优实战指南 (MoE 架构优化版)

本指南针对 `Qwen3.5-35B-A3B` 这种 **MoE (Mixture of Experts)** 架构，在双卡 RTX 3090 (48GB) 非对称显存环境下的极限部署提供 SOP。

---

## 1. 核心纠错：MoE 架构的显存真相
*   **权重体积**：35B 的 **AWQ (4-bit)** 量化版本权重约 **18GB**。
*   **KV Cache 特性**：由于是 `A3B`（激活 3B），其 KV 缓存需求极小。
    *   **32K 上下文** 仅占用约 **2.68GB**。
    *   **结论**：在剩余 28GB 的对称可用空间内，**完全不需要压缩 KV 缓存**，可以直接跑满 **32K 上下文**，且保持原生 FP16/BF16 精度以确保输出质量。

---

## 2. 明日实战：双卡 RTX 3090 (48GB) 极限部署策略

### 2.1 业务约束与显存精算
*   **约束**：GPU 0 已被 RAG/TTS 占用 10GB（剩余 14GB）。
*   **对称死锁**：vLLM 张量并行 (`--tensor-parallel-size 2`) 强制镜像。
*   **可用池**：$14\text{GB} \times 2 = 28\text{GB}$。
*   **分配比例**：$28\text{GB} / 48\text{GB} \approx 0.58$。为留出系统 Buffer，建议设为 **0.56**。

### 2.2 部署命令 (针对最佳性能的 AWQ 格式)
**推荐方案**：下载 `Qwen/Qwen3.5-35B-A3B-Instruct-AWQ` 以获得 vLLM 原生硬件加速。

```bash
sudo docker run -d --name vllm-35b-moe \
  --restart always \
  --gpus all \
  --ipc=host \
  -v /swarm-vol/ai/vllm/root:/root/.cache/huggingface \
  -p 8000:8000 \
  -e HF_ENDPOINT=https://hf-mirror.com \
  hub.aiursoft.com/vllm/vllm-openai:latest \
  Qwen/Qwen3.5-35B-A3B-Instruct-AWQ \
  --tensor-parallel-size 2 \
  --max-model-len 32768 \
  --gpu-memory-utilization 0.56 \
  --enforce-eager \
  --trust-remote-code \
  --enable-prefix-caching
```

### 2.3 备选方案：部署 GGUF 格式 (Q4_0/Q4_K_M)
如果手里只有 GGUF 文件，需指定模型文件路径：

```bash
# 假设模型文件在 /root/.cache/huggingface/qwen35.gguf
sudo docker run -d --name vllm-35b-gguf \
  --restart always \
  --gpus all \
  --ipc=host \
  -v /swarm-vol/ai/vllm/root:/root/.cache/huggingface \
  -p 8000:8000 \
  hub.aiursoft.com/vllm/vllm-openai:latest \
  --model /root/.cache/huggingface/qwen35.gguf \
  --tokenizer Qwen/Qwen3.5-35B-A3B-Instruct \
  --tensor-parallel-size 2 \
  --max-model-len 32768 \
  --gpu-memory-utilization 0.56 \
  --enforce-eager
```

### 2.4 参数深度解析
1.  **`--ipc=host`**：彻底解决多卡并行时 NCCL 库在容器内共享内存不足导致的崩溃，比手动指定 `shm-size` 更稳。
2.  **`--max-model-len 32768`**：MoE 架构福利。即便显存剩余不多，也能从容处理 32K 文本，无需阉割。
3.  **取消 `--kv-cache-dtype fp8`**：显存绰绰有余（约 8GB 空闲），不开启 FP8 压缩以保留最高推理精度。
4.  **`--gpu-memory-utilization 0.56`**：精准避让 GPU 0 上预留给 RAG/TTS 的 10GB 空间。

---

## 3. 架构预警：何时该切回 Ollama？

*   **场景**：如果需要处理 **128K 以上** 的超长上下文，或者 GPU 0 的预留空间进一步被挤压到不足 12GB。
*   **策略**：切回 Ollama 开启 **非对称分层**。Ollama 能把两张卡剩下的显存拼凑在一起使用（14GB + 24GB = 38GB），而 vLLM 只能浪费掉那 10GB 的差异。

---

## 4. 4090 (24GB) 单卡经验
*   **9B BF16**：完美运行。
*   **35B AWQ**：单卡极其吃力，建议仅在双卡环境下使用张量并行部署。

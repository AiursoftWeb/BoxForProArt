# vLLM 部署与调优指南 (从 Ollama 迁移)

vLLM 是一个高性能、低延迟的 LLM 推理引擎。与 Ollama 不同，vLLM 的绝大部分调优是通过启动命令（CLI Flags）完成的，而不是环境变量。

## 1. 核心参数对比 (Ollama vs vLLM)

如果你习惯了 Ollama 的环境变量，下表可以帮助你快速定位 vLLM 的对应设置：

| 功能描述 | Ollama 环境变量 | vLLM 命令行参数 | 推荐值 (RTX 4090) |
| :--- | :--- | :--- | :--- |
| **上下文长度** | `OLLAMA_NUM_CTX` | `--max-model-len` | `4096` 或 `8192` |
| **显存占用率** | N/A | `--gpu-memory-utilization` | `0.8` (留 20% 给桌面/系统) |
| **并发请求数** | `OLLAMA_NUM_PARALLEL` | `--max-num-seqs` | `256` (vLLM 处理并发极强) |
| **对话缓存** | N/A | `--enable-prefix-caching` | `True` (长对话大幅提速) |
| **模型常驻** | `OLLAMA_KEEP_ALIVE` | (默认常驻) | 不需要额外设置 |
| **Flash Attention**| `OLLAMA_FLASH_ATTENTION`| (默认开启) | 不需要额外设置 |

---

## 2. Docker Compose 集成示例

建议在你的 `docker-compose.yml` 中按照以下方式添加 vLLM 服务，替换原本的 `ollama-server`：

```yaml
services:
  vllm-server:
    image: hub.aiursoft.com/vllm/vllm-openai:latest
    volumes:
      - /swarm-vol/ai/vllm/root:/root/.cache/huggingface
    ports:
      - "8000:8000"
    restart: always
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    # 所有的调优参数都写在 command 里
    command: >
      Qwen/Qwen3.5-9B
      --max-model-len 4096
      --gpu-memory-utilization 0.8
      --enable-prefix-caching
      --trust-remote-code
      --max-num-seqs 256
      --reasoning-parser qwen3
```

---

## 3. 进阶调优参数说明

- **`--gpu-memory-utilization`**: 
  - **作用**：控制 vLLM 预分配显存的比例。
  - **建议**：在有显卡驱动桌面环境（如 Gnome）的机器上，建议设置为 `0.8`。如果纯服务器环境，可设为 `0.9` 或 `0.95`。
- **`--max-model-len`**: 
  - **作用**：限制模型处理的最大 Token 总量。
  - **注意**：显存占用 = 模型权重 + (上下文长度 * 并发数)。如果 OOM，优先调小这个值。
- **`--enable-prefix-caching`**: 
  - **作用**：开启前缀缓存。
  - **场景**：在多轮对话中，前面的聊天记录会被缓存，后续回复不再需要重复计算，首字延迟（TTFT）极低。
- **`--kv-cache-dtype`**: 
  - **作用**：设置 KV 缓存的数据类型（如 `fp8`）。
  - **建议**：如果显存非常吃紧，设置为 `fp8` 可以节省近一半的 KV 缓存显存，但精度有微小损失。

---

## 4. 如何通过 OpenAI API 调用

vLLM 提供完全兼容 OpenAI 的接口，Base URL 为 `http://localhost:8000/v1`。

### Python 示例
```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8000/v1", api_key="EMPTY")

response = client.chat.completions.create(
    model="Qwen/Qwen3.5-9B",
    messages=[{"role": "user", "content": "你好，请自我介绍"}]
)
print(response.choices[0].message.content)
```

### Curl 示例
```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3.5-9B",
    "messages": [{"role": "user", "content": "1+1=?"}]
  }'
```

---

## 5. 常见问题排查

1. **CUDA Out of Memory**: 检查是否还有其他容器（如 Ollama）占用显存。使用 `nvidia-smi` 查看。
2. **模型下载慢**: 确保挂载了 `/swarm-vol/ai/vllm/root` 卷，这样模型只需下载一次。
3. **Open WebUI 连接**: 在 Open WebUI 中，将 `OLLAMA_BASE_URL` 替换为 vLLM 的地址，或者添加新的 OpenAI 模型提供商地址 `http://vllm-server:8000/v1`。

#!/bin/sh
# Expire mutable APT metadata, including legacy extensionless-file directories.
# Keep immutable by-hash entries and the package pool cached.

log() {
    # 打印带时间戳的日志信息
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log "开始执行 APT 元数据清理任务..."

# --- 新增网络检查 ---
HOSTNAME_TO_CHECK="archive.ubuntu.com"
log "正在检查网络连接: $HOSTNAME_TO_CHECK..."

# 使用 ping 命令检查网络连通性
# -c 1: 只发送1个ICMP数据包
# -W 5: 设置超时时间为5秒
if ! ping -c 1 -W 5 "$HOSTNAME_TO_CHECK" > /dev/null 2>&1; then
    log "错误: 无法连接到 $HOSTNAME_TO_CHECK。请检查网络连接。"
    log "清理任务已取消。"
    exit 1
else
    log "网络连接正常，继续执行清理。"
fi
# --- 网络检查结束 ---

CACHE_PATH="/data/ubuntu/dists"

if [ ! -d "$CACHE_PATH" ]; then
    log "缓存目录 $CACHE_PATH 不存在，跳过清理。"
    exit 0
fi

# Expire both new files and old directory/index.html cache entries. Prune
# matching directories so their contents are not visited again. by-hash URLs
# identify immutable content and must survive metadata refreshes.
entries_to_delete=$(find "$CACHE_PATH" -mindepth 2 \
    -type d -name "by-hash" -prune -o \
    \( -type f -o -type d \) \
    \( -name "InRelease" -o -name "Release" -o -name "Release.gpg" \
       -o -name "Packages*" -o -name "Sources*" -o -name "Contents-*" \
       -o -name "Translation-*" -o -name "Commands-*" \
       -o -name "Components-*.yml*" -o -name "icons-*.tar*" \) \
    -print -prune) || exit 1

# 检查是否有需要删除的目录
if [ -z "$entries_to_delete" ]; then
    log "没有找到需要清理的元数据。"
else
    # 在循环外部计算目录数量，避免在 subshell 中计数导致的问题
    # `grep -c .` 会计算非空行的数量，比 `wc -l` 更健壮
    deleted_count=$(printf '%s\n' "$entries_to_delete" | grep -c .)

    log "准备清理 ${deleted_count} 个元数据缓存条目:"
    
    # 循环遍历并删除每个找到的目录
    printf '%s\n' "$entries_to_delete" | while IFS= read -r entry; do
        if [ -n "$entry" ]; then
            log "  => 正在删除缓存: $entry"
            rm -rf -- "$entry" || exit 1
        fi
    done || exit 1

    log "汇总：总共清理了 ${deleted_count} 个元数据缓存条目。"
fi

log "清理任务完成。"

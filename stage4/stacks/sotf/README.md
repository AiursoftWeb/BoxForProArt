# 🌲 Sons of the Forest (森林之子) 私服运维指南

## 📂 核心目录结构

| 目录 | 说明 |
|---|---|
| `/swarm-vol/gaming/sotf-data/game` | 游戏本体文件（SteamCMD 下载） |
| `/swarm-vol/gaming/sotf-data/userdata` | 存档与配置文件 |
| `/swarm-vol/gaming/sotf-data/steamcmd` | SteamCMD 缓存 |
| `/mnt/backup` | 自动备份目录 |

## 🚀 首次部署流程

### 1. 启动容器（下载游戏本体）

容器首次启动后，SteamCMD 会自动下载约 15GB 的游戏本体。

```bash
# 确保数据目录存在且权限正确
sudo mkdir -p /swarm-vol/gaming/sotf-data/{userdata,game,steamcmd}
sudo chmod 777 -R /swarm-vol/gaming/

# 部署（deploy.sh 会自动完成此步骤）
# 或手动：
cd /path/to/BoxForProart
sudo bash deploy.sh --stage 4 --filter sotf
```

监控下载进度：
```bash
docker service logs -f sotf_sotf-server
```

### 2. 修改配置文件

等待游戏下载完毕并首次初始化后，`dedicatedserver.cfg` 会自动生成在 `/swarm-vol/gaming/sotf-data/userdata/` 下。

```bash
# 停掉服务
docker service scale sotf_sotf-server=0

# 编辑配置
vim /swarm-vol/gaming/sotf-data/userdata/dedicatedserver.cfg
```

核心配置项（JSON 格式）：

```json
{
  "IpAddress": "0.0.0.0",
  "GamePort": 8766,
  "QueryPort": 27016,
  "BlobSyncPort": 9700,
  "ServerName": "你的服务器名称",
  "MaxPlayers": 8,
  "Password": "你的密码",
  "LanOnly": false,
  "SaveSlot": 1,
  "SaveMode": "Continue",
  "GameMode": "Hard",
  "SaveInterval": 600,
  "IdleKickTime": 600,
  "SteamNetworkState": "open"
}
```

### 3. 配置管理员权限

将你的 **17位 Steam ID** 写入白名单文件：

```bash
echo "你的17位SteamID" > /swarm-vol/gaming/sotf-data/userdata/ownerswhitelist.txt
```

### 4. 重新启动

```bash
docker service scale sotf_sotf-server=1
```

## ⚙️ 难度说明

当前已配置为 **Hard（硬核生存）** 模式：

- 物资极度匮乏，行李箱不刷新
- 野人血厚攻高，频繁大规模进攻
- 生存惩罚拉满（饥饿、口渴、寒冷）

可选难度值：`Hard` / `Normal` / `Peaceful` / `Custom`

## 🛡️ 网络与端口

全部为 **UDP** 流量，已通过 FRP 隧道穿透到公网：

| 端口 | 用途 |
|---|---|
| `8766/UDP` | Game Port |
| `27016/UDP` | Query Port |
| `9700/UDP` | Blob Sync Port |

> ⚠️ 如有云服务商安全组，需同步放行这三个 UDP 端口。

## 🔄 常用操作

```bash
# 查看实时日志
docker service logs -f sotf_sotf-server

# 重启服务（会自动触发 SteamCMD 更新）
docker service update --force sotf_sotf-server

# 停止服务
docker service scale sotf_sotf-server=0

# 启动服务
docker service scale sotf_sotf-server=1
```

## 💾 自动备份

Crontab 每天凌晨 **04:00 UTC** 自动备份：

```bash
# 查看当前 crontab
crontab -l

# 手动添加（如 deploy.sh 未设置）
(crontab -l 2>/dev/null; echo '0 4 * * * tar -czf /mnt/backup/sotf_gaming_$(date +\%Y\%m\%d).tar.gz -C / swarm-vol/gaming >> /var/log/sotf_backup.log 2>&1') | crontab -
```

备份产物位于 `/mnt/backup/sotf_gaming_YYYYMMDD.tar.gz`，日志见 `/var/log/sotf_backup.log`。

## 🎮 客户端加入方式

1. 打开《森林之子》→ **多人游戏 (Multiplayer)** → **加入 (Join)**
2. 来源 (Source) 切换为 **"专用 (Dedicated)"**
3. 筛选器中搜索你设置的 `ServerName`
4. 输入密码加入

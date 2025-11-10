# README｜离线部署 LibreChat + Ollama + MCP Gateway（Windows + PowerShell 7.5.4）

> 所有出现的 **PATH** 都是占位符。请改成你的真实绝对路径，例如 `D:\AI\stack\final`。未替换会导致失败。

## 一、快速方式

* 直接打开仓库内的 **《一键配置.ps1》**，设置ROOT PATH。
* 使用 **PowerShell 7.5.4** 打开终端。直接运行《一键配置.ps1》。
* 执行完成后访问 `http://localhost:3080`。
* 如需手动方式或排错参考本 README。

## 二、环境要求

* Windows 10 或 11。启用虚拟化。
* Docker Desktop 可用。Compose v2 可用。
* PowerShell **7.5.4**。终端命令为 `pwsh`。
* 端口空闲：`3080` `11434` `8080`。
* 离线镜像包与 `.ollama` 模型包已就绪。

### 检查与升级 PowerShell 7.5.4

```powershell
$PSVersionTable.PSVersion
```

若版本不是 7.5.4

* 在线升级

```powershell
winget install --id Microsoft.PowerShell -v 7.5.4 --source winget
```

* 离线升级
  在联网机器下载对应架构安装包复制到目标机后本地安装。安装后用 `pwsh` 启动。

## 三、目录结构

脚本会自动创建以下目录。根目录使用占位符 **PATH**。

```
PATH
├─ conf
├─ volumes
│  ├─ workspace
│  ├─ mongo
│  ├─ ollama
│  └─ image_cache
└─ docker-compose.yml
```

请将 **PATH** 全部替换为你的真实路径。

## 四、离线资源准备

### 容器镜像 tar 包

在联网机器执行拉取与导出后复制到 `PATH\volumes\image_cache`。推荐文件名如下。

```
mongo_7.tar
ollama_latest.tar
mcp-gateway_latest.tar
librechat_v0.8.0-rc4.tar
```

示例命令仅用于联网机器。

```powershell
docker pull mongo:7
docker pull ollama/ollama:latest
docker pull docker/mcp-gateway:latest
docker pull ghcr.io/danny-avila/librechat:v0.8.0-rc4

docker save mongo:7 -o mongo_7.tar
docker save ollama/ollama:latest -o ollama_latest.tar
docker save docker/mcp-gateway:latest -o mcp-gateway_latest.tar
docker save ghcr.io/danny-avila/librechat:v0.8.0-rc4 -o librechat_v0.8.0-rc4.tar
```

### 模型包

将所需 `.ollama` 文件放入 `PATH\volumes\image_cache`。支持任意命名。常见示例如下。

```
qwen3_8b.ollama
qwen3_latest.ollama
gemma3_4b.ollama
gemma3_latest.ollama
```

## 五、手动启动方式（可选）

可下载脚本 `一键部署.ps1` 并手动执行。
执行前将脚本中的

```powershell
$Root="PATH"
```

替换为你的真实路径。用 PowerShell 7.5.4 运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\bringup.ps1
```

脚本要点

* 仅清理本栈容器与默认网络。
* 写入 `conf\librechat.yaml` 与 `conf\mcp-gateway.yaml`。
* 只使用离线镜像。缺失会报错并列出文件名。
* 自动导入 `image_cache` 下所有 `.ollama` 并预热首个可用模型。
* 生成两份摘要与日志

  * `PATH\volumes\workspace\mcp_tools_summary.txt`
  * `PATH\volumes\workspace\mcp_init_logs.txt`

## 六、就绪判据

打开 Docker Desktop 查看 `librechat` 日志。**必须等到出现两行 MCP 就绪日志后再使用工具**。

```
2025-11-05 18:17:58 info: [MCP][docker-mcp-gateway] Capabilities: {"logging":{},"prompts":{"listChanged":true},"resources":{"subscribe":true,"listChanged":true},"tools":{"listChanged":true}}
2025-11-05 18:17:58 info: [MCP][docker-mcp-gateway] Tools:
```

时间可能较长。属正常现象。

## 七、首次验证

优先使用 Invoke-RestMethod。不要用 curl。

```powershell
# 模型列表
Invoke-RestMethod -Uri "http://localhost:11434/v1/models" -Method GET

# 简单对话
$body = @{ model = "<你的模型名>"; messages = @(@{ role="user"; content="ok" }) } | ConvertTo-Json -Depth 5
Invoke-RestMethod -Uri "http://localhost:11434/v1/chat/completions" -Method POST -ContentType "application/json" -Body $body

# 访问 UI
# 浏览器打开
http://localhost:3080
```

## 八、常用运维

```powershell
docker ps
docker logs librechat --since 10m
docker compose -f PATH\docker-compose.yml down
docker compose -f PATH\docker-compose.yml up -d
```

请将 **PATH** 替换为你的真实路径。

## 九、常见问题

* 缺少离线镜像
  将缺失的 tar 放入 `PATH\volumes\image_cache` 后重试。
* Mongo 未就绪
  检查磁盘权限与杀毒软件与端口占用。
* 模型列表为空
  确认 `.ollama` 是否在 `image_cache` 并查看 `ollama` 日志。
* 界面可访问但无工具
  等待出现两行 MCP 就绪日志。
* 端口冲突
  修改 `docker-compose.yml` 中 `3080` `11434` `8080` 的映射后重启。
* 代理干扰
  脚本已清空代理环境变量。若系统仍有代理请加入白名单。

## 十、安全与参数

* 修改 `JWT_SECRET` `JWT_REFRESH_SECRET` `SESSION_SECRET` 避免示例值进入生产。
* 关闭注册
  `ALLOW_REGISTRATION=false`。
* Agents 默认模型
  `AGENTS_DEFAULT_MODEL` 应与已导入模型一致。
* 路径占位
  确保所有 **PATH** 已替换为真实路径。

本 README 仅提醒可以直接使用已存在的 **《一键配置.md》** 完成一键配置与部署。手动方式仅用于排错和定制。

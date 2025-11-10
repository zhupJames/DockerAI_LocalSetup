# PowerShell 7.5.4
# Please fill out the $Root
$ErrorActionPreference = 'Stop'

# ===== 0) 路径 =====
$Root=""
$Conf=Join-Path $Root "conf"
$Vols=Join-Path $Root "volumes"
$WS  =Join-Path $Vols "workspace"
$VolMongo = Join-Path $Vols "mongo"
$VolOllama= Join-Path $Vols "ollama"
$Lcy=Join-Path $Conf "librechat.yaml"
$ComposePath=Join-Path $Root "docker-compose.yml"
$AuthJson=Join-Path $Conf "auth.json"
$McpCfg=Join-Path $Conf "mcp-gateway.yaml"
$Cache=Join-Path $Vols "image_cache"
$enc=New-Object System.Text.UTF8Encoding($false)
New-Item -Force -ItemType Directory $Conf,$Vols,$WS,$VolMongo,$VolOllama,$Cache | Out-Null
if(-not (Test-Path $AuthJson)){ '{}' | Out-File -Encoding utf8NoBOM $AuthJson }

# ===== 1) 清理仅本栈容器与网络 =====
"librechat","ollama","mongo","mcp-gateway" | %{
  $id=(docker ps -aq -f "name=^$_$") 2>$null; if($id){ docker rm -f $id | Out-Null }
}
try{ docker network rm libre-local_default | Out-Null }catch{}

# ===== 2) 写 docker-compose（移除 --servers 名称式配置，改用 YAML 提供）=====
$ConfY  = $Conf      -replace "'","''"
$WSY    = $WS        -replace "'","''"
$VolMY  = $VolMongo  -replace "'","''"
$VolOY  = $VolOllama -replace "'","''"
$AuthY  = $AuthJson  -replace "'","''"
$McpCfgY= $McpCfg    -replace "'","''"
$CacheY = $Cache     -replace "'","''"

$compose=@"
name: libre-local
services:
  mongo:
    container_name: mongo
    image: mongo:7
    restart: unless-stopped
    healthcheck:
      test: ["CMD","mongosh","--eval","db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 12
    volumes:
      - type: bind
        source: '$VolMY'
        target: /data/db

  ollama:
    container_name: ollama
    image: ollama/ollama:latest
    restart: unless-stopped
    ports: ["11434:11434"]
    volumes:
      - type: bind
        source: '$VolOY'
        target: /root/.ollama
      - type: bind
        source: '$CacheY'
        target: /cache

  mcp-gateway:
    container_name: mcp-gateway
    image: docker/mcp-gateway:latest
    command:
      - --transport=streaming
      - --port=8080
      - --config=/conf/mcp-gateway.yaml
      - --watch
    restart: unless-stopped
    ports: ["8080:8080"]
    volumes:
      - type: bind
        source: '$ConfY'
        target: /conf
      - type: bind
        source: '$WSY'
        target: /workspace
      - /var/run/docker.sock:/var/run/docker.sock

  librechat:
    container_name: librechat
    image: ghcr.io/danny-avila/librechat:v0.8.0
    restart: unless-stopped
    depends_on:
      mongo: { condition: service_healthy }
      mcp-gateway: { condition: service_started }
      ollama: { condition: service_started }
    ports: ["3080:3080"]
    environment:
      CONFIG_PATH: "/app/conf/librechat.yaml"
      JWT_SECRET: "test1"
      JWT_REFRESH_SECRET: "test2"
      SESSION_SECRET: "test3"
      CREDS_KEY: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      CREDS_IV:  "0123456789abcdef0123456789abcdef"
      ALLOW_EMAIL_LOGIN: "true"
      ALLOW_REGISTRATION: "true"
      ALLOW_SOCIAL_LOGIN: "false"
      MONGO_URI: "mongodb://mongo:27017/librechat"
      NO_PROXY: "ollama,localhost,127.0.0.1,::1,host.docker.internal,mcp-gateway"
      no_proxy: "ollama,localhost,127.0.0.1,::1,host.docker.internal,mcp-gateway"
      HTTP_PROXY: ""
      HTTPS_PROXY: ""
      http_proxy: ""
      https_proxy: ""
      DISABLE_AGENTS: "false"
    volumes:
      - type: bind
        source: '$ConfY'
        target: /app/conf
        read_only: true
      - type: bind
        source: '$WSY'
        target: /workspace
      - type: bind
        source: '$AuthY'
        target: /app/api/data/auth.json
        read_only: true
"@
[IO.File]::WriteAllText($ComposePath,$compose,$enc)
docker compose -f $ComposePath config | Out-Null

# ===== 2.1) 先写空的网关 YAML（稍后覆盖为仅本地可用镜像）=====
[IO.File]::WriteAllText($McpCfg,"servers: []",$enc)

# ===== 3) 离线镜像加载检测（含常见 MCP 服务器镜像；仅抑制错误输出）=====
function Test-LocalImage{
  param([string]$Ref)
  & docker image inspect $Ref 1>$null 2>$null
  if($LASTEXITCODE -eq 0){ return $true } else { return $false }
}
$tarMap=@(
  @{ Path=Join-Path $Cache "mongo_7.tar";               Ref="mongo:7" },
  @{ Path=Join-Path $Cache "ollama_latest.tar";         Ref="ollama/ollama:latest" },
  @{ Path=Join-Path $Cache "mcp-gateway_latest.tar";    Ref="docker/mcp-gateway:latest" },
  @{ Path=Join-Path $Cache "librechat_v0.8.0.tar";      Ref="ghcr.io/danny-avila/librechat:v0.8.0" },
  # MCP servers（Docker Hub / GHCR）
  @{ Path=Join-Path $Cache "mcp_duckduckgo_latest.tar"; Ref="mcp/duckduckgo:latest" },
  @{ Path=Join-Path $Cache "mcp_firecrawl_latest.tar";  Ref="mcp/firecrawl:latest" },
  @{ Path=Join-Path $Cache "mcp_github_official_latest.tar"; Ref="ghcr.io/github/github-mcp-server:latest" },
  @{ Path=Join-Path $Cache "mcp_sequentialthinking_latest.tar"; Ref="mcp/sequentialthinking:latest" },
  @{ Path=Join-Path $Cache "mcp_grafana_latest.tar";    Ref="mcp/grafana:latest" }
)
foreach($t in $tarMap){
  if(-not (Test-LocalImage $t.Ref)){
    if(Test-Path $t.Path){ try{ docker load -i $t.Path | Out-Null }catch{} }
  }
}

# ===== 3.1) 只收集“本机确有”的 MCP 镜像并写回 YAML（避免远程 Catalog）=====
$candidates=@(
  "mcp/duckduckgo:latest",
  "mcp/firecrawl:latest",
  "ghcr.io/github/github-mcp-server:latest",
  "mcp/sequentialthinking:latest",
  "mcp/grafana:latest"
)
$present= @()
foreach($img in $candidates){ if(Test-LocalImage $img){ $present += $img } }
$serverUris = ($present | ForEach-Object { "  - docker-image://$_" }) -join "`n"
$cfg = "servers:`n" + ($serverUris -ne "" ? $serverUris : "  []")
[IO.File]::WriteAllText($McpCfg,$cfg,$enc)

# ===== 4) 先启动依赖服务（不启动 librechat）=====
docker compose -f $ComposePath up -d mongo ollama mcp-gateway

# ===== 5) 等待 Mongo 健康 =====
$deadline=(Get-Date).AddMinutes(3)
do{ Start-Sleep 3; $st=docker inspect -f "{{.State.Health.Status}}" mongo 2>$null }until($st -eq "healthy" -or (Get-Date) -gt $deadline)
if($st -ne "healthy"){ throw "Mongo 未就绪" }

# ===== 6) 离线导入或在线拉取 Ollama 模型（无 awk/grep）=====
function Import-OllamaPkgs{
  Get-ChildItem -Path $Cache -Filter "*.ollama" -File -ErrorAction SilentlyContinue |
    ForEach-Object { try{ docker exec ollama ollama import "/cache/$($_.Name)" | Out-Null }catch{} }
}
Import-OllamaPkgs

function Get-LocalModels{
  try{
    $r = Invoke-RestMethod -Uri "http://localhost:11434/v1/models" -Method Get -TimeoutSec 5
    if($r -and $r.data){ return @($r.data.id) }
  }catch{}
  try{
    $r2 = Invoke-RestMethod -Uri "http://localhost:11434/api/list" -Method Get -TimeoutSec 5
    if($r2 -and $r2.models){ return @($r2.models.name) }
  }catch{}
  return @()
}

function Ensure-OllamaModel([string]$model){
  $present = (Get-LocalModels) -contains $model
  if(-not $present){
    try{ docker exec ollama ollama pull $model | Out-Null }catch{
      throw "未发现 $model 的 .ollama 包且在线拉取失败，请将对应 .ollama 放入 $Cache 后重试"
    }
  }
}
Ensure-OllamaModel "qwen3:8b"
Ensure-OllamaModel "gemma3:4b"
$ModelList = Get-LocalModels

# ===== 7) 写入 librechat.yaml（streamable-http + /mcp）=====
if($ModelList.Count -eq 0){ $ModelList=@("qwen3:8b","gemma3:4b") }
$modelsYaml = ($ModelList | ForEach-Object { '"'+$_+'"' }) -join ", "

$yaml=@"
version: "1.3.0"
interface:
  agents: true

endpoints:
  agents:
    disableBuilder: false
    titleConvo: false
  custom:
    - name: "LocalOllama"
      apiKey: "ollama"
      baseURL: "http://ollama:11434/v1/"
      titleConvo: false
      summarize: false
      assistants: false
      models:
        default: [$modelsYaml]
        fetch: true
      modelDisplayLabel: "Ollama"

mcpServers:
  docker-mcp-gateway:
    type: "streamable-http"
    url: "http://mcp-gateway:8080/mcp"
    headers:
      sessionid: "{{LIBRECHAT_USER_ID}}"
    chatMenu: true
    requiresOAuth: false
    serverInstructions: true
    timeout: 120000
    initTimeout: 300000
"@
$yaml=($yaml -replace '\p{Cf}',''); [IO.File]::WriteAllText($Lcy,$yaml,$enc)

# ===== 8) 一次性修复历史数据 endpoint=agents → custom =====
$js=@'
const dbx = db.getSiblingDB("librechat");
const cols = dbx.getCollectionNames();
if (cols.includes("convos")) {
  dbx.convos.updateMany(
    { $or: [ { endpoint: "agents" }, { endpoint: { $exists: false } } ] },
    { $set: { endpoint: "custom" } }
  );
}
if (cols.includes("presets")) {
  dbx.presets.updateMany(
    { endpoint: "agents" },
    { $set: { endpoint: "custom" } }
  );
}
'@
$patchFile = Join-Path $VolMongo "fix_endpoint.js"
[IO.File]::WriteAllText($patchFile,$js,$enc)
docker exec mongo mongosh --file "/data/db/fix_endpoint.js" | Out-Null

# ===== 9) 等网关就绪 再启 LibreChat（先测 TCP 8080 再测 HTTP 并接受 200/400/404/405）=====
$gwReady=$false
$deadline=(Get-Date).AddMinutes(2)
do{
  Start-Sleep 2
  try{
    $tnc = Test-NetConnection -ComputerName 'localhost' -Port 8080 -WarningAction SilentlyContinue
    if($tnc.TcpTestSucceeded){ $gwReady = $true; break }
  }catch{}
  try{
    $resp = Invoke-WebRequest -Uri "http://localhost:8080/mcp" -Method Get -TimeoutSec 3 -ErrorAction Stop
    $gwReady = $true
  }catch{
    $code = $null
    if($_.Exception.Response){ $code = [int]$_.Exception.Response.StatusCode }
    if($code -in 200,400,404,405){ $gwReady = $true } else { $gwReady = $false }
  }
} until($gwReady -or (Get-Date) -gt $deadline)
if(-not $gwReady){ throw "MCP 网关未就绪" }

docker compose -f $ComposePath up -d librechat

# ===== 10) 冷启动一次模型 =====
if($ModelList.Count -gt 0){
  $Primary = $ModelList[0]
  try{ docker exec ollama sh -lc "printf ok | ollama run $Primary >/dev/null 2>&1 || true" }catch{}
}

# ===== 11) 收集 MCP 工具清单 =====
Start-Sleep 8
$since=(Get-Date).AddMinutes(-10).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$log = docker logs librechat --since $since 2>&1
$toolLines = $log | Select-String -Pattern "\[MCP\].*Tools:"
$summaryText = ($toolLines | Select-Object -ExpandProperty Line) -join "`r`n"
$summaryPath = Join-Path $WS "mcp_tools_summary.txt"
$logPath     = Join-Path $WS "mcp_init_logs.txt"
[IO.File]::WriteAllText($summaryPath,$summaryText,$enc)
[IO.File]::WriteAllText($logPath,$log,$enc)

# ===== 12) 自检 =====
if($ModelList.Count -gt 0){
  $body = @{ model=$ModelList[0]; messages=@(@{role="user"; content="只回复ok"}) } | ConvertTo-Json -Depth 5
  Invoke-RestMethod -Uri "http://localhost:11434/v1/chat/completions" -Method Post -ContentType "application/json" -Body $body | Out-Null
}

"`n完成：
- UI:           http://localhost:3080
- MCP 网关：     http://localhost:8080/mcp
- 工具清单：      $summaryPath
- 初始化日志：    $logPath
- 模型状态：      已导入：" + ($ModelList -join ', ')

# Please fill out the $Root
# 一键设置.ps1
# PowerShell 7.5.4
param(
  [string]$Root="",
  [switch]$ExportImages,
  [string]$ExportDir=""
)

$ErrorActionPreference='Stop'
$Conf     = Join-Path $Root "conf"
$Vols     = Join-Path $Root "volumes"
$WS       = Join-Path $Vols "workspace"
$VolMongo = Join-Path $Vols "mongo"
$VolOllama= Join-Path $Vols "ollama"
$Cache    = Join-Path $Vols "image_cache"
$Compose  = Join-Path $Root "compose-named.yml"
$Tmp      = Join-Path $env:TEMP "libre_local_build_$(Get-Random)"
$NowTag   = (Get-Date -Format "yyyyMMddHHmm")
$enc      = New-Object System.Text.UTF8Encoding($false)

$ImgLibre = "local/librechat-bundled:1.3.1"
$ImgMcp   = "local/mcp-gateway-bundled:$NowTag"
$ImgOll   = "local/ollama-with-models:$NowTag"

New-Item -Force -ItemType Directory $Conf,$Vols,$WS,$VolMongo,$VolOllama,$Cache | Out-Null
if(-not (Test-Path $Tmp)){ New-Item -ItemType Directory -Path $Tmp | Out-Null }

# ========== 1) LibreChat 配置 ==========
$LcyHost = Join-Path $Tmp "librechat.yaml"
@'
version: "1.3.0"
interface:
  agents: true
  defaultEndpoint: custom
endpoints:
  agents:
    disableBuilder: false
    titleConvo: false
  custom:
    - name: "LocalOllama"
      apiKey: "ollama"
      baseURL: "http://ollama:11434/v1"
      fetch: true
      titleConvo: false
      summarize: false
      assistants: false
      models:
        default: []
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
'@ | Out-File -FilePath $LcyHost -Encoding UTF8

$AuthHost = Join-Path $Tmp "auth.json"
if(-not (Test-Path $AuthHost)){ '{}' | Out-File -FilePath $AuthHost -Encoding utf8NoBOM }
$McpHost = Join-Path $Tmp "mcp-gateway.yaml"
'servers: {}' | Out-File -FilePath $McpHost -Encoding UTF8

# ========== 2) 构建镜像 ==========
$DirLib = Join-Path $Tmp "build_libre"; New-Item -ItemType Directory $DirLib | Out-Null
Copy-Item $LcyHost  (Join-Path $DirLib "librechat.yaml")  -Force
Copy-Item $AuthHost (Join-Path $DirLib "auth.json")       -Force
@'
FROM ghcr.io/danny-avila/librechat:v0.8.0
COPY librechat.yaml /app/conf/librechat.yaml
COPY auth.json      /app/api/data/auth.json
'@ | Out-File (Join-Path $DirLib "Dockerfile") -Encoding UTF8
docker build -t $ImgLibre $DirLib | Out-Null

$DirMcp = Join-Path $Tmp "build_mcp"; New-Item -ItemType Directory $DirMcp | Out-Null
Copy-Item $McpHost (Join-Path $DirMcp "mcp-gateway.yaml") -Force
@'
FROM docker/mcp-gateway:latest
RUN mkdir -p /conf
COPY mcp-gateway.yaml /conf/mcp-gateway.yaml
'@ | Out-File (Join-Path $DirMcp "Dockerfile") -Encoding UTF8
docker build -t $ImgMcp $DirMcp | Out-Null

$DirOll   = Join-Path $Tmp "build_ollama"; New-Item -ItemType Directory $DirOll | Out-Null
$SeedDir  = Join-Path $DirOll "models";     New-Item -ItemType Directory $SeedDir | Out-Null
$ScriptFp = Join-Path $DirOll "import-and-serve.sh"
if(Test-Path $Cache){
  Get-ChildItem -Path $Cache -Filter "*.ollama" -File -ErrorAction SilentlyContinue |
    ForEach-Object { Copy-Item $_.FullName (Join-Path $SeedDir $_.Name) -Force }
}
$script = @'
#!/bin/sh
set -e
ollama serve &
PID=$!
i=0
while [ "$i" -lt 180 ]; do
  if ollama list >/dev/null 2>&1; then break; fi
  i=$((i+1)); sleep 1
done
if ls /seed/*.ollama >/dev/null 2>&1; then
  for f in /seed/*.ollama; do echo "Importing $f"; ollama import "$f" || true; done
fi
if ls /cache/*.ollama >/dev/null 2>&1; then
  for f in /cache/*.ollama; do echo "Importing $f"; ollama import "$f" || true; done
fi
wait "$PID"
'@
$script = $script -replace "`r`n","`n"
[IO.File]::WriteAllText($ScriptFp,$script,$enc)
@'
FROM ollama/ollama:latest
RUN mkdir -p /seed /usr/local/bin
COPY import-and-serve.sh /usr/local/bin/import-and-serve.sh
RUN chmod +x /usr/local/bin/import-and-serve.sh
COPY models/ /seed/
ENTRYPOINT ["/usr/local/bin/import-and-serve.sh"]
'@ | Out-File (Join-Path $DirOll "Dockerfile") -Encoding UTF8
docker build -t $ImgOll $DirOll | Out-Null

# ========== 3) Compose ==========
$composeText = @"
name: libre-local
volumes:
  libre_mongo_data:
  libre_ollama_data:
  libre_workspace:
  libre_cache:

services:
  mongo:
    image: mongo:7
    container_name: mongo
    restart: unless-stopped
    healthcheck:
      test:
        - CMD
        - mongosh
        - --eval
        - "db.adminCommand('ping')"
      interval: 10s
      timeout: 5s
      retries: 12
    volumes:
      - libre_mongo_data:/data/db

  ollama:
    image: $ImgOll
    container_name: ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    volumes:
      - libre_ollama_data:/root/.ollama
      - libre_cache:/cache

  mcp-gateway:
    image: $ImgMcp
    container_name: mcp-gateway
    command:
      - "--port"
      - "8080"
      - "--transport"
      - "streaming"
      - "--config=/conf/mcp-gateway.yaml"
      - "--watch"
    restart: unless-stopped
    ports:
      - "8080:8080"
    healthcheck:
      test:
        - CMD
        - wget
        - -qO-
        - http://127.0.0.1:8080/health
      interval: 10s
      timeout: 5s
      retries: 12
    volumes:
      - libre_workspace:/workspace
      - /var/run/docker.sock:/var/run/docker.sock

  librechat:
    image: $ImgLibre
    container_name: librechat
    restart: unless-stopped
    depends_on:
      mongo:
        condition: service_healthy
      mcp-gateway:
        condition: service_healthy
      ollama:
        condition: service_started
    ports:
      - "3080:3080"
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
      - libre_workspace:/workspace
"@
[IO.File]::WriteAllText($Compose,$composeText,$enc)

# ========== 4) 启动 ==========
docker compose -f $Compose up -d

# ========== 5) 健康检查 ==========
$deadline=(Get-Date).AddMinutes(3)
do{ Start-Sleep 3; $st=docker inspect -f "{{.State.Health.Status}}" mongo 2>$null }until($st -eq "healthy" -or (Get-Date) -gt $deadline)
if($st -ne "healthy"){ throw "Mongo 未就绪" }

function Test-Gw {
  $paths=@("/health","/","/status","/healthz")
  foreach($p in $paths){
    try{
      $r=Invoke-WebRequest -Uri ("http://127.0.0.1:8080"+$p) -TimeoutSec 5 -Method Get -HttpVersion 1.1 -Headers @{Connection="close"}
      if($r.StatusCode -ge 200 -and $r.StatusCode -lt 500){ return $true }
    }catch{}
  }
  return $false
}
$deadline=(Get-Date).AddMinutes(3); $gw=$false
do{ Start-Sleep 2; $gw=Test-Gw }until($gw -or (Get-Date) -gt $deadline)
if(-not $gw){
  docker logs --tail 120 mcp-gateway 2>&1 | Write-Host
  throw "MCP 网关未就绪"
}

# ========== 6) 模型就绪与预热 ==========
function Get-OlModels{
  try{
    $r=Invoke-RestMethod -Uri "http://127.0.0.1:11434/v1/models" -Method Get -TimeoutSec 8 -HttpVersion 1.1 -Headers @{Accept="application/json";Connection="close"}
    if($r -and $r.data){ return @($r.data.id) } else { return @() }
  }catch{ return @() }
}
$require="qwen3:8b"
$models=Get-OlModels
if($models -notcontains $require){
  try{ docker exec ollama ollama pull $require }catch{}
}
for($i=1;$i -le 240;$i++){ $models=Get-OlModels; if($models -contains $require){break}; Start-Sleep 2 }

# 首轮编译预热
try{ docker exec -t ollama sh -lc "printf OK | ollama run $require >/dev/null 2>&1 || true" }catch{}

# ========== 7) 更新 LibreChat 默认模型 ==========
$selected=@()
if($models -contains $require){ $selected+= $require }
$preferred=@("gemma3:4b")
foreach($m in $preferred){ if(($selected -notcontains $m) -and ($models -contains $m)){ $selected+=$m } }
if($selected.Count -lt 2){ $selected += ($models | Where-Object { $selected -notcontains $_ } | Select-Object -First (2-$selected.Count)) }
$line = ($selected | ForEach-Object { '"' + $_ + '"' }) -join ","
$FinalYaml = Join-Path $Tmp "librechat.final.yaml"
@'
version: "1.3.0"
interface:
  agents: true
  defaultEndpoint: custom
endpoints:
  agents:
    disableBuilder: false
    titleConvo: false
  custom:
    - name: "LocalOllama"
      apiKey: "ollama"
      baseURL: "http://ollama:11434/v1"
      fetch: true
      titleConvo: false
      summarize: false
      assistants: false
      models:
        default: [__PLACEHOLDER_MODELS__]
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
'@ -replace '__PLACEHOLDER_MODELS__', $line | Out-File -FilePath $FinalYaml -Encoding UTF8
docker cp $FinalYaml librechat:/app/conf/librechat.yaml | Out-Null
docker restart librechat | Out-Null

# ========== 8) 历史数据迁移 ==========
$PatchJs=@'
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
$PatchHost = Join-Path $Tmp "fix_endpoint.js"
[IO.File]::WriteAllText($PatchHost,$PatchJs,$enc)
docker cp $PatchHost mongo:/data/db/fix_endpoint.js | Out-Null
docker exec mongo mongosh --file "/data/db/fix_endpoint.js" | Out-Null

# ========== 9) 可选镜像导出 ==========
if($ExportImages){
  if([string]::IsNullOrWhiteSpace($ExportDir)){ $ExportDir = Join-Path $Root "bundle\images" }
  if(-not (Test-Path $ExportDir)){ New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null }
  $pairs=@(
    @{ Img="mongo:7"; Tar="mongo_7.tar" },
    @{ Img=$ImgOll;   Tar="ollama_with_models.tar" },
    @{ Img=$ImgMcp;   Tar="mcp_gateway_bundled.tar" },
    @{ Img=$ImgLibre; Tar="librechat_bundled.tar" }
  )
  foreach($p in $pairs){ docker save -o (Join-Path $ExportDir $p.Tar) $p.Img }
  "镜像已导出到: $ExportDir" | Write-Output
}

# ========== 10) 直连与自检（最小生成量，三段回退） ==========
function _ErrStr([object]$ex){ if($null -eq $ex){return ""}; try{return ($ex | Out-String).Trim()}catch{return "$ex"} }

function Test-Chat {
  param([string]$Model)
  $hdr = @{Accept="application/json";Connection="close"}

  # A) /api/generate —— 最快，num_predict=1
  try{
    $bodyA = @{ model=$Model; prompt="OK"; stream=$false; options=@{ num_predict=1; temperature=0; top_p=0 } } | ConvertTo-Json -Depth 8
    $ra = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/generate" -Method Post -ContentType "application/json" -Body $bodyA -Headers $hdr -TimeoutSec 120 -HttpVersion 1.1
    if($ra -and $ra.response){ return @{ ok=$true; via="api/generate"; msg=$ra.response } }
  }catch{ $eA = _ErrStr $_ }

  # B) /api/chat —— 兼容 content 为数组或字符串
  try{
    $bodyB = @{ model=$Model; messages=@(@{role="user"; content="OK"}); stream=$false; options=@{ num_predict=1; temperature=0; top_p=0 } } | ConvertTo-Json -Depth 8
    $rb = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/chat" -Method Post -ContentType "application/json" -Body $bodyB -Headers $hdr -TimeoutSec 120 -HttpVersion 1.1
    if($rb -and $rb.message){
      $c = $rb.message.content
      if($c -is [string] -and $c.Length -gt 0){ return @{ ok=$true; via="api/chat"; msg=$c } }
      if($c -is [System.Collections.IEnumerable]){
        $t = ($c | Where-Object { $_.type -eq "text" } | Select-Object -First 1)
        if($t -and $t.text){ return @{ ok=$true; via="api/chat[]"; msg=$t.text } }
      }
    }
  }catch{ $eB = _ErrStr $_ }

  # C) /v1/chat/completions —— OpenAI 兼容
  try{
    $bodyC = @{ model=$Model; messages=@(@{role="user"; content="OK"}); stream=$false; temperature=0; max_tokens=1 } | ConvertTo-Json -Depth 8
    $rc = Invoke-RestMethod -Uri "http://127.0.0.1:11434/v1/chat/completions" -Method Post -ContentType "application/json" -Body $bodyC -Headers $hdr -TimeoutSec 120 -HttpVersion 1.1
    if($rc -and $rc.choices -and $rc.choices[0].message.content){ return @{ ok=$true; via="v1/chat/completions"; msg=$rc.choices[0].message.content } }
  }catch{ $eC = _ErrStr $_ }

  return @{ ok=$false; via=""; errA=$eA; errB=$eB; errC=$eC }
}

Start-Sleep 3
$uiOk=$false; $gwOk=$false; $olOk=$false; $chatOK=$false; $chatVia=""
try{
  $u=Invoke-WebRequest -Uri "http://127.0.0.1:3080" -Method Get -TimeoutSec 15 -HttpVersion 1.1 -Headers @{Connection="close"}
  if($u.StatusCode -ge 200 -and $u.StatusCode -lt 500){$uiOk=$true}
}catch{
  try{ $uiOk = ("true" -eq (docker inspect -f "{{.State.Running}}" librechat 2>$null)) }catch{}
}
try{ $gwOk=Test-Gw }catch{}
try{
  $m=Invoke-RestMethod -Uri "http://127.0.0.1:11434/v1/models" -Method Get -TimeoutSec 8 -HttpVersion 1.1 -Headers @{Accept="application/json";Connection="close"}
  if($m){$olOk=$true}
}catch{}

$sel = if($selected){ $selected[0] } else { $require }
$res = Test-Chat -Model $sel
if($res.ok){ $chatOK=$true; $chatVia=$res.via } else {
  Write-Warning ("Chat直连失败 详细: api/generate=[{0}] api/chat=[{1}] v1=[{2}]" -f $res.errA,$res.errB,$res.errC)
  Write-Host "`n--- 最近 80 行 ollama 日志 ---"
  docker logs --tail 80 ollama 2>&1 | Write-Host
}

"`n完成:
- UI:               http://localhost:3080     状态: " + ($(if($uiOk){"OK"}else{"未知"})) + "
- MCP 网关:          http://localhost:8080     状态: " + ($(if($gwOk){"OK"}else{"未知"})) + "
- Ollama API:        http://localhost:11434    状态: " + ($(if($olOk){"OK"}else{"未知"})) + "
- 模型(default):      " + ($(if($selected){$selected -join ', '}else{'<空>'})) + "
- Qwen3 目标:         " + ($(if($models -contains $require){"OK"}else{"缺失"})) + "
- Chat直连测试:       " + ($(if($chatOK){"OK via " + $chatVia}else{"失败"})) + "
- Compose:           $Compose
- 卷:                libre_mongo_data, libre_ollama_data, libre_workspace, libre_cache
- 追加模型方法:       将 .ollama 放入 libre_cache 或 docker exec ollama ollama pull qwen3:8b
" | Write-Output

Remove-Item -Recurse -Force $Tmp

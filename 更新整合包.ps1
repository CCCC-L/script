# 是否删除FPSLocker\patches文件夹 0为不删除，1为删除
$deleteFPSLockerPatches = 0
$changeClashTunStatus = 0

# 配置文件
$iniConfig = @{
  "atmosphere\config\system_settings.ini" = @{
    "tc" = ""
  }
}

# 白名单文件夹
$whitelisting = @(
  $MyInvocation.MyCommand.Name,
  "atmosphere\contents",
  "atmosphere\exefs_patches", 
  "atmosphere\kips", 
  "Nintendo", 
  "emuMMC", 
  "Emutendo", 
  "config", 
  "SaltySD\plugins\FPSLocker", 
  "JKSV"
  "switch\DBI\dbi.config",
  "switch\DBI\.DBI.nro.star",
  "switch\.packages\config.ini",
  "lakka"
)

# 黑名单文件夹
$blacklists = @(
  "atmosphere\exefs_patches\am", 
  "atmosphere\exefs_patches\bluetooth_patches", 
  "atmosphere\exefs_patches\btm_patches", 
  "atmosphere\exefs_patches\es_patches", 
  "atmosphere\exefs_patches\nfim_ctest",
  "atmosphere\exefs_patches\disable_remap_dialog"
  
)

$packagePlugBlacklists = @(
  "ldn_mitm",
  "ldnmitm_config"
)

$packageBlacklists = @(
  "switch\.HekateToolbox.nro.star"
)

# 当前文件夹下有这些文件夹则认为是大气层整合包
$specificFolder = @(
  "atmosphere", 
  "Nintendo", 
  "emuMMC", 
  "Emutendo"

)

# ------------------------------- 依赖区 -------------------------------
Add-Type -Assembly System.IO.Compression.FileSystem

# ------------------------------- 方法区 -------------------------------
# 定义删除文件的函数
function CleanFiles {
  param (
    [string]$path
  )

  Get-ChildItem -Path $path | ForEach-Object {
    # 获取相对路径
    $relativePath = GetRelativePath $_
    # 判断当前文件是否不在白名单中
    if ($whitelisting -notcontains "$relativePath") {
      # 如果是文件夹则递归当前方法
      if ($_ -is [System.IO.DirectoryInfo]) {
        CleanFiles -path $_.FullName
        # 判断当前文件夹是否是空文件夹，是空文件夹删除
        if ((Get-Item $relativePath).GetFileSystemInfos().Count -eq 0) {
          removeFile $_.FullName
        }
      }
      else {
        # 文件直接删除
        removeFile $_.FullName
      }
    }
  }
}

# 获取相对于脚本的路径
function GetRelativePath {
  param (
    [System.IO.FileSystemInfo]$item
  )

  return $item.FullName.Replace($PSScriptRoot + "\", "").Replace($PSScriptRoot, "")
}

# 启动、关闭Clash Tun模式
function ChangeClashTunStatus {
  param (
    [bool]$status
  )

  if (! $changeClashTunStatus) {
    return
  }

  $data = $status ? '{"tun":{"enable":true}}' : '{"tun":{"enable":false}}'
  Write-Host $data
  $result = Invoke-WebRequest -Method PATCH -Uri "http://127.0.0.1:9097/configs?force=true" -ContentType "application/json" -Body $data
}

# 下载整合包
function DownloadPackage {
  # 获取整合包下载地址
  $downloadUrl = "https://gh-proxy.com/github.com/wei2ard/AutoFetch/releases/download/latest/AIO-pre.zip"
  $zipName = "AIO-pre.zip"

  # 启动Clash Tun模式
  ChangeClashTunStatus 1

  # 下载整合包
  Invoke-WebRequest -Method Get -Uri $downloadUrl -OutFile $zipName 
  # 关闭Clash Tun模式
  ChangeClashTunStatus 0 
  return $zipName
}

# 解压
function Unzip {
  param (
    [string]$zipPath,
    [string]$tempPath
  )
  Expand-Archive -LiteralPath $zipPath -DestinationPath $tempPath
}

# 删除文件
function removeFile {
  param (
    [string]$path
  )

  Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
  if ($?) {
    Write-Host "remove" $path
  }
}

# 获取ini文件的Section
function GetIniSection {
  param (
    [string]$FilePath,
    [string]$Section
  )

  $ini = @{}
  $capture = $false
  $lines = Get-Content -Path $FilePath

  foreach ($line in $lines) {
    if ($line -match '^\s*\[(.+)\]') {
      if ($capture) {
        break
      }
      $capture = ($matches[1].Trim() -eq $Section)
      if ($capture) {
        $ini[$Section] = @{}
      }
    }
    elseif ($capture) {
      if ($line -match '^\s*(.+?)\s*=\s*(.*)') {
        $ini[$Section][$matches[1].Trim()] = $matches[2].Trim()
      }
    }
  }

  return $ini[$Section]
}

# 更新ini文件的Section当没有时追加到末尾
function UpdateIniSection {
  param (
    [string]$FilePath,
    [string]$Section,
    [hashtable]$NewData,
    [string]$NewLine = "`n"
  )

  if (-not (Test-Path $FilePath)) {
    Write-Error "File '$FilePath' not found"
    return
  }

  $lines = Get-Content -Path $FilePath -Raw
  $newContent = @()
  $sectionFound = $false
  $mathedSection = $false

  $lines -split '\r?\n' | foreach {
    if ($_ -match '^\s*\[(.+)\]') {
      if ($sectionFound) {
        $sectionFound = $false
      }
      if ($matches[1].Trim() -eq $Section) {
        $sectionFound = $true
        $mathedSection = $true
        $newContent += "$_"
        $NewData.GetEnumerator() | Sort-Object Name | ForEach-Object {
          $newContent += "$($_.Key)=$($_.Value)"
        }
        return
      }
    }
    if (-not $sectionFound) {
      $newContent += $_
    }
  }

  if (-not $mathedSection) {
    $newContent += "[$Section]"
    $NewData.GetEnumerator() | Sort-Object Name | ForEach-Object {
      $newContent += "$($_.Key)=$($_.Value)"
    }
  }

  $newContent -join $NewLine | Set-Content -Path $FilePath -NoNewline -Encoding UTF8
}

# 获取地址值
function getOffset {
  param (
    [string]$pattern1,
    [System.Byte[]]$fileBytes
  )
  if ($pattern1.StartsWith("\x")) {
    $pattern = $pattern1 -split "\\x" | Where-Object { $_ } | ForEach-Object { [byte]("0x" + $_) }
  }
  else {
    $pattern = [System.Text.Encoding]::UTF8.GetBytes($pattern1)
  }

  for ($i = 0; $i -le ($fileBytes.Length); $i += 4) {
    $match = $true
    for ($j = 0; $j -lt $pattern.Length; $j++) {
      if ($fileBytes[$i + $j] -ne $pattern[$j]) {
        $match = $false
        break
      }
    }
    if ($match) {
      return $i
    }
  }
  
}

function replaceFile {
  param (
    [string]$path,
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$values
  )

  if ($values.Count % 2 -ne 0) {
    Write-Host '接收到的$values参数不是成双成对的'
    return 
  }

  for ($i = 0; $i -lt $values.Count; $i += 2) {
    Set-Content $path ((Get-Content $path) -replace $values[$i], $values[$i + 1]) 
  }
}

function updateKipConfig {
  replaceFile "exporter.ps1" "pause" ""
  .\exporter.ps1
  if (!$?) {
    Write-Host "导出Kip参数异常，不再更新Kip版本"
    return 
  }

  $sourceKipPath = (Get-childItem atmosphere\kips\loader.kip -Recurse -Force).FullName
  Copy-Item $sourceKipPath "atmosphere\kips\.bak\Auto by Powershell.kip"
  $targetKipPath = Get-childItem ($packageName + "\atmosphere\kips\.bak\*_default_*.kip") -Recurse -Force
  Copy-Item $targetKipPath.FullName $sourceKipPath

  Copy-Item ($packageName + "\importer.ps1") .
  replaceFile "importer.ps1" "pause" ""
  .\importer.ps1
  if (!$?) {
    Write-Host "导入Kip版本异常，恢复loader.kip的版本"
    Copy-Item "atmosphere\kips\.bak\Auto by Powershell.kip" $sourceKipPath 
    return 
  }

  $kipVersion = [regex]::Match($targetKipPath.name, '\d+(\.\d+)+').Value
  Write-Host "Updated Kip version to $kipVersion"

}

# ------------------------------- 脚本区 -------------------------------
# 判断是否包含特定文件夹
foreach ($folder in $specificFolder) {
  if (-not (Test-Path $folder)) {
    Write-Host "当前文件夹不是整合包根目录"
    Pause
    exit
  }
}

# 保存指定的ini的配置
# foreach ($path in $iniConfig.Keys) {
#   foreach ($section in @($iniConfig[$path].Keys)) {
#     $iniConfig[$path][$section] = GetIniSection $path $section
#   }
# }

# 判断是否删除FPSLocker\patches文件夹
if ($deleteFPSLockerPatches) {
  removeFile "SaltySD\plugins\FPSLocker\patches"
}

# 删除黑名单中的文件夹
foreach ($blacklist in $blacklists) {
  removeFile $blacklist
}

# 删除atmosphere\contents文件夹下的插件
Get-ChildItem -Path "atmosphere\contents" -Directory | ForEach-Object {
  if (Test-Path ($_.FullName + "\toolbox.json")) {
    removeFile $_.FullName
  }
}

# 清空之前整合包的内容
CleanFiles -path "*"

# 下载新的整合包
$zipName = DownloadPackage

# 解压整合包
Unzip $zipName .

# 删除内存卡中config文件夹与包中config文件夹相同的文件夹
$packageName = $zipName.TrimEnd([System.IO.Path]::GetExtension($zipName))
$packageName = "Magic-Suite"
Get-ChildItem config | ForEach-Object {
  removeFile ($packageName + "\" + (GetRelativePath $_))
}

# 删除不需要的插件
$packagePlugBlacklists | ForEach-Object {
  # 查找atmosphere\contents中有没有指定的插件
  $plugName = $_
  Get-ChildItem -Path ($packageName + "\atmosphere\contents") -Directory | ForEach-Object {
    # 判断toolbox.json中是否包含需要删除的插件名
    if (Get-Content -Path ($_.FullName + "\toolbox.json") | Select-String -Pattern $plugName -Quiet) {
      removeFile $_.FullName
    }
  }

  # 删除插件
  removeFile ($packageName + "\switch\" + $_) 
  removeFile ($packageName + "\switch\" + $_ + ".nro") 
  removeFile ($packageName + "\switch\" + $_ + ".nro.star") 
  # 删除tesla插件
  removeFile ($packageName + "\switch\.overlays\" + $_ + ".ovl") 
}

# 删除不需要的文件
foreach ($blacklist in $packageBlacklists) {
  removeFile ($packageName + "\" + $blacklist)
}

# 恢复ini配置
# foreach ($path in $iniConfig.Keys) {
#   foreach ($section in $iniConfig[$path].Keys) {
#     UpdateIniSection -FilePath ($packageName + "\" + $path) -Section "$section" -NewData $iniConfig[$path][$section]
#   }
# }

# 更新Kip配置
# updateKipConfig

# 复制到根目录
copy-item $packagename\* . -recurse -erroraction silentlycontinue

# 删除压缩包及临时目录
removefile $zipname
removefile $packagename
removefile "auto.bat"
removefile "LICENSE"
removefile "换包脚本使用说明.md"

pause

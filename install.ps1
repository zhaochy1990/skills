# 一键安装 skills（Windows PowerShell）
# 用法：
#   .\install.ps1                          # 安装 own + third-party 到 %USERPROFILE%\.agents\skills
#   .\install.ps1 -StrideDir <工作区路径>    # 追加安装 project-stride 到 <工作区>\.agents\skills
# 若提示脚本被禁用：Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
# 重复执行 = 覆盖更新（先删旧目录再拷贝，保证与仓库一致）。
param(
    [string]$StrideDir = ""
)

$ErrorActionPreference = "Stop"
$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Install-Group {
    param([string]$SrcDir, [string]$DestDir)
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    Get-ChildItem -Directory $SrcDir | ForEach-Object {
        if (-not (Test-Path (Join-Path $_.FullName "SKILL.md"))) { return }
        $target = Join-Path $DestDir $_.Name
        if (Test-Path $target) { Remove-Item -Recurse -Force $target }
        Copy-Item -Recurse $_.FullName $target
        Write-Host "  installed $($_.Name)"
    }
}

$Dest = Join-Path $HOME ".agents\skills"
Write-Host "→ 用户级 skills → $Dest"
Install-Group (Join-Path $RepoDir "own") $Dest
Get-ChildItem -Directory (Join-Path $RepoDir "third-party") | ForEach-Object {
    Write-Host "→ $($_.Name)"
    Install-Group $_.FullName $Dest
}

if ($StrideDir) {
    if (-not (Test-Path $StrideDir)) {
        Write-Error "-StrideDir 路径不存在: $StrideDir"
    }
    Write-Host "→ stride 项目级 skills → $StrideDir\.agents\skills"
    Install-Group (Join-Path $RepoDir "project-stride") (Join-Path $StrideDir ".agents\skills")
}

Write-Host "完成。重启 ZCode / 新开会话后生效。"

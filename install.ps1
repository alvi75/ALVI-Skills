# Installs llm-council for every coding agent on this machine.
#   powershell -ExecutionPolicy Bypass -File install.ps1          install, skip copies that differ
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Force   replace copies that differ
param([switch]$Force)
$ErrorActionPreference = 'Stop'

$skill = 'llm-council'
$src = Join-Path $PSScriptRoot $skill
if (-not (Test-Path (Join-Path $src 'SKILL.md'))) { Write-Error "missing $src\SKILL.md" }

$claudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
# ~/.agents/skills is read by Codex, Gemini CLI, OpenCode, Cursor and Copilot.
$targets = @((Join-Path $claudeHome 'skills'), (Join-Path $HOME '.agents\skills'))

function Get-Tree($root) {
  $root = (Resolve-Path $root).Path
  (Get-ChildItem $root -Recurse -File | Sort-Object FullName | ForEach-Object {
    $_.FullName.Substring($root.Length) + ':' + (Get-FileHash $_.FullName).Hash
  }) -join "`n"
}

$code = 0
foreach ($dir in $targets) {
  $dest = Join-Path $dir $skill
  if (Test-Path $dest) {
    if ((Get-Tree $src) -eq (Get-Tree $dest)) {
      Write-Output "up to date  $dest"; continue
    }
    if (-not $Force) {
      Write-Output "skipped     $dest (differs; compare it, then rerun with -Force)"
      $code = 2; continue
    }
    Remove-Item $dest -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Copy-Item $src $dir -Recurse
  Write-Output "installed   $dest"
}

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$old = Join-Path $codexHome "skills\$skill"
if (Test-Path $old) {
  Write-Output "note: $old also exists. Codex may list llm-council twice; delete that folder to use this copy."
}
exit $code

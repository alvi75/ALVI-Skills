# Claude Code status line (PowerShell 5.1, no dependencies).
#
#   -Layout meters   (default)  two rate-limit meters, styled like the claude.ai composer footer
#   -Layout context             one context-window meter with token counts
#
#   ◆ Opus 5  High  my-project  ⎇ main  ctx 13% · 128k/1M
#   Session: 16% · resets in 1h 31m  ▕██░░░░░░░░░░▏  ▕█░░░░░░░░░░░▏  Weekly: 8% · resets in 4d 22h
#
# settings.json (forward slashes are required - Git Bash eats backslashes):
#   "statusLine": {
#     "type": "command",
#     "command": "powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/YOU/.claude/statusline.ps1",
#     "refreshInterval": 60
#   }
#
# refreshInterval is what keeps the countdowns moving in EVERY open session,
# including ones you are not typing in - event-driven updates alone freeze when
# a window goes idle.
#
# No dollar figure by design: cost.total_cost_usd is a client-side estimate of
# what the API would have charged. On a subscription nobody pays it.

param([ValidateSet('meters', 'context')][string]$Layout = 'meters')

$ErrorActionPreference = 'SilentlyContinue'

# PowerShell 5.1 drains piped stdin into $input before the script body runs, so
# [Console]::In.ReadToEnd() returns 0 chars under -File. $input must come first.
$raw = ($input | Out-String)
if (-not $raw) { $raw = [Console]::In.ReadToEnd() }
if (-not $raw) { exit 0 }
try { $d = $raw | ConvertFrom-Json } catch { exit 0 }
if (-not $d) { exit 0 }

$E = [char]27
$RESET = "$E[0m"; $DIM = "$E[2m"
# NOTE: PowerShell variable names are CASE-INSENSITIVE. Never introduce a $label
# alongside $LBL - they would be the same variable and the colour constant would
# be overwritten with text. That bug shipped once already.
$isLight = $false
try {
    $cfg = Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.claude\settings.json') -Raw |
           ConvertFrom-Json
    if ($cfg.theme -and ([string]$cfg.theme) -match 'light') { $isLight = $true }
} catch { }

if ($isLight) {
    # xterm 39 (#00AFFF) is 2.45:1 on white, under the WCAG 3:1 floor for
    # non-text; the muted grey label is 3.45:1, under the 4.5:1 floor for text.
    $FILL  = "$E[38;5;26m"; $TRACK = "$E[38;5;252m"; $LBL = "$E[38;5;240m"
    $AMBER = "$E[38;5;130m"; $RED = "$E[38;5;124m"; $WHITE = "$E[38;5;232m"
} else {
    $FILL  = "$E[38;5;39m"; $TRACK = "$E[38;5;238m"; $LBL = "$E[38;5;245m"
    $AMBER = "$E[38;5;214m"; $RED = "$E[38;5;203m"; $WHITE = "$E[97m"
}
$CYAN = "$E[36m"; $GREEN = "$E[32m"; $YELLOW = "$E[33m"; $MAGENTA = "$E[35m"

$METER_W   = 12   # fixed, so one cell means the same thing at every window size
$RIGHT_PAD = 6    # MCP errors and auto-update notices share the right of this row

$out = New-Object Text.StringBuilder

# Claude Code exports the real terminal width; tput cannot see it from here.
$cols = 0
if ($env:COLUMNS) { [int]::TryParse($env:COLUMNS, [ref]$cols) | Out-Null }
if ($cols -le 0) { $cols = 100 }

# ---------------- helpers ----------------
function Clamp-Pct([object]$v) {
    $n = 0.0
    if (-not [double]::TryParse([string]$v, [ref]$n)) { return 0.0 }
    if ($n -lt 0) { return 0.0 }
    if ($n -gt 100) { return 100.0 }
    return $n
}

# Floor, not {0:N0}: N0 rounds half away from zero, so 99.5 would print 100% and
# read as an exhausted limit. The docs' own examples all truncate.
function Pct-Text([double]$p) { return ("{0:0}" -f [math]::Floor($p)) }

function Format-Tok([double]$n) {
    if ($n -ge 1000000) { return ("{0:0.#}M" -f ($n / 1000000)) }
    if ($n -ge 1000)    { return ("{0:0}k"   -f ($n / 1000)) }
    return ("{0:0}" -f $n)
}

function Format-Reset([object]$epoch) {
    if ($null -eq $epoch) { return $null }
    $v = 0.0
    if (-not [double]::TryParse([string]$epoch, [ref]$v)) { return $null }  # never say "now" for junk
    $secs = $v - [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($secs -le 0) { return 'resetting' }
    $dd = [math]::Floor($secs / 86400)
    $hh = [math]::Floor(($secs % 86400) / 3600)
    $mm = [math]::Floor(($secs % 3600) / 60)
    if ($dd -ge 1) { return "${dd}d ${hh}h" }
    if ($hh -ge 1) { return "${hh}h ${mm}m" }
    return "${mm}m"
}

function New-Meter([double]$pct, [int]$w) {
    if ($w -lt 1) { $w = 1 }
    # AwayFromZero: [math]::Round defaults to banker's rounding, which renders
    # 30% and 50% identically at w=5 and drops 75% from 11 cells to 10.
    $f = [int][math]::Round($pct * $w / 100.0, [MidpointRounding]::AwayFromZero)
    if ($f -gt $w) { $f = $w }
    if ($f -lt 0)  { $f = 0 }
    $col = if ($pct -ge 90) { $RED } elseif ($pct -ge 75) { $AMBER } else { $FILL }
    # Below one cell but above zero, draw a 1/4-width sliver rather than either an
    # empty bar (dishonest low) or a whole block (at 12 cells, a 17x overstatement).
    # U+258E deliberately, NOT U+258F - that glyph is already the closing bracket.
    $head = ''
    if ($f -eq 0 -and $pct -gt 0) { $head = [string][char]0x258E }
    $bar = $col + ([string][char]0x2588) * $f + $head + $TRACK +
           ([string][char]0x2591) * ($w - $f - $head.Length) + $RESET
    return "$TRACK$([char]0x2595)$RESET$bar$TRACK$([char]0x258F)$RESET"
}

# Fixed meter width; longest label form that fits; meters shrink only as a last resort.
function Render-Row($pairs) {
    $n = $pairs.Count
    $chrome = 2 * $n + 2 * ($n + 1) - 2 + $RIGHT_PAD
    $nForms = $pairs[0].forms.Count
    for ($i = 0; $i -lt $nForms; $i++) {
        $txt = 0; foreach ($p in $pairs) { $txt += $p.forms[$i].Length }
        if ($txt + $n * $METER_W + $chrome -le $cols) { return @{ idx = $i; w = $METER_W } }
    }
    $txt = 0; foreach ($p in $pairs) { $txt += $p.forms[$nForms - 1].Length }
    $w = [int][math]::Floor(($cols - $txt - $chrome) / $n)
    if ($w -lt 1) { $w = 1 }
    if ($w -gt $METER_W) { $w = $METER_W }
    return @{ idx = $nForms - 1; w = $w }
}

$dot = [char]0x00B7

# ---------------- line 1: model / effort / dir / git / context ----------------
$model = $d.model.display_name
if (-not $model) { $model = 'claude' }
$model = ($model -replace '\s*\(.*\)\s*$', '')   # "Opus 5 (1M context)" -> "Opus 5"

$eff = ''; $effPlain = ''
if ($d.effort.level) {
    $effPlain = (Get-Culture).TextInfo.ToTitleCase([string]$d.effort.level)
    $eff = "  $LBL$effPlain$RESET"
}
$flags = ''; $flagsPlain = ''
if ($d.fast_mode) { $flags = " $DIM$dot fast$RESET"; $flagsPlain = " $dot fast" }

$cwd = $d.workspace.current_dir
if (-not $cwd) { $cwd = $d.cwd }
$dir = if ($cwd) { Split-Path $cwd -Leaf } else { '?' }

# git costs 3 process spawns (~240ms on Windows); cache per session for 5s.
$git = ''; $gitPlain = ''
if ($cwd -and (Test-Path -LiteralPath $cwd)) {
    $sid = $d.session_id; if (-not $sid) { $sid = 'nosession' }
    $cache = Join-Path $env:TEMP ("cc-statusline-git-" + ($sid -replace '[^A-Za-z0-9\-]', '') + ".txt")
    $fresh = (Test-Path -LiteralPath $cache) -and
             ((Get-Date) - (Get-Item -LiteralPath $cache).LastWriteTime).TotalSeconds -lt 5
    if (-not $fresh) {
        $rec = ''
        Push-Location -LiteralPath $cwd
        $branch = (git branch --show-current 2>$null | Select-Object -First 1)
        if (-not $branch) {
            $sha = (git rev-parse --short HEAD 2>$null | Select-Object -First 1)
            if ($sha) { $branch = "detached@$sha" }
        }
        if ($branch) {
            $staged   = @(git diff --cached --name-only 2>$null).Count
            $modified = @(git diff --name-only 2>$null).Count
            $rec = "$branch|$staged|$modified"
        }
        Pop-Location
        Set-Content -LiteralPath $cache -Value $rec -Encoding UTF8
    }
    $c = (Get-Content -LiteralPath $cache -Raw)
    if ($c) {
        $p = $c.Trim() -split '\|'
        if ($p[0]) {
            $marks = ''; $marksPlain = ''
            if ([int]$p[1] -gt 0) { $marks += " $GREEN+$($p[1])$RESET"; $marksPlain += " +$($p[1])" }
            if ([int]$p[2] -gt 0) { $marks += " $YELLOW~$($p[2])$RESET"; $marksPlain += " ~$($p[2])" }
            $git = "  $MAGENTA$([char]0x2387) $($p[0])$RESET$marks"
            $gitPlain = "  $([char]0x2387) $($p[0])$marksPlain"
        }
    }
}

$cw = $d.context_window
$ctxPct = 0.0
if ($cw) { $ctxPct = Clamp-Pct $cw.used_percentage }
$ctxUsed = 0.0; $ctxSize = 0.0
if ($cw) {
    if ($cw.total_input_tokens)  { $ctxUsed = [double]$cw.total_input_tokens }
    if ($cw.context_window_size) { $ctxSize = [double]$cw.context_window_size }
}
$ctxTokTxt = if ($ctxSize -gt 0) { "$(Format-Tok $ctxUsed)/$(Format-Tok $ctxSize)" }
             else { "$(Format-Tok $ctxUsed) tok" }

$tail = ''
if ($Layout -eq 'meters') {
    # Context lives on line 1 here, so line 2 stays a faithful copy of the footer.
    $tailTxt = "ctx $(Pct-Text $ctxPct)% $dot $ctxTokTxt"
    $plain1 = "$([char]0x25C6) $model" + $(if ($effPlain) { "  $effPlain" }) + $flagsPlain +
              "  $dir" + $gitPlain
    $ctxCol = if ($ctxPct -ge 90) { $RED } elseif ($ctxPct -ge 70) { $AMBER } else { $LBL }
    if ($plain1.Length + 2 + $tailTxt.Length + $RIGHT_PAD -le $cols) {
        $tail = "  $ctxCol$tailTxt$RESET"
    }
}
[void]$out.Append("$CYAN$([char]0x25C6) $WHITE$model$RESET$eff$flags  $LBL$dir$RESET$git$tail`n")

# ---------------- line 2 ----------------
$rl = $d.rate_limits
$has5 = $rl -and ($null -ne $rl.five_hour.used_percentage)
$has7 = $rl -and ($null -ne $rl.seven_day.used_percentage)

# rate_limits is absent before the first API response and always for API-key /
# Team / Enterprise auth, so the meters layout falls back to the context meter
# rather than printing a blank row.
if ($Layout -eq 'meters' -and ($has5 -or $has7)) {
    $p5 = Clamp-Pct $rl.five_hour.used_percentage
    $p7 = Clamp-Pct $rl.seven_day.used_percentage
    $r5 = Format-Reset $rl.five_hour.resets_at
    $r7 = Format-Reset $rl.seven_day.resets_at
    $t5 = Pct-Text $p5; $t7 = Pct-Text $p7

    # "resetting" is a state, not a duration - never render "resets in resetting".
    $long5  = if ($r5 -eq 'resetting') { " $dot resetting" } elseif ($r5) { " $dot resets in $r5" } else { '' }
    $long7  = if ($r7 -eq 'resetting') { " $dot resetting" } elseif ($r7) { " $dot resets in $r7" } else { '' }
    $short5 = if ($r5) { " $dot $r5" } else { '' }
    $short7 = if ($r7) { " $dot $r7" } else { '' }

    $pairs = @()
    if ($has5) { $pairs += @{ pct = $p5; side = 'l'; forms = @("Session: $t5%$long5", "Session $t5%$short5", "S $t5%") } }
    if ($has7) { $pairs += @{ pct = $p7; side = 'r'; forms = @("Weekly: $t7%$long7",  "Weekly $t7%$short7",  "W $t7%") } }

    $fit = Render-Row $pairs
    $seg = @()
    foreach ($p in $pairs) {
        $text = "$LBL$($p.forms[$fit.idx])$RESET"
        $meter = New-Meter $p.pct $fit.w
        $seg += if ($p.side -eq 'l') { "$text  $meter" } else { "$meter  $text" }
    }
    [void]$out.Append(($seg -join '  ') + "`n")
}
else {
    $ms = 0.0; if ($d.cost.total_duration_ms) { $ms = [double]$d.cost.total_duration_ms }
    $mins = [int][math]::Floor($ms / 60000); $secs = [int][math]::Floor(($ms % 60000) / 1000)
    $rlTxt = ''
    if ($has5) { $rlTxt = " $dot 5h $(Pct-Text (Clamp-Pct $rl.five_hour.used_percentage))%" }

    $forms = @(
        "Context: $(Pct-Text $ctxPct)% $dot $ctxTokTxt $dot ${mins}m${secs}s$rlTxt",
        "Context: $(Pct-Text $ctxPct)% $dot $ctxTokTxt",
        "C $(Pct-Text $ctxPct)%"
    )
    $fit = Render-Row @(@{ pct = $ctxPct; side = 'l'; forms = $forms })
    [void]$out.Append("$LBL$($forms[$fit.idx])$RESET  " + (New-Meter $ctxPct $fit.w) + "`n")
}

# Write raw bytes: LF only, UTF-8, no BOM. CRLF + ANSI is the documented glitch profile.
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($out.ToString())
$stdout = [Console]::OpenStandardOutput()
$stdout.Write($bytes, 0, $bytes.Length)
$stdout.Flush()

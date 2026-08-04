# Sweep a status line script through the inputs that actually break them.
#
#   .\test-statusline.ps1                          # meters layout
#   .\test-statusline.ps1 -Layout context          # context layout
#   .\test-statusline.ps1 -Script C:/path/to/statusline.ps1
#
# Asserts rather than prints. Exits non-zero on any failure. Verified by mutation:
# deliberate defects in rounding, clamping, line endings, the sub-cell sliver and
# the cost display are each caught by at least one check here.

param(
    [string]$Script = (Join-Path $PSScriptRoot 'statusline.ps1'),
    [ValidateSet('meters', 'context')][string]$Layout = 'meters'
)

# Without this, Out-String decodes the script's UTF-8 output using the console
# codepage (IBM437 by default on Windows). Each box-drawing glyph then counts as
# 3 characters and every width check fails on a perfectly good script.
$prevEnc = [Console]::OutputEncoding
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
trap { [Console]::OutputEncoding = $prevEnc }

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$cwd = ($PWD.Path -replace '\\', '/')
$real = '{"session_id":"test-0001","cwd":"' + $cwd + '","effort":{"level":"high"},' +
        '"model":{"id":"claude-opus-5","display_name":"Opus 5 (1M context)"},' +
        '"workspace":{"current_dir":"' + $cwd + '"},"version":"2.1.220",' +
        '"cost":{"total_cost_usd":9.4812,"total_duration_ms":3754000},' +
        '"context_window":{"total_input_tokens":128145,"total_output_tokens":2291,' +
        '"context_window_size":1000000,"used_percentage":13,"remaining_percentage":87},' +
        '"exceeds_200k_tokens":false,"fast_mode":false,"thinking":{"enabled":true},' +
        '"rate_limits":{"five_hour":{"used_percentage":16,"resets_at":' + ($now + 5460) + '},' +
        '"seven_day":{"used_percentage":8,"resets_at":' + ($now + 426000) + '}}}'

function Run($json, $cols) {
    $env:COLUMNS = "$cols"
    $o = ($json | powershell -NoProfile -ExecutionPolicy Bypass -File $Script -Layout $Layout | Out-String)
    return @{ raw = $o; code = $LASTEXITCODE }
}
function Vis($s) { ($s -replace "$([char]27)\[[0-9;]*m", '').TrimEnd() }
$fails = 0
Write-Output "layout: $Layout   script: $Script"

Write-Output "`n=== A. width fit ==="
foreach ($c in 30, 40, 50, 60, 70, 80, 90, 100, 120, 160, 200) {
    $l = @((Run $real $c).raw -split "`n" | Where-Object { $_ })
    for ($i = 0; $i -lt $l.Count; $i++) {
        if ((Vis $l[$i]).Length -gt $c) {
            Write-Output ("  FAIL cols={0} line{1} width={2}" -f $c, ($i + 1), (Vis $l[$i]).Length)
            $fails++
        }
    }
    "{0,4} | {1}" -f $c, (Vis $l[-1])
}

Write-Output "`n=== B. rate_limits absent ==="
$noRl = $real | ConvertFrom-Json
$noRl.PSObject.Properties.Remove('rate_limits')
$noRlJson = $noRl | ConvertTo-Json -Depth 8 -Compress
foreach ($c in 40, 80, 120) {
    $l = @((Run $noRlJson $c).raw -split "`n" | Where-Object { $_ })
    $v = Vis $l[-1]
    if ($v.Length -gt $c) { Write-Output "  FAIL cols=$c width=$($v.Length)"; $fails++ }
    "{0,4} | {1}" -f $c, $v
}

Write-Output "`n=== C. no dollar figure anywhere ==="
# The payload carries total_cost_usd = 9.4812. On a subscription that number is a
# client-side estimate of API-equivalent spend and must never be displayed.
foreach ($case in @(@('with rate_limits', $real), @('without rate_limits', $noRlJson))) {
    $o = (Run $case[1] 120).raw
    if ($o -match '\$' -or $o -match '9\.48') {
        Write-Output "  FAIL cost leaked into output ($($case[0])): $(Vis $o)"; $fails++
    }
    "{0,-20} clean" -f $case[0]
}

Write-Output "`n=== D. percentage sweep ==="
$src = if ($Layout -eq 'meters') { 'rate_limits' } else { 'context_window' }
$bars = @{}
foreach ($p in 0, 0.4, 1, 3, 30, 37.5, 49.9, 50, 70, 74.9, 75, 90, 99.5, 100, 150, -5) {
    $j = $real | ConvertFrom-Json
    if ($Layout -eq 'meters') {
        $j.rate_limits.five_hour.used_percentage = $p
        $j.rate_limits.seven_day.used_percentage = $p
    } else {
        $j.context_window.used_percentage = $p
    }
    $v = Vis @((Run ($j | ConvertTo-Json -Depth 8 -Compress) 120).raw -split "`n")[1]
    $bars["$p"] = $v
    "pct={0,6} | {1}" -f $p, $v
}
$FULL = [string][char]0x2588; $SLIVER = [string][char]0x258E
$div = if ($Layout -eq 'meters') { 2 } else { 1 }   # meters row draws two bars
function Cells($s) { @([regex]::Matches($s, $FULL)).Count / $div }
function Slivers($s) { @([regex]::Matches($s, $SLIVER)).Count }

# A sub-cell value draws a sliver, never a whole block: at 12 cells a full block
# overstates 0.4% seventeenfold, next to a label reading 0%.
if ((Slivers $bars['0.4']) -eq 0 -or (Cells $bars['0.4']) -ne 0) {
    Write-Output "  FAIL 0.4% should draw a sliver, not a full cell"; $fails++
}
if ((Slivers $bars['0']) -ne 0 -or (Cells $bars['0']) -ne 0) {
    Write-Output "  FAIL 0% must draw an empty track"; $fails++
}
# Away-from-zero rounding. 37.5% of a 12-cell meter is exactly 4.5 - the midpoint
# where banker's rounding gives 4 and away-from-zero gives 5. It is the only value
# in this sweep that discriminates between the two at this width.
if ((Cells $bars['37.5']) -ne 5) {
    Write-Output "  FAIL 37.5% must draw 5 cells, got $(Cells $bars['37.5']) (banker's rounding?)"; $fails++
}
if ((Cells $bars['75']) -le (Cells $bars['70'])) {
    Write-Output "  FAIL 75% must draw more cells than 70%"; $fails++
}
# Floor the label, so 99.5 never reads as an exhausted 100%. Clamp both ends.
if ($bars['99.5'] -match '\b100%') { Write-Output "  FAIL 99.5% printed as 100%"; $fails++ }
if ($bars['150'] -notmatch '\b100%') { Write-Output "  FAIL 150% not clamped to 100%"; $fails++ }
if ($bars['-5']  -notmatch '\b0%')   { Write-Output "  FAIL -5% not clamped to 0%"; $fails++ }

Write-Output "`n=== E. hostile resets_at ==="
foreach ($v in '"tomorrow"', 'null', '0', 'true', '[1,2]', "$($now + 3600)") {
    $j = '{"model":{"display_name":"Opus 5"},"cwd":"' + $cwd +
         '","session_id":"t","context_window":{"used_percentage":13},' +
         '"rate_limits":{"five_hour":{"used_percentage":16,"resets_at":' + $v + '}}}'
    $r = Run $j 120
    if ($r.code -ne 0) { Write-Output "  FAIL exit=$($r.code) for $v"; $fails++ }
    if ($r.raw -match 'resets in resetting') { Write-Output "  FAIL 'resets in resetting' for $v"; $fails++ }
    "{0,-14} | {1}" -f $v, (Vis @($r.raw -split "`n")[1])
}

Write-Output "`n=== F. degenerate stdin (must exit 0) ==="
foreach ($p in @(@('empty', ''), @('garbage', 'garbage'), @('empty obj', '{}'), @('truncated', '{"model":'))) {
    $r = Run $p[1] 120
    if ($r.code -ne 0) { Write-Output "  FAIL $($p[0]) exit=$($r.code)"; $fails++ }
    "{0,-10} exit={1} bytes={2}" -f $p[0], $r.code, $r.raw.Length
}

Write-Output "`n=== G. raw bytes: LF only, no CR, no BOM ==="
$env:COLUMNS = '120'
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell'
$psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Script`" -Layout $Layout"
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.UseShellExecute = $false
$proc = [Diagnostics.Process]::Start($psi)
$proc.StandardInput.Write($real); $proc.StandardInput.Close()
$ms = New-Object IO.MemoryStream
$proc.StandardOutput.BaseStream.CopyTo($ms); $proc.WaitForExit()
$b = $ms.ToArray()
$cr = @($b | Where-Object { $_ -eq 13 }).Count
$bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
if ($cr -gt 0) { Write-Output "  FAIL $cr CR bytes"; $fails++ }
if ($bom)      { Write-Output "  FAIL BOM present"; $fails++ }
"bytes={0} CR={1} LF={2} BOM={3}" -f $b.Length, $cr, @($b | Where-Object { $_ -eq 10 }).Count, $bom

Write-Output "`n=== H. latency (5 warm runs) ==="
1..2 | ForEach-Object { Run $real 120 | Out-Null }
$sw = [Diagnostics.Stopwatch]::StartNew()
1..5 | ForEach-Object { Run $real 120 | Out-Null }
$sw.Stop()
"mean {0} ms" -f [int]($sw.ElapsedMilliseconds / 5)

[Console]::OutputEncoding = $prevEnc
Write-Output ""
if ($fails -eq 0) { Write-Output "ALL CHECKS PASSED" } else { Write-Output "$fails CHECK(S) FAILED" }
exit $fails

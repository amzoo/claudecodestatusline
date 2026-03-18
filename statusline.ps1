# Single line: Model | tokens | %used | %remain | think | 5h bar @reset | 7d bar @reset | extra

# Read input from stdin
$input = @($Input) -join "`n"

if (-not $input) {
    Write-Host -NoNewline "Claude"
    exit 0
}

# ANSI colors matching oh-my-posh theme
$blue   = "`e[38;2;0;153;255m"
$orange = "`e[38;2;255;176;85m"
$green  = "`e[38;2;0;160;0m"
$cyan   = "`e[38;2;46;149;153m"
$red    = "`e[38;2;255;85;85m"
$yellow = "`e[38;2;230;200;0m"
$white  = "`e[38;2;220;220;220m"
$dim    = "`e[2m"
$reset  = "`e[0m"

# Format token counts (e.g., 50k / 200k)
function Format-Tokens([long]$num) {
    if ($num -ge 1000000) { return "{0:F1}m" -f ($num / 1000000) }
    elseif ($num -ge 1000) { return "{0:F0}k" -f ($num / 1000) }
    else { return "$num" }
}

# Format number with commas (e.g., 134,938)
function Format-Commas([long]$num) {
    return $num.ToString("N0")
}

# Return color escape based on usage percentage
function Get-UsageColor([int]$pct) {
    if ($pct -ge 90) { return $red }
    elseif ($pct -ge 70) { return $orange }
    elseif ($pct -ge 50) { return $yellow }
    else { return $green }
}

# ===== OAuth token resolution =====
function Get-OAuthToken {
    # 1. Explicit env var override
    if ($env:CLAUDE_CODE_OAUTH_TOKEN) {
        return $env:CLAUDE_CODE_OAUTH_TOKEN
    }

    # 2. Windows Credential Manager (via cmdkey/CredentialManager)
    try {
        if (Get-Command "cmdkey.exe" -ErrorAction SilentlyContinue) {
            # Try reading from Windows Credential Manager using PowerShell
            $credPath = Join-Path $env:LOCALAPPDATA "Claude Code\credentials.json"
            if (Test-Path $credPath) {
                $creds = Get-Content $credPath -Raw | ConvertFrom-Json
                $token = $creds.claudeAiOauth.accessToken
                if ($token -and $token -ne "null") { return $token }
            }
        }
    } catch {}

    # 3. Credentials file (cross-platform fallback)
    $credsFile = Join-Path $env:USERPROFILE ".claude\.credentials.json"
    if (Test-Path $credsFile) {
        try {
            $creds = Get-Content $credsFile -Raw | ConvertFrom-Json
            $token = $creds.claudeAiOauth.accessToken
            if ($token -and $token -ne "null") { return $token }
        } catch {}
    }

    return $null
}

# ===== Profile cache (email) =====
$profileCacheFile = Join-Path $env:TEMP "claude\statusline-profile-cache.json"
$profileCacheMaxAge = 3600
$email = ""
$needsProfileRefresh = $true

$null = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP "claude") -ErrorAction SilentlyContinue

if (Test-Path $profileCacheFile) {
    $profileAge = ((Get-Date) - (Get-Item $profileCacheFile).LastWriteTime).TotalSeconds
    if ($profileAge -lt $profileCacheMaxAge) { $needsProfileRefresh = $false }
    try { $email = (Get-Content $profileCacheFile -Raw | ConvertFrom-Json).account.email } catch {}
}

if ($needsProfileRefresh) {
    $pToken = Get-OAuthToken
    if ($pToken) {
        try {
            $pHeaders = @{
                "Accept"         = "application/json"
                "Content-Type"   = "application/json"
                "Authorization"  = "Bearer $pToken"
                "anthropic-beta" = "oauth-2025-04-20"
                "User-Agent"     = "claude-code/2.1.34"
            }
            $pResp = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/profile" `
                -Headers $pHeaders -Method Get -TimeoutSec 10 -ErrorAction Stop
            $email = $pResp.account.email
            $pResp | ConvertTo-Json -Depth 10 | Set-Content $profileCacheFile -Force
        } catch {}
    }
}

# ===== Extract data from JSON =====
$data = $input | ConvertFrom-Json

$modelName = if ($data.model.display_name) { $data.model.display_name } else { "Claude" }

# Context window
$size = if ($data.context_window.context_window_size) { [long]$data.context_window.context_window_size } else { 200000 }
if ($size -eq 0) { $size = 200000 }

# Token usage
$inputTokens = if ($data.context_window.current_usage.input_tokens) { [long]$data.context_window.current_usage.input_tokens } else { 0 }
$cacheCreate = if ($data.context_window.current_usage.cache_creation_input_tokens) { [long]$data.context_window.current_usage.cache_creation_input_tokens } else { 0 }
$cacheRead   = if ($data.context_window.current_usage.cache_read_input_tokens) { [long]$data.context_window.current_usage.cache_read_input_tokens } else { 0 }
$current = $inputTokens + $cacheCreate + $cacheRead

$usedTokens  = Format-Tokens $current
$totalTokens = Format-Tokens $size

if ($size -gt 0) {
    $pctUsed = [math]::Floor($current * 100 / $size)
} else {
    $pctUsed = 0
}
$pctRemain = 100 - $pctUsed

$usedComma   = Format-Commas $current
$remainComma = Format-Commas ($size - $current)

# Check reasoning effort
$effortLevel = "medium"
if ($env:CLAUDE_CODE_EFFORT_LEVEL) {
    $effortLevel = $env:CLAUDE_CODE_EFFORT_LEVEL
} else {
    $settingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
    if (Test-Path $settingsPath) {
        try {
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            if ($settings.effortLevel) { $effortLevel = $settings.effortLevel }
        } catch {}
    }
}

# ===== Build single-line output =====
$out = ""
$out += "${blue}${modelName}${reset}"

# Current working directory
$cwd = $data.cwd
if ($cwd) {
    $displayDir = Split-Path $cwd -Leaf
    $gitBranch = $null
    try {
        $gitBranch = git -C $cwd rev-parse --abbrev-ref HEAD 2>$null
    } catch {}
    $out += " ${dim}|${reset} "
    $out += "${cyan}${displayDir}${reset}"
    if ($gitBranch) {
        $out += "${dim}@${reset}${green}${gitBranch}${reset}"
        try {
            $numstat = git -C $cwd diff --numstat 2>$null
            if ($numstat) {
                $added = 0; $deleted = 0
                foreach ($line in $numstat) {
                    $parts = $line -split '\s+'
                    if ($parts[0] -match '^\d+$') { $added += [int]$parts[0] }
                    if ($parts[1] -match '^\d+$') { $deleted += [int]$parts[1] }
                }
                if (($added + $deleted) -gt 0) {
                    $out += " ${dim}(${reset}${green}+${added}${reset} ${red}-${deleted}${reset}${dim})${reset}"
                }
            }
        } catch {}
    }
}

if ($email) { $out += " ${dim}|${reset} ${dim}${email}${reset}" }
$out += "\n"
$out += "${orange}${usedTokens}/${totalTokens}${reset} ${dim}(${reset}${green}${pctUsed}%${reset}${dim})${reset}"
$out += " ${dim}|${reset} "
$out += "effort: "
switch ($effortLevel) {
    "low"    { $out += "${dim}low${reset}" }
    "medium" { $out += "${orange}med${reset}" }
    default  { $out += "${green}high${reset}" }
}
$out += "\n"

# ===== Usage limits with caching =====
$cacheDir = Join-Path $env:TEMP "claude"
$cacheFile = Join-Path $cacheDir "statusline-usage-cache.json"
$cacheMaxAge = 60  # seconds between API calls

if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }

$needsRefresh = $true
$usageData = $null

# Check cache
if (Test-Path $cacheFile) {
    $cacheMtime = (Get-Item $cacheFile).LastWriteTime
    $cacheAge = ((Get-Date) - $cacheMtime).TotalSeconds
    if ($cacheAge -lt $cacheMaxAge) {
        $needsRefresh = $false
        $usageData = Get-Content $cacheFile -Raw
    }
}

# Fetch fresh data if cache is stale
if ($needsRefresh) {
    $token = Get-OAuthToken
    if ($token) {
        try {
            $headers = @{
                "Accept"         = "application/json"
                "Content-Type"   = "application/json"
                "Authorization"  = "Bearer $token"
                "anthropic-beta" = "oauth-2025-04-20"
                "User-Agent"     = "claude-code/2.1.34"
            }
            $response = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" `
                -Headers $headers -Method Get -TimeoutSec 10 -ErrorAction Stop
            $usageData = $response | ConvertTo-Json -Depth 10
            $usageData | Set-Content $cacheFile -Force
        } catch {}
    }
    # Fall back to stale cache
    if (-not $usageData -and (Test-Path $cacheFile)) {
        $usageData = Get-Content $cacheFile -Raw
    }
}

# Format ISO reset time to compact local time
function Format-ResetTime([string]$isoStr, [string]$style) {
    if (-not $isoStr -or $isoStr -eq "null") { return $null }
    try {
        $dt = [DateTimeOffset]::Parse($isoStr).LocalDateTime
        switch ($style) {
            "time"     { return $dt.ToString("h:mmtt").ToLower() }
            "datetime" { return $dt.ToString("MMM d, h:mmtt").ToLower() }
            default    { return $dt.ToString("MMM d").ToLower() }
        }
    } catch { return $null }
}

$sep = " ${dim}|${reset} "

if ($usageData) {
    try {
        $usage = if ($usageData -is [string]) { $usageData | ConvertFrom-Json } else { $usageData }

        # ---- 5-hour (current) ----
        $fiveHourPct = [math]::Floor([double]($usage.five_hour.utilization ?? 0))
        $fiveHourResetIso = $usage.five_hour.resets_at
        $fiveHourReset = Format-ResetTime $fiveHourResetIso "time"
        $fiveHourColor = Get-UsageColor $fiveHourPct

        $out += "${white}5h${reset} ${fiveHourColor}${fiveHourPct}%${reset}"
        if ($fiveHourReset) { $out += " ${dim}@${fiveHourReset}${reset}" }

        # ---- 7-day (weekly) ----
        $sevenDayPct = [math]::Floor([double]($usage.seven_day.utilization ?? 0))
        $sevenDayResetIso = $usage.seven_day.resets_at
        $sevenDayReset = Format-ResetTime $sevenDayResetIso "datetime"
        $sevenDayColor = Get-UsageColor $sevenDayPct

        $out += "${sep}${white}7d${reset} ${sevenDayColor}${sevenDayPct}%${reset}"
        if ($sevenDayReset) { $out += " ${dim}@${sevenDayReset}${reset}" }

        # ---- Extra usage ----
        $extraEnabled = $usage.extra_usage.is_enabled
        if ($extraEnabled -eq $true) {
            $extraPct = [math]::Floor([double]($usage.extra_usage.utilization ?? 0))
            $extraUsedRaw = $usage.extra_usage.used_credits
            $extraLimitRaw = $usage.extra_usage.monthly_limit

            if ($null -ne $extraUsedRaw -and $null -ne $extraLimitRaw) {
                $extraUsed = "{0:F2}" -f ([double]$extraUsedRaw / 100)
                $extraLimit = "{0:F2}" -f ([double]$extraLimitRaw / 100)
                $extraColor = Get-UsageColor $extraPct
                $out += "\n${white}extra${reset} ${extraColor}`$${extraUsed}/`$${extraLimit}${reset}"
            } else {
                $out += "\n${white}extra${reset} ${green}enabled${reset}"
            }
        }
    } catch {}
}

# ===== Claude service status (status.claude.com) =====
$statusCacheFile = Join-Path $env:TEMP "claude\statusline-status-cache.json"
$statusCacheMaxAge = 60
$claudeStatusData = $null

if (Test-Path $statusCacheFile) {
    $statusAge = ((Get-Date) - (Get-Item $statusCacheFile).LastWriteTime).TotalSeconds
    if ($statusAge -lt $statusCacheMaxAge) {
        try { $claudeStatusData = Get-Content $statusCacheFile -Raw | ConvertFrom-Json } catch {}
    }
}

if (-not $claudeStatusData) {
    try {
        $claudeStatusData = Invoke-RestMethod -Uri "https://status.claude.com/api/v2/summary.json" `
            -Method Get -TimeoutSec 10 -ErrorAction Stop
        $claudeStatusData | ConvertTo-Json -Depth 10 | Set-Content $statusCacheFile -Force
    } catch {}
}

if ($claudeStatusData) {
    $sIndicator = $claudeStatusData.status.indicator
    switch ($sIndicator) {
        "none"     { $sColor = $green;  $sLabel = "ok" }
        "minor"    { $sColor = $yellow; $sLabel = "degraded" }
        "major"    { $sColor = $orange; $sLabel = "degraded" }
        "critical" { $sColor = $red;    $sLabel = "outage" }
        default    { $sColor = $dim;    $sLabel = "unknown" }
    }
    $out += "\n${white}claude.ai${reset} ${sColor}${sLabel}${reset}"
    if ($sIndicator -ne "none") {
        $sComps = ($claudeStatusData.components |
            Where-Object { $_.status -ne "operational" } |
            Select-Object -ExpandProperty name) -join ", "
        if ($sComps) { $out += " ${dim}(${reset}${sComps}${dim})${reset}" }
    }
}

# Output single line
Write-Host -NoNewline $out

exit 0

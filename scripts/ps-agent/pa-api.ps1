# prompt_agent — tenant-API helpers (Windows)
#
# Mirrors pa-api.sh. Credentials come from env vars or config.toml.
# Requires: curl.exe (Windows 10+), jq (winget install jqlang.jq)
#
# Usage:
#   pa-api whoami                       # show resolved domain + masked app-id
#   pa-api get-apps                     # GET /api/protect-native-apps/get_apps
#   pa-api get-secrets [domain]         # GET /api/protect-native-apps/get_secrets_policy
#   pa-api get-policy <url> [email]     # POST /api/employee/evaluate-rule
#   pa-api heartbeat                    # POST /api/protect-native-apps/heartbeat
#   pa-api apps-summary                 # histogram of apps in get_apps
#   pa-api apps-by-name <app>           # list URL patterns for one app
#   pa-api match <url>                  # which app would the agent classify a URL as?
#   pa-api check <url> [email]          # classification + per-domain rule
#   pa-api genai-check <domain>...      # run bin/check-domain-in-genai-list.ps1
#   pa-api curl <path> [curl args...]   # authed curl to https://${domain}<path>
#   pa-api env                          # print $env: lines for PROMPT_API_*

$_PA_API_DIR = $PSScriptRoot

# Add bin/ to PATH for this session
if ($env:PATH -notlike "*$_PA_API_DIR\bin*") {
    $env:PATH = "$_PA_API_DIR\bin;$env:PATH"
}

# ── credentials resolution ───────────────────────────────────────────────────
# Resolution order (mirrors src/common/config.py):
#   1) Env: PROMPT_API_DOMAIN / PROMPT_API_KEY
#   2) Agent config.toml: C:\ProgramData\Prompt\config.toml
function _pa_api_load_creds {
    $script:PA_API_DOMAIN = $env:PROMPT_API_DOMAIN
    $script:PA_API_KEY    = $env:PROMPT_API_KEY
    $script:PA_API_SOURCE = if ($env:PROMPT_API_DOMAIN) { "env" } else { "" }

    if (-not $PA_API_DOMAIN) {
        $cfg = "C:\ProgramData\Prompt\config.toml"
        if (Test-Path $cfg) {
            $content = Get-Content $cfg -Raw -ErrorAction SilentlyContinue
            if ($content) {
                $script:PA_API_DOMAIN = [regex]::Match($content, '(?m)^\s*domain\s*=\s*(.+)$').Groups[1].Value.Trim().Trim('"')
                $script:PA_API_KEY    = [regex]::Match($content, '(?m)^\s*api_key\s*=\s*(.+)$').Groups[1].Value.Trim().Trim('"')
                if ($PA_API_DOMAIN) { $script:PA_API_SOURCE = "config.toml" }
            }
        }
    }

    return ($PA_API_DOMAIN -and $PA_API_KEY)
}

# ── core curl wrapper ─────────────────────────────────────────────────────────
function _pa_api_curl {
    param([string]$Path, [string[]]$ExtraArgs)
    if (-not (_pa_api_load_creds)) {
        Write-Error "pa-api: failed to resolve domain/api_key"; return
    }
    curl.exe -fsS "https://$PA_API_DOMAIN$Path" `
        -H "app-id: $PA_API_KEY" `
        -H "content-type: application/json" `
        @ExtraArgs
}

function _pa_api_format {
    param([string]$Data, [switch]$Raw)
    if ($Raw -or $env:PA_API_RAW -eq "1") { return $Data }
    if (Get-Command jq -ErrorAction SilentlyContinue) {
        $Data | jq .
    } else {
        $Data | ConvertFrom-Json | ConvertTo-Json -Depth 20
    }
}

# ── subcommands ───────────────────────────────────────────────────────────────
function pa-api {
    param(
        [string]$Command,
        [switch]$Raw,
        [Parameter(ValueFromRemainingArguments)][string[]]$Rest
    )

    if ($Raw) { $env:PA_API_RAW = "1" } else { $env:PA_API_RAW = "0" }

    switch ($Command) {
        { $_ -in "whoami","env" } {
            if (-not (_pa_api_load_creds)) { Write-Error "pa-api: no credentials found"; return }
            if ($Command -eq "env") {
                Write-Output "`$env:PROMPT_API_DOMAIN = '$PA_API_DOMAIN'"
                Write-Output "`$env:PROMPT_API_KEY    = '$PA_API_KEY'"
            } else {
                Write-Output "domain : $PA_API_DOMAIN"
                Write-Output "app-id : $($PA_API_KEY.Substring(0,6))…$($PA_API_KEY.Substring($PA_API_KEY.Length-4))"
                Write-Output "source : $PA_API_SOURCE"
            }
        }

        "get-apps" {
            _pa_api_format (_pa_api_curl "/api/protect-native-apps/get_apps") -Raw:$Raw
        }

        "get-secrets" {
            $q = if ($Rest[0]) { "?domain=$([uri]::EscapeDataString($Rest[0]))" } else { "" }
            _pa_api_format (_pa_api_curl "/api/protect-native-apps/get_secrets_policy$q") -Raw:$Raw
        }

        "heartbeat" {
            _pa_api_format (_pa_api_curl "/api/protect-native-apps/heartbeat" @("-X","POST","-d",'{"configTimestamps":{}}')) -Raw:$Raw
        }

        "get-policy" {
            if (-not $Rest[0]) { Write-Error "usage: pa-api get-policy <url> [email]"; return }
            $url   = $Rest[0]
            $email = if ($Rest[1]) { $Rest[1] } elseif ($env:PROMPT_USER_EMAIL) { $env:PROMPT_USER_EMAIL } else { $env:USERNAME }
            $sensor = @{ version = ($env:PROMPT_AGENT_VERSION ?? "dev"); os = "Windows"; os_version = [System.Environment]::OSVersion.VersionString; machine = $env:COMPUTERNAME } | ConvertTo-Json -Compress
            $body   = @{ userInfo = @{ email = $email }; sensorData = ($sensor | ConvertFrom-Json); requestUrl = $url } | ConvertTo-Json -Compress
            _pa_api_format (_pa_api_curl "/api/employee/evaluate-rule" @("-X","POST","-d",$body)) -Raw:$Raw
        }

        "apps-summary" {
            $apps = _pa_api_curl "/api/protect-native-apps/get_apps"
            if (Get-Command jq -ErrorAction SilentlyContinue) {
                $apps | jq -r 'to_entries | group_by(.value) | map({app: .[0].value, count: length}) | sort_by(-.count) | .[] | "\(.count)\t\(.app)"'
            } else {
                ($apps | ConvertFrom-Json).PSObject.Properties |
                    Group-Object Value | Sort-Object Count -Descending |
                    Format-Table @{L="Count";E={$_.Count}}, @{L="App";E={$_.Name}} -AutoSize
            }
        }

        "apps-by-name" {
            if (-not $Rest[0]) { Write-Error "usage: pa-api apps-by-name <app-name>"; return }
            $apps = _pa_api_curl "/api/protect-native-apps/get_apps"
            if (Get-Command jq -ErrorAction SilentlyContinue) {
                $apps | jq -r --arg name $Rest[0] 'to_entries[] | select(.value == $name) | .key'
            } else {
                ($apps | ConvertFrom-Json).PSObject.Properties | Where-Object Value -eq $Rest[0] | Select-Object -ExpandProperty Name
            }
        }

        "match" {
            if (-not $Rest[0]) { Write-Error "usage: pa-api match <url>"; return }
            $url  = $Rest[0]
            $apps = _pa_api_curl "/api/protect-native-apps/get_apps"
            if (Get-Command jq -ErrorAction SilentlyContinue) {
                $result = $apps | jq -r --arg url $url '
                    to_entries
                    | (map(select(.key == $url)) + map(select(.key != $url and (.key as $re | $url | test($re)))))
                    | .[0] // empty | "\(.value)\t\(.key)"'
                if ($result) {
                    $parts = $result -split "`t"
                    Write-Output "app    : $($parts[0])"
                    Write-Output "pattern: $($parts[1])"
                } else {
                    Write-Error "no match — should_inspect_app($url) would return None"
                }
            }
        }

        "check" {
            if (-not $Rest[0]) { Write-Error "usage: pa-api check <url> [email]"; return }
            $url   = $Rest[0]
            $email = if ($Rest[1]) { $Rest[1] } elseif ($env:PROMPT_USER_EMAIL) { $env:PROMPT_USER_EMAIL } else { $env:USERNAME }
            $apps  = _pa_api_curl "/api/protect-native-apps/get_apps"

            $matchLine = if (Get-Command jq -ErrorAction SilentlyContinue) {
                $apps | jq -r --arg url $url '
                    to_entries
                    | (map(select(.key == $url)) + map(select(.key != $url and (.key as $re | $url | test($re)))))
                    | .[0] // empty | "\(.value)\t\(.key)"'
            }
            $app   = if ($matchLine) { ($matchLine -split "`t")[0] } else { "(no match)" }
            $regex = if ($matchLine) { ($matchLine -split "`t")[1] } else { "—" }

            $sensor = @{ version = ($env:PROMPT_AGENT_VERSION ?? "dev"); os = "Windows"; os_version = [System.Environment]::OSVersion.VersionString; machine = $env:COMPUTERNAME } | ConvertTo-Json -Compress
            $body   = @{ userInfo = @{ email = $email }; sensorData = ($sensor | ConvertFrom-Json); requestUrl = $url } | ConvertTo-Json -Compress
            $policy = _pa_api_curl "/api/employee/evaluate-rule" @("-X","POST","-d",$body)

            if (-not $policy -or $policy -eq "null") {
                Write-Output "url       : $url"
                Write-Output "app       : $app"
                Write-Output "regex     : $regex"
                Write-Output "action    : (null)"
                Write-Output "logAction : —"
                Write-Output "mode      : —"
                Write-Output "policyId  : —"
                Write-Output "note      : evaluate-rule returned null → agent will drop the request"
            } else {
                $p      = $policy | ConvertFrom-Json
                $action = $p.ruleInfo.action ?? "—"
                $lvo    = $p.ruleInfo.isLogViolationsOnly
                $mode   = $p.policyInfo.inspectionMode ?? "—"
                $pid    = $p.policyInfo.policyId ?? "—"
                $logAction = if ($lvo -eq $true) { "ViolationsOnly  (isLogViolationsOnly=true)" } elseif ($lvo -eq $false) { "All             (isLogViolationsOnly=false)" } else { "—" }
                Write-Output "url       : $url"
                Write-Output "app       : $app"
                Write-Output "regex     : $regex"
                Write-Output "action    : $action"
                Write-Output "logAction : $logAction"
                Write-Output "mode      : $mode"
                Write-Output "policyId  : $pid"
            }
        }

        "genai-check" {
            if (-not $Rest[0]) { Write-Error "usage: pa-api genai-check <domain> [domain...]"; return }
            if (-not (_pa_api_load_creds)) { Write-Error "pa-api: no credentials found"; return }
            $env:PROMPT_API_DOMAIN = $PA_API_DOMAIN
            $env:PROMPT_API_KEY    = $PA_API_KEY
            & "$_PA_API_DIR\bin\check-domain-in-genai-list.ps1" @Rest
        }

        "curl" {
            if (-not $Rest[0]) { Write-Error "usage: pa-api curl <path> [curl-args...]"; return }
            _pa_api_curl $Rest[0] $Rest[1..$Rest.Count]
        }

        { $_ -in "","help","-h","--help" } {
            Write-Output @"
pa-api — tenant API helpers (uses agent's domain + app-id)

  whoami                  show resolved domain + masked app-id + source
  env                     print `$env: lines for PROMPT_API_* (eval-friendly)
  get-apps                GET /api/protect-native-apps/get_apps  (INSPECT_URLS_MAP)
  get-secrets [domain]    GET /api/protect-native-apps/get_secrets_policy
  get-policy <url> [email]  POST /api/employee/evaluate-rule (per-domain policy)
  heartbeat               POST /api/protect-native-apps/heartbeat
  apps-summary            histogram of apps in get_apps
  apps-by-name <app>      URL patterns mapped to a given app
  match <url>             which app would should_inspect_app(url) return?
  check <url> [email]     classification + per-domain rule (app/action/logAction/mode)
  genai-check <domain>... run bin\check-domain-in-genai-list.ps1
  curl <path> [args...]   generic authed curl to https://`${domain}<path>

Add -Raw before args to skip JSON formatting.
"@
        }

        default {
            Write-Error "pa-api: unknown subcommand '$Command' (try 'pa-api help')"
        }
    }
}

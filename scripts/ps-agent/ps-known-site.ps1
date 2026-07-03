# ps-known-site — query the global.prompt.security UI API to check whether a
# URL matches any "Known Sites" rule (genAi catalogue + tenant custom rules).
#
# Usage:
#   $env:PROMPT_JWT = '<fronteggSessionToken value>'
#   ps-known-site https://browser-intake-datadoghq.com/api/v2/rum
#
# Get a fresh JWT:
#   1. Open https://global.prompt.security in browser (logged in)
#   2. DevTools → Application → Cookies → fronteggSessionToken → copy value

function ps-known-site {
    param([string]$Url)

    if (-not $env:PROMPT_JWT) {
        Write-Error "[ps-known-site] error: missing environment variable PROMPT_JWT"
        Write-Host "  -> `$env:PROMPT_JWT = '<fronteggSessionToken value>'"
        Write-Host "  -> get it from https://global.prompt.security (DevTools -> Cookies)"
        return
    }

    if (-not $Url) {
        Write-Error "usage: ps-known-site <url>"
        return
    }

    $body = "{`"url`":`"$Url`"}"
    curl.exe -fsS 'https://global.prompt.security/api/gen-ai/known-sites/test-url' `
        -H 'accept: application/json' `
        -H 'content-type: application/json' `
        -b "fronteggSessionToken=$env:PROMPT_JWT" `
        -H 'origin: https://global.prompt.security' `
        --data-raw $body | jq .
}

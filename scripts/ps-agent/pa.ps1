# prompt_agent helper (Windows)
#
# Usage: pa {status|logout|uninstall|start|stop|restart|logs|edit}
#   par   alias for pa restart

function pa {
    param([string]$Command)

    $bin  = "$env:ProgramFiles\PromptSecurity\prompt_agent.exe"
    $svc  = "PromptService"
    $logs = "$env:ProgramFiles\PromptSecurity\logs\service_logs.log"
    $cfg  = "C:\ProgramData\Prompt\config.toml"

    switch ($Command) {
        "status"    { & $bin status }
        "logout"    { & $bin logout }
        "uninstall" { & $bin uninstall }
        "start"     { Start-Service $svc }
        "stop"      { Stop-Service $svc }
        "restart"   { Restart-Service $svc }
        "logs"      { Get-Content $logs -Wait }
        "edit"      {
            attrib -r -s -h $cfg
            try { Start-Process -Wait notepad $cfg }
            finally { attrib +r +s +h $cfg }
        }
        default {
            Write-Error "usage: pa {status|logout|uninstall|start|stop|restart|logs|edit}"
        }
    }
}

function par { pa restart }

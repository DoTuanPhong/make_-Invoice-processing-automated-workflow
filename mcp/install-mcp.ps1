<#
.SYNOPSIS
    Cai Make MCP server vao Cursor, Claude Desktop va Kilo (VS Code).

.DESCRIPTION
    Hoat dong voi 2 phuong thuc cua Make:
    - MCP Toolbox (khuyen nghich): Server URL = https://<ZONE>/mcp/server/<TOOLBOX_ID>, key = Toolbox Key
      (tao trong Make -> MCP toolboxes -> Create toolbox)
    - MCP token: Server URL = https://<ZONE>/mcp, key = MCP token
      (tao trong Make -> Profile -> API access -> Tokens -> Add token, chon scope mcp:use)

    Chay script, nhap Server URL va Key khi duoc hoi. Script ghi/merge config vao:
    - %APPDATA%\Cursor\mcp.json                        (url + Authorization header)
    - %APPDATA%\Claude\claude_desktop_config.json       (mcp-remote proxy + --header)
    - %USERPROFILE%\.config\kilo\kilo.json            (Kilo: mcp > make, type remote)

.EXAMPLE
    .\install-mcp.ps1 -ServerUrl "https://us2.make.com/mcp/server/707ebff8-71e4-40ba-a992-6f7219483412" -AuthKey "tb_xxxxxxxx"

.EXAMPLE
    .\install-mcp.ps1 -ServerUrl "https://us2.make.com/mcp" -AuthKey "tk_xxxxxxxx" -SkipClaudeDesktop
#>
param(
    [string]$ServerUrl,
    [string]$AuthKey,
    [switch]$SkipClaudeDesktop
)

$ErrorActionPreference = 'Stop'

if (-not $ServerUrl) { $ServerUrl = Read-Host "Nhap MCP Server URL (vd: https://us2.make.com/mcp/server/<TOOLBOX_ID> hoac https://us2.make.com/mcp)" }
if (-not $AuthKey) { $AuthKey = Read-Host "Nhap Key (Toolbox Key hoac MCP token)" }

if ($ServerUrl -notmatch '^https://[a-z0-9-]+\.make\.com/mcp') {
    Write-Warning "Server URL khong dung dinh dang. Phai la https://<ZONE>.make.com/mcp/... Ban nhap: $ServerUrl"
    exit 1
}

$authHeader = "Bearer $AuthKey"

function Write-JsonConfig {
    param(
        [string]$ConfigPath,
        [string]$Section,
        [string]$ServerName,
        [hashtable]$ServerConfig
    )

    $config = @{}
    if (Test-Path $ConfigPath) {
        try {
            $existing = Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
            if ($null -ne $existing) { $config = $existing }
        }
        catch {
            $backup = "$ConfigPath.bak"
            Write-Warning "Config hien tai tai $ConfigPath loi dang JSON, se tao moi. Backup thanh $backup"
            Copy-Item $ConfigPath $backup -Force
        }
    }

    if (-not $config.ContainsKey($Section)) { $config[$Section] = @{} }
    $config[$Section][$ServerName] = $ServerConfig

    $parent = Split-Path $ConfigPath -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $json = $config | ConvertTo-Json -Depth 20
    Set-Content -Path $ConfigPath -Value $json -Encoding UTF8
    Write-Host "OK da ghi: $ConfigPath" -ForegroundColor Green
}

# Cursor: remote MCP voi url + Authorization header
Write-JsonConfig -ConfigPath (Join-Path $env:APPDATA 'Cursor\mcp.json') `
    -Section 'mcpServers' -ServerName 'make' `
    -ServerConfig @{
        url     = $ServerUrl
        headers = @{ Authorization = $authHeader }
    }

# Claude Desktop: dung mcp-remote proxy, truyen header qua --header
if (-not $SkipClaudeDesktop) {
    Write-JsonConfig -ConfigPath (Join-Path $env:APPDATA 'Claude\claude_desktop_config.json') `
        -Section 'mcpServers' -ServerName 'make' `
        -ServerConfig @{
            command = 'npx'
            args    = @('-y', 'mcp-remote', $ServerUrl, '--header', "Authorization: $authHeader")
        }
}

# Kilo (VS Code extension): config trong kilo.json, key "mcp", server type "remote"
Write-JsonConfig -ConfigPath (Join-Path $env:USERPROFILE '.config\kilo\kilo.json') `
    -Section 'mcp' -ServerName 'make' `
    -ServerConfig @{
        type    = 'remote'
        url     = $ServerUrl
        headers = @{ Authorization = $authHeader }
        enabled = $true
    }

Write-Host ""
Write-Host "Hoan tat. Server URL: $ServerUrl" -ForegroundColor Cyan
Write-Host "Tiep theo:" -ForegroundColor Cyan
Write-Host "  1. Kiem tra ket noi: trong Kilo/Cursor chat hoi 'What tools do you have from Make MCP server?'" -ForegroundColor Cyan
Write-Host "  2. Neu loi 401/Access denied: key sai - kiem tra lai Toolbox Key hoac MCP token" -ForegroundColor Cyan
Write-Host "  3. Reload VS Code window (Ctrl+Shift+P -> Developer: Reload Window) de Kilo nap MCP server" -ForegroundColor Cyan
Write-Host "  4. Xem huong dan tao scenario: workflow\05-mcp-build-prompt.md" -ForegroundColor Cyan

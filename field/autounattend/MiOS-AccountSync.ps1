# AI-hint: Windows background account synchronization script that queries the pgvector database and synchronizes accounts to the local SAM database.
# AI-related: MiOS-Provision.lib.ps1, mios.toml
# 'MiOS' -- Windows DB->SAM live account-sync service

$logPath = "C:\ProgramData\MiOS\MiOS-AccountSync.log"
mkdir (Split-Path $logPath -Parent) -Force -ErrorAction SilentlyContinue

function Write-Log {
    param($Msg)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Msg"
    Write-Output $line
    $line | Out-File -FilePath $logPath -Append -Encoding utf8
}

Write-Log "Starting Account Sync Service loop"

# Loop periodically to sync accounts
while ($true) {
    try {
        # Check if podman machine / WSL is running and accessible
        $wslStatus = wsl.exe -d podman-MiOS-DEV --exec /bin/bash -c "echo 'ready'" 2>$null
        if ($wslStatus -ne "ready") {
            Start-Sleep -Seconds 10
            continue
        }

        # Query account table and aliases from pgvector
        $envelope = @{
            statements = @(
                @{
                    sql = "SELECT name AS username, display, groups, is_admin, enabled FROM account WHERE enabled = true AND (os_targets = 'both' OR os_targets = 'windows') UNION SELECT a.alias_username AS username, c.display_name AS display, '' AS groups, false AS is_admin, a.is_active AS enabled FROM mios_identity.aliases a JOIN mios_identity.canonical_users c ON a.canonical_id = c.id WHERE a.is_active = true"
                    params = @()
                }
            )
        } | ConvertTo-Json -Compress

        # Escape double quotes for bash execution
        $jsonIn = $envelope -replace '"', '\"'
        $queryCmd = "echo '$jsonIn' | python3 /usr/libexec/mios/mios-pg-query --exec-json"
        $out = wsl.exe -d podman-MiOS-DEV --exec /bin/bash -c $queryCmd 2>$null

        if ($LASTEXITCODE -eq 0 -and $out) {
            $rows = $out -split "`n" | Where-Object { $_.Trim() }
            $dbUsers = @{}

            foreach ($row in $rows) {
                $fields = $row -split "`t"
                if ($fields.Count -ge 5) {
                    $name     = $fields[0].Trim()
                    $display  = $fields[1].Trim()
                    $groups   = $fields[2].Trim()
                    $isAdmin  = $fields[3].Trim() -eq "t"
                    $enabled  = $fields[4].Trim() -eq "t"

                    $dbUsers[$name] = @{
                        Display = $display
                        Groups  = $groups
                        IsAdmin = $isAdmin
                        Enabled = $enabled
                    }

                    # Check if local user exists
                    $localUser = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
                    if (-not $localUser) {
                        Write-Log "Creating local user: $name"
                        # Create local user with no password or a randomized secure one initially
                        $randomPassword = [char[]](33..126) | Get-Random -Count 24 | ForEach-Object { [char]$_ }
                        $securePassword = ConvertTo-SecureString ($randomPassword -join "") -AsPlainText -Force
                        New-LocalUser -Name $name -Password $securePassword -Description $display -FullName $display -ErrorAction SilentlyContinue
                    }

                    # Sync status (enable/disable)
                    if ($enabled) {
                        Enable-LocalUser -Name $name -ErrorAction SilentlyContinue
                    } else {
                        Disable-LocalUser -Name $name -ErrorAction SilentlyContinue
                    }

                    # Sync groups (Administrators / Users)
                    if ($isAdmin) {
                        # Add to Administrators if not already there
                        Add-LocalGroupMember -Group "Administrators" -Member $name -ErrorAction SilentlyContinue
                    } else {
                        # Remove from Administrators if member
                        Remove-LocalGroupMember -Group "Administrators" -Member $name -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
    catch {
        Write-Log "Error in sync loop: $_"
    }

    # Interval delay
    Start-Sleep -Seconds 30
}

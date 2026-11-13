<#
NetScaler pre-upgrade disk cleanup.

Checks /var and /flash on each appliance, then frees space in /var:
  /var/nsinstall      old build folders and .tgz installer files
  /var/log            old rotated logs (current logs are never touched)
  /var/nslog          numbered archived logs such as newslog.12.tar.gz
  /var/ns_sys_backup  makes a fresh backup first, then removes the older ones
checks again and reports PASS or FAIL. Never starts an upgrade.

Runs on the PowerShell built into Windows (5.1) and on PowerShell 7.
Opens a settings window by default. For scripted use:
    .\NetScalerCleanup.ps1 -Cli [-Real] [-Username nsroot]
(the password is asked, or read from the NS_PASSWORD environment variable)
#>
[CmdletBinding()]
param(
    [switch]$Cli,
    [switch]$Real,
    [string]$Username,
    [string]$SettingsPath
)

$ErrorActionPreference = 'Stop'

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host "PowerShell on this PC runs in restricted mode ($($ExecutionContext.SessionState.LanguageMode))."
    Write-Host "The tool needs normal mode. Please ask IT to allow this script."
    exit 1
}

$Root = $PSScriptRoot
if (-not $SettingsPath) { $SettingsPath = Join-Path $Root 'NetScalerCleanup.settings.json' }
$ReportDir = Join-Path $Root 'reports'

# appliances use self-signed certificates; accept them for these calls only
if (-not ('NsTls' -as [type])) {
    Add-Type -TypeDefinition @"
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class NsTls {
    static bool Accept(object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) { return true; }
    public static readonly RemoteCertificateValidationCallback Callback = Accept;
}
"@
}
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# keeps the window responsive during long steps; replaced when the GUI starts
$script:Pump = { }

# ---------------------------------------------------------------- settings

function Get-DefaultSettings {
    [ordered]@{
        appliances         = @()
        username           = 'nsroot'
        protocol           = 'auto'
        cleanup_folders    = @('/var/nsinstall')
        keep_running_build = $false
        clean_logs         = $true
        clean_nslogs       = $true
        replace_backup     = $true
        backup_level       = 'full'
        keep_builds        = @()
        always_keep        = @('adc.version', 'installns_state*')
        minimum_var_mb     = 7168
        minimum_flash_mb   = 200
    }
}

function Read-Settings {
    $s = Get-DefaultSettings
    if (Test-Path $SettingsPath) {
        $saved = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) { $s[$p.Name] = $p.Value }
    }
    $s.backup_level = if ("$($s.backup_level)" -match '^\s*basic\s*$') { 'basic' } else { 'full' }
    foreach ($k in 'appliances', 'cleanup_folders', 'keep_builds', 'always_keep') {
        $s[$k] = @($s[$k] | Where-Object { $_ -and "$_".Trim() } | ForEach-Object { "$_".Trim() })
    }
    $s
}

function Save-Settings($s) {
    # the password is never written to disk
    $s | ConvertTo-Json -Depth 4 | Set-Content -Path $SettingsPath -Encoding UTF8
}

function Test-Settings($s) {
    if ($s.appliances.Count -eq 0) { return 'Add at least one appliance IP.' }
    if ($s.cleanup_folders.Count -eq 0) { return 'Add at least one folder to clean.' }
    foreach ($f in $s.cleanup_folders) {
        # hard limit: only subfolders of /var are ever touched
        if (-not $f.StartsWith('/var/') -or $f.TrimEnd('/') -eq '/var') {
            return "Folder '$f' is not allowed. Only subfolders of /var can be cleaned."
        }
    }
    $null
}

# ---------------------------------------------------------------- NITRO

function Invoke-Nitro($S, [string]$Method, [string]$Path, $Body, [int]$TimeoutMs = 60000) {
    try {
        $req = [System.Net.WebRequest]::Create($S.Base + $Path)
        $req.Method = $Method
        $req.Proxy = $null          # internal NSIPs are reached directly, never via a web proxy
        $req.Accept = 'application/json'
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        if ($S.Protocol -eq 'https') { $req.ServerCertificateValidationCallback = [NsTls]::Callback }
        if ($S.Token) { $req.Headers.Add('Cookie', "NITRO_AUTH_TOKEN=$($S.Token)") }
        if ($null -ne $Body) {
            $bytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 6 -Compress))
            $req.ContentType = 'application/json'
            $req.ContentLength = $bytes.Length
            $stream = $req.GetRequestStream()
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Close()
        }
        $resp = $req.GetResponse()
    }
    catch {
        $e = $_.Exception
        while ($e -and -not ($e -is [System.Net.WebException]) -and $e.InnerException) { $e = $e.InnerException }
        if ($e -is [System.Net.WebException] -and $e.Response) {
            $raw = (New-Object IO.StreamReader($e.Response.GetResponseStream())).ReadToEnd()
            $code = [int]$e.Response.StatusCode
            $msg = $raw
            try {
                $j = $raw | ConvertFrom-Json
                if ($j.message) { $msg = $j.message }
                if ($j.errorcode) { $msg = "[$($j.errorcode)] $msg" }
            } catch { }
            throw "$Method $Path failed ($code): $msg"
        }
        throw "cannot reach $($S.Host): $($e.Message)"
    }
    $reader = New-Object IO.StreamReader($resp.GetResponseStream())
    $raw = $reader.ReadToEnd()
    $reader.Close()
    $resp.Close()
    if (-not $raw.Trim()) { return [pscustomobject]@{} }
    $data = $raw | ConvertFrom-Json
    if ($data.errorcode -and $data.errorcode -ne 0) { throw "$Method $Path : $($data.message)" }
    $data
}

function Connect-NetScaler($NsHost, $Protocol, $User, $Pass) {
    $S = @{ Host = $NsHost; Protocol = $Protocol; Base = "${Protocol}://$NsHost/nitro/v1"; Token = $null }
    try {
        $r = Invoke-Nitro $S POST '/config/login' @{ login = @{ username = $User; password = $Pass; timeout = 900 } }
    }
    catch {
        if ("$_" -match '3816|factor') {
            throw 'this account needs a second login factor (2FA); use an account that logs in with a password only'
        }
        throw
    }
    if (-not $r.sessionid) { throw 'login returned no session id' }
    $S.Token = $r.sessionid
    $S
}

function Disconnect-NetScaler($S) {
    if (-not $S -or -not $S.Token) { return }
    try { Invoke-Nitro $S POST '/config/logout' @{ logout = @{} } | Out-Null } catch { }
    $S.Token = $null
}

function Get-RunningBuild($S) {
    $r = Invoke-Nitro $S GET '/config/nsversion'
    $text = "$(@($r.nsversion)[0].version)"
    if ($text -match 'NS(\d+\.\d+):\s*Build\s*(\d+\.\d+)') { return @("$($Matches[1])-$($Matches[2])", $text) }
    @($null, $text)
}

function Get-HaState($S) {
    try { $r = Invoke-Nitro $S GET '/config/hanode' } catch { return 'Unknown' }
    $nodes = @($r.hanode | Where-Object { $_ })
    if ($nodes.Count -eq 0) { return 'Standalone' }
    $local = $nodes | Where-Object { "$($_.id)" -eq '0' } | Select-Object -First 1
    if ($local -and $local.state) { return "$($local.state)" }
    'Standalone'
}

function Get-DiskSpace($S) {
    $sys = (Invoke-Nitro $S GET '/stat/system').system
    function Pick($names) {
        foreach ($n in $names) {
            $v = $sys.$n
            if ($null -ne $v -and "$v" -ne '') { return [double]$v }
        }
        $null
    }
    $space = @{
        FlashFree = Pick @('disk0avail', 'disk0_free')
        VarFree   = Pick @('disk1avail', 'disk1_free')
    }
    if ($null -eq $space.VarFree -or $null -eq $space.FlashFree) {
        # fail loudly rather than report 0 MB; the names tell us what to map
        $names = ($sys.PSObject.Properties.Name | Where-Object { $_ -like '*disk*' }) -join ', '
        throw "disk space fields not found in stat/system, got: $names"
    }
    $space
}

function Get-NsFiles($S, $Location) {
    try { $r = Invoke-Nitro $S GET ('/config/systemfile?args=filelocation:' + [Uri]::EscapeDataString($Location)) }
    catch {
        if ("$_" -match 'No such|not exist') { return @() }
        throw
    }
    $out = @()
    foreach ($f in @($r.systemfile)) {
        if (-not $f -or -not $f.filename) { continue }
        $out += [pscustomobject]@{
            Name  = "$($f.filename)"
            IsDir = ((@($f.filemode) -join ',') -match 'DIRECTORY')
            Size  = [double]$f.filesize
        }
    }
    $out
}

function Join-NsPath($Location, $Name) { "$($Location.TrimEnd('/'))/$Name" }

function Get-NsDirSize($S, $Location) {
    $total = 0
    foreach ($f in Get-NsFiles $S $Location) {
        if ($f.IsDir) { $total += Get-NsDirSize $S (Join-NsPath $Location $f.Name) } else { $total += $f.Size }
    }
    $total
}

function Remove-NsFile($S, $Location, $Name) {
    $loc = [Uri]::EscapeDataString($Location)
    $n = [Uri]::EscapeDataString($Name)
    try {
        # documented form: /config/systemfile/<name>?args=filelocation:<path>
        Invoke-Nitro $S DELETE "/config/systemfile/$($n)?args=filelocation:$loc" | Out-Null
    }
    catch {
        $first = "$_"
        try { Invoke-Nitro $S DELETE "/config/systemfile?args=filename:$n,filelocation:$loc" | Out-Null }
        catch { throw $first }
    }
}

function Remove-NsDir($S, $Location, $Name) {
    try { Remove-NsFile $S $Location $Name; return } catch { }
    # some builds refuse a non-empty folder: empty it, then remove it
    $path = Join-NsPath $Location $Name
    foreach ($f in Get-NsFiles $S $path) {
        if ($f.IsDir) { Remove-NsDir $S $path $f.Name } else { Remove-NsFile $S $path $f.Name }
    }
    Remove-NsFile $S $Location $Name
}

# ---------------------------------------------------------------- rules

function Get-BuildOf($Name) {
    if ($Name -match '(\d{2}\.\d)-(\d{1,3}\.\d{1,3})') { return "$($Matches[1])-$($Matches[2])" }
    $null
}

function ConvertTo-BuildVersion($Build) { [version]($Build -replace '-', '.') }

function Get-CleanupPlan($Entries, $Running, $Settings) {
    $keepRollback = [bool]$Settings.keep_running_build
    $keepBuilds = @($Settings.keep_builds)
    if ($keepRollback -and $Running) { $keepBuilds += $Running }
    $delete = @(); $keep = @()
    foreach ($e in $Entries) {
        $name = $e.Name
        $build = Get-BuildOf $name
        $isInstall = $e.IsDir -and $name.ToLower().StartsWith('build')
        $isArchive = (-not $e.IsDir) -and ($name -match '\.(tgz|tar|tar\.gz|gz)$')
        $protected = $false
        foreach ($p in $Settings.always_keep) { if ($name -like $p) { $protected = $true } }

        if ($protected) { $keep += , @($e, 'protected file') }
        elseif ($build -and $keepBuilds -contains $build) {
            $why = if ($build -eq $Running) { 'running build (rollback)' } else { 'listed in keep builds' }
            $keep += , @($e, $why)
        }
        elseif (-not $keepRollback) {
            # default, as the client's team asked: every installer file and build folder goes
            if ($isArchive) {
                $why = if ($build) { "installer file, build $build" } else { 'installer file' }
                $delete += , @($e, $why)
            }
            elseif ($isInstall) { $delete += , @($e, "install folder, build $build") }
            else { $keep += , @($e, 'not a build file, left alone') }
        }
        elseif (-not $build) { $keep += , @($e, 'not a recognised build file, left alone') }
        elseif (-not $Running -or (ConvertTo-BuildVersion $build) -gt (ConvertTo-BuildVersion $Running)) {
            # a newer image is most likely the upgrade target
            $keep += , @($e, 'newer than the running build (upgrade image)')
        }
        elseif ($isInstall -or $isArchive) { $delete += , @($e, "old build $build") }
        else { $keep += , @($e, 'not an install folder or archive') }
    }
    @{ Delete = $delete; Keep = $keep }
}

function Get-LogPlan($Entries) {
    # /var/log: rotated copies and compressed archives; current logs are kept.
    $delete = @(); $keep = @()
    foreach ($e in $Entries) {
        if ($e.IsDir) { $keep += , @($e, 'folder, left alone'); continue }
        if ($e.Name -match '\.\d+(\.(gz|bz2))?$' -or $e.Name -match '\.(gz|bz2)$') { $delete += , @($e, 'old rotated log') }
        else { $keep += , @($e, 'current log') }
    }
    @{ Delete = $delete; Keep = $keep }
}

function Get-NsLogPlan($Entries) {
    # /var/nslog: delete only numbered rotated/archived log files, for example
    # newslog.12.tar.gz, nwenslog.23.tar.gz, or ns.log.4. Keep active files
    # such as newslog, newslog.nextfile, ns.log, and all directories.
    $delete = @(); $keep = @()
    foreach ($e in $Entries) {
        if ($e.IsDir) { $keep += , @($e, 'folder, left alone'); continue }
        if ($e.Name -match '\.\d+(?:\.tar)?\.(?:gz|bz2)$' -or $e.Name -match '\.\d+$') {
            $delete += , @($e, 'numbered archived/rotated NetScaler log')
        }
        else { $keep += , @($e, 'active or unrecognised log, left alone') }
    }
    @{ Delete = $delete; Keep = $keep }
}

function New-NsBackup($S, $Level) {
    $name = 'preupgrade_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
    $body = @{ systembackup = @{ filename = $name; level = $Level; comment = 'Created by the pre-upgrade cleanup' } }
    # a full backup can take a few minutes
    Invoke-Nitro $S POST '/config/systembackup?action=create' $body 900000 | Out-Null
    "$name.tgz"
}

function Remove-NsBackup($S, $Name) {
    try { Invoke-Nitro $S DELETE "/config/systembackup/$([Uri]::EscapeDataString($Name))" | Out-Null }
    catch {
        $first = "$_"
        try { Remove-NsFile $S $script:BackupFolder $Name } catch { throw $first }
    }
}

# ---------------------------------------------------------------- run

$script:LogFolder = '/var/log'
$script:NsLogFolder = '/var/nslog'
$script:BackupFolder = '/var/ns_sys_backup'

function Format-MB($v) { if ($null -eq $v -or "$v" -eq '') { '?' } else { '{0:N0} MB' -f [double]$v } }

function Wait-NewSpace($S, $Before) {
    # disk stats refresh every few seconds on the appliance
    $space = Get-DiskSpace $S
    for ($i = 0; $i -lt 6 -and $space.VarFree -eq $Before.VarFree; $i++) {
        for ($t = 0; $t -lt 40; $t++) { Start-Sleep -Milliseconds 100; & $script:Pump }
        $space = Get-DiskSpace $S
    }
    $space
}

function Invoke-Appliance($NsHost, $Settings, $User, $Pass, [bool]$IsReal, $Log) {
    $row = [ordered]@{
        Appliance = $NsHost; Node = ''; RunningBuild = ''; VarFreeBeforeMB = ''; FlashFreeMB = ''
        Items = 0; FreedMB = 0; VarFreeAfterMB = ''; MinVarMB = $Settings.minimum_var_mb; Result = ''; Notes = ''
    }
    & $Log ''
    & $Log "=== $NsHost ==="

    $protocols = if ($Settings.protocol -eq 'auto') { @('https', 'http') } else { @($Settings.protocol) }
    $S = $null; $lastErr = $null
    foreach ($p in $protocols) {
        try { $S = Connect-NetScaler $NsHost $p $User $Pass; break }
        catch {
            $lastErr = "$_"
            if ($lastErr -notmatch '^cannot reach') { break }
        }
    }
    if (-not $S) {
        & $Log "  login failed: $lastErr"
        $row.Result = 'ERROR'; $row.Notes = "login failed: $lastErr"
        return [pscustomobject]$row
    }
    & $Log "  connected over $($S.Protocol)"

    try {
        $running, $versionText = Get-RunningBuild $S
        $node = Get-HaState $S
        $before = Get-DiskSpace $S
        $row.Node = $node
        $row.RunningBuild = if ($running) { $running } else { $versionText }
        $row.VarFreeBeforeMB = [math]::Round($before.VarFree)
        $row.FlashFreeMB = [math]::Round($before.FlashFree)
        & $Log "  node: $node   running build: $($row.RunningBuild)"
        & $Log "  /var free: $(Format-MB $before.VarFree)   /flash free: $(Format-MB $before.FlashFree)"
        & $Log "  required: /var $(Format-MB $Settings.minimum_var_mb), /flash $(Format-MB $Settings.minimum_flash_mb)"

        $toDelete = @()
        $buildFolders = @($Settings.cleanup_folders | Where-Object { $_.TrimEnd('/') -ne $script:LogFolder -and $_.TrimEnd('/') -ne $script:BackupFolder })
        foreach ($folder in $buildFolders) {
            $entries = @(Get-NsFiles $S $folder)
            $plan = Get-CleanupPlan $entries $running $Settings
            & $Log ''
            & $Log "  $folder"
            foreach ($item in $plan.Delete) {
                $e = $item[0]
                $size = if ($e.IsDir) { Get-NsDirSize $S (Join-NsPath $folder $e.Name) } else { $e.Size }
                $toDelete += , @($folder, $e, $size)
                $slash = if ($e.IsDir) { '/' } else { '' }
                & $Log "    DELETE  $($e.Name)$slash  ($(Format-MB ($size / 1MB)))  $($item[1])"
            }
            foreach ($item in $plan.Keep) {
                $slash = if ($item[0].IsDir) { '/' } else { '' }
                & $Log "    keep    $($item[0].Name)$slash  $($item[1])"
            }
            if ($entries.Count -eq 0) { & $Log '    (empty)' }
        }

        $logsReadable = $true
        if ($Settings.clean_logs) {
            try { $entries = @(Get-NsFiles $S $script:LogFolder) }
            catch {
                & $Log ''
                & $Log "  $($script:LogFolder): could not read it ($_), skipped"
                $logsReadable = $false; $entries = @()
            }
        }
        if ($Settings.clean_logs -and $logsReadable) {
            $plan = Get-LogPlan $entries
            & $Log ''
            & $Log "  $($script:LogFolder)"
            foreach ($item in $plan.Delete) {
                $e = $item[0]
                $toDelete += , @($script:LogFolder, $e, $e.Size)
                & $Log "    DELETE  $($e.Name)  ($(Format-MB ($e.Size / 1MB)))  $($item[1])"
            }
            $current = @($plan.Keep | Where-Object { -not $_[0].IsDir }).Count
            & $Log "    keep    $current current log files (never deleted)"
            if ($plan.Delete.Count -eq 0) { & $Log '    (no old logs)' }
        }

        $nsLogsReadable = $true
        if ($Settings.clean_nslogs) {
            try { $nsEntries = @(Get-NsFiles $S $script:NsLogFolder) }
            catch {
                & $Log ''
                & $Log "  $($script:NsLogFolder): could not read it ($_), skipped"
                $nsLogsReadable = $false; $nsEntries = @()
            }
        }
        if ($Settings.clean_nslogs -and $nsLogsReadable) {
            $nsPlan = Get-NsLogPlan $nsEntries
            & $Log ''
            & $Log "  $($script:NsLogFolder)"
            foreach ($item in $nsPlan.Delete) {
                $e = $item[0]
                $toDelete += , @($script:NsLogFolder, $e, $e.Size)
                & $Log "    DELETE  $($e.Name)  ($(Format-MB ($e.Size / 1MB)))  $($item[1])"
            }
            foreach ($item in $nsPlan.Keep) {
                & $Log "    keep    $($item[0].Name)  $($item[1])"
            }
            if ($nsPlan.Delete.Count -eq 0) { & $Log '    (no numbered archived logs)' }
        }

        $oldBackups = @()
        $backupReadable = $true
        if ($Settings.replace_backup) {
            try { $oldBackups = @(Get-NsFiles $S $script:BackupFolder | Where-Object { -not $_.IsDir -and $_.Name -match '\.tgz$' }) }
            catch {
                & $Log ''
                & $Log "  $($script:BackupFolder): could not read it ($_), backup step skipped"
                $backupReadable = $false; $oldBackups = @()
            }
        }
        if ($Settings.replace_backup -and $backupReadable) {
            & $Log ''
            & $Log "  $($script:BackupFolder)"
            & $Log "    NEW     a fresh $($Settings.backup_level) backup is created first"
            foreach ($b in $oldBackups) {
                & $Log "    DELETE  $($b.Name)  ($(Format-MB ($b.Size / 1MB)))  old backup, removed once the new one exists"
            }
            if ($oldBackups.Count -eq 0) { & $Log '    (no old backups)' }
        }

        $freed = 0
        foreach ($d in $toDelete) { $freed += $d[2] / 1MB }
        foreach ($b in $oldBackups) { $freed += $b.Size / 1MB }
        $failures = @()
        $backupNote = ''
        $done = 0
        if ($IsReal) {
            & $Log ''
            foreach ($d in $toDelete) {
                $folder, $e, $size = $d
                $path = Join-NsPath $folder $e.Name
                try {
                    if ($e.IsDir) { Remove-NsDir $S $folder $e.Name } else { Remove-NsFile $S $folder $e.Name }
                    & $Log "  deleted $path"
                    $done++
                }
                catch {
                    $failures += $e.Name
                    $freed -= $size / 1MB
                    & $Log "  could NOT delete $($path): $_"
                    & $Log '    remove it on the NetScaler Disk Cleanup page instead'
                }
                & $script:Pump
            }

            if ($Settings.replace_backup -and $backupReadable) {
                $newBackup = $null
                try {
                    & $Log "  creating a new $($Settings.backup_level) backup (this can take a few minutes)..."
                    $newBackup = New-NsBackup $S $Settings.backup_level
                    & $Log "  created backup $($script:BackupFolder)/$newBackup"
                }
                catch {
                    & $Log "  could NOT create a new backup: $_"
                    & $Log '    the old backups are kept, so the appliance is never left without one'
                    $backupNote = 'new backup failed, old backups kept'
                    foreach ($b in $oldBackups) { $freed -= $b.Size / 1MB }
                }
                if ($newBackup) {
                    foreach ($b in $oldBackups) {
                        if ($b.Name -eq $newBackup) { continue }
                        try {
                            Remove-NsBackup $S $b.Name
                            & $Log "  deleted old backup $($b.Name)"
                            $done++
                        }
                        catch {
                            $failures += $b.Name
                            $freed -= $b.Size / 1MB
                            & $Log "  could NOT delete old backup $($b.Name): $_"
                        }
                    }
                }
            }
            $after = if ($toDelete.Count) { Wait-NewSpace $S $before } else { Get-DiskSpace $S }
            $varAfter = $after.VarFree; $flashAfter = $after.FlashFree
            # measured, so it already includes the space the new backup took
            $freed = $after.VarFree - $before.VarFree
        }
        else {
            $done = $toDelete.Count + $oldBackups.Count
            if ($Settings.replace_backup -and $backupReadable -and $oldBackups.Count) {
                # the fresh backup takes space back; assume it is about as big as the largest old one
                $guess = (@($oldBackups | Sort-Object Size)[-1]).Size / 1MB
                $freed -= $guess
                & $Log ''
                & $Log "  (estimate allows $(Format-MB $guess) for the new backup)"
            }
            $varAfter = $before.VarFree + $freed; $flashAfter = $before.FlashFree
        }

        $ok = ($varAfter -ge $Settings.minimum_var_mb) -and ($flashAfter -ge $Settings.minimum_flash_mb)
        $label = if ($ok) { 'PASS' } else { 'FAIL' }
        if (-not $IsReal) { $label += ' (projected)' }
        $row.Items = $done
        $row.FreedMB = [math]::Round($freed)
        $row.VarFreeAfterMB = [math]::Round($varAfter)
        $row.Result = $label
        $notes = @()
        if ($failures.Count) { $notes += 'failed to delete: ' + ($failures -join ', ') }
        if ($backupNote) { $notes += $backupNote }
        $row.Notes = $notes -join '; '
        $word = if ($IsReal) { 'after cleanup' } else { 'after cleanup (estimate)' }
        & $Log ''
        & $Log "  /var free $($word): $(Format-MB $varAfter)  ->  $label"
        if (-not $ok) { & $Log '  still below the minimum: needs manual attention before the upgrade job' }
    }
    catch {
        & $Log "  error: $_"
        $row.Result = 'ERROR'; $row.Notes = "$_"
    }
    finally { Disconnect-NetScaler $S }
    [pscustomobject]$row
}

function Invoke-Cleanup($Settings, $User, $Pass, [bool]$IsReal, $Log, $OnRow) {
    New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $kind = if ($IsReal) { 'real' } else { 'test' }
    $logPath = Join-Path $ReportDir "cleanup-$kind-$stamp.log"
    $csvPath = Join-Path $ReportDir "cleanup-$kind-$stamp.csv"
    $fileLog = { param($m) & $Log $m; Add-Content -Path $logPath -Value $m -Encoding UTF8 }.GetNewClosure()

    $title = if ($IsReal) { 'REAL RUN: files will be deleted' } else { 'TEST RUN: nothing will be deleted' }
    & $fileLog "$title  ($stamp)"
    $rows = @()
    foreach ($h in $Settings.appliances) {
        $r = Invoke-Appliance $h $Settings $User $Pass $IsReal $fileLog
        $rows += $r
        if ($OnRow) { & $OnRow $r }
    }
    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    & $fileLog ''
    & $fileLog 'Summary'
    foreach ($r in $rows) {
        & $fileLog ('  {0,-20} {1,-12} /var {2,10} -> {3,10}  {4}' -f $r.Appliance, $r.Node,
            (Format-MB $r.VarFreeBeforeMB), (Format-MB $r.VarFreeAfterMB), $r.Result)
    }
    & $fileLog "Report saved: $csvPath"
    $csvPath
}

# ---------------------------------------------------------------- command line

if ($Cli) {
    $settings = Read-Settings
    $problem = Test-Settings $settings
    if ($problem) { Write-Host $problem; exit 1 }
    if (-not $Username) { $Username = $settings.username }
    $pass = $env:NS_PASSWORD
    if (-not $pass) {
        $sec = Read-Host "Password for $Username" -AsSecureString
        $pass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    }
    Invoke-Cleanup $settings $Username $pass $Real.IsPresent { param($m) Write-Host $m } $null | Out-Null
    exit 0
}

# ---------------------------------------------------------------- window

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$script:Pump = { [System.Windows.Forms.Application]::DoEvents() }

$Ink = [Drawing.Color]::FromArgb(27, 36, 48)
$Paper = [Drawing.Color]::FromArgb(244, 241, 234)
$Amber = [Drawing.Color]::FromArgb(222, 150, 48)
$Danger = [Drawing.Color]::FromArgb(178, 58, 58)
$Muted = [Drawing.Color]::FromArgb(105, 112, 122)
$PassBg = [Drawing.Color]::FromArgb(222, 240, 228)
$FailBg = [Drawing.Color]::FromArgb(250, 232, 214)
$ErrBg = [Drawing.Color]::FromArgb(246, 222, 222)
$FontBody = New-Object Drawing.Font('Segoe UI', 9.5)
$Bold = New-Object Drawing.Font('Segoe UI Semibold', 9.5)
$Small = New-Object Drawing.Font('Segoe UI', 8.5)

$form = New-Object Windows.Forms.Form
$form.Text = 'NetScaler Pre-Upgrade Cleanup'
$form.ClientSize = New-Object Drawing.Size(1100, 790)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Paper
$form.Font = $FontBody
$form.AutoScaleMode = 'None'
$form.AutoScroll = $true

$header = New-Object Windows.Forms.Panel
$header.SetBounds(0, 0, 1100, 78)
$header.BackColor = $Ink
$form.Controls.Add($header)

$accent = New-Object Windows.Forms.Panel
$accent.SetBounds(0, 78, 1100, 4)
$accent.BackColor = $Amber
$form.Controls.Add($accent)

$title = New-Object Windows.Forms.Label
$title.Text = 'NetScaler Pre-Upgrade Cleanup'
$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 16)
$title.ForeColor = [Drawing.Color]::White
$title.SetBounds(22, 12, 700, 34)
$header.Controls.Add($title)

$subtitle = New-Object Windows.Forms.Label
$subtitle.Text = 'Run before creating the upgrade job.  Frees space in /var.  Never starts an upgrade.'
$subtitle.ForeColor = [Drawing.Color]::FromArgb(190, 198, 208)
$subtitle.SetBounds(24, 47, 800, 22)
$header.Controls.Add($subtitle)

function New-Label($text, $x, $y, $w = 330) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Font = $Bold; $l.ForeColor = $Ink
    $l.SetBounds($x, $y, $w, 20)
    $form.Controls.Add($l); $l
}
function New-Hint($text, $x, $y, $w = 330) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Font = $Small; $l.ForeColor = $Muted
    $l.SetBounds($x, $y, $w, 18)
    $form.Controls.Add($l); $l
}
function New-Box($x, $y, $w = 330, $h = 26) {
    $t = New-Object Windows.Forms.TextBox
    $t.SetBounds($x, $y, $w, $h); $t.BorderStyle = 'FixedSingle'
    $form.Controls.Add($t); $t
}
function New-Button($text, $x, $y, $w, $back, $fore) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.SetBounds($x, $y, $w, 36)
    $b.FlatStyle = 'Flat'; $b.Font = $Bold
    $b.BackColor = $back; $b.ForeColor = $fore
    $b.FlatAppearance.BorderColor = $fore
    $b.Cursor = [Windows.Forms.Cursors]::Hand
    $form.Controls.Add($b); $b
}

# ---- settings column
$x = 24
$sectionLabel = New-Label 'SETTINGS' $x 98
$sectionLabel.ForeColor = $Amber

New-Label 'NetScaler appliances' $x 126 | Out-Null
New-Hint 'One IP per line. List both nodes of each HA pair.' $x 145 | Out-Null
$tbHosts = New-Box $x 166 330 92
$tbHosts.Multiline = $true; $tbHosts.ScrollBars = 'Vertical'

New-Label 'Username' $x 270 160 | Out-Null
$tbUser = New-Box $x 291 160
New-Label 'Password' ($x + 170) 270 160 | Out-Null
$tbPass = New-Box ($x + 170) 291 160
$tbPass.UseSystemPasswordChar = $true
New-Hint 'Your normal NetScaler login. Never saved.' $x 320 | Out-Null

New-Label 'Connection' $x 346 | Out-Null
$cbProto = New-Object Windows.Forms.ComboBox
$cbProto.DropDownStyle = 'DropDownList'
$cbProto.SetBounds($x, 367, 330, 26)
[void]$cbProto.Items.AddRange(@('auto  (https, then http)', 'https only', 'http only'))
$form.Controls.Add($cbProto)

function New-Check($text, $y) {
    $c = New-Object Windows.Forms.CheckBox
    $c.Text = $text; $c.SetBounds($x, $y, 330, 22)
    $form.Controls.Add($c); $c
}

New-Label 'What to clean' $x 404 | Out-Null
New-Hint '/var/nsinstall: old build folders and .tgz files, always.' $x 423 | Out-Null
$chkLogs = New-Check '/var/log: delete old rotated logs' 444
$chkLogs.Width = 160
$chkNsLogs = New-Check '/var/nslog: delete old archives' 444
$chkNsLogs.Left = $x + 170
$chkNsLogs.Width = 160
$chkBackup = New-Check '/var/ns_sys_backup: replace backup' 468
$chkBackup.Width = 262
$cbLevel = New-Object Windows.Forms.ComboBox
$cbLevel.DropDownStyle = 'DropDownList'
$cbLevel.SetBounds(($x + 266), 467, 64, 24)
[void]$cbLevel.Items.AddRange(@('full', 'basic'))
$form.Controls.Add($cbLevel)
$chkRunning = New-Check 'Keep the running build .tgz (rollback)' 492

New-Label 'Also keep these builds' $x 524 | Out-Null
New-Hint 'e.g. 14.1-73.49' $x 543 | Out-Null
$tbKeepBuilds = New-Box $x 564

New-Label 'Never delete' $x 600 | Out-Null
New-Hint 'File names or patterns, comma separated.' $x 619 | Out-Null
$tbAlwaysKeep = New-Box $x 640

New-Label 'Minimum free /var (MB)' $x 676 160 | Out-Null
$numVar = New-Object Windows.Forms.NumericUpDown
$numVar.SetBounds($x, 697, 160, 26); $numVar.Maximum = 1000000; $numVar.ThousandsSeparator = $true
$form.Controls.Add($numVar)
New-Label 'Minimum free /flash (MB)' ($x + 170) 676 160 | Out-Null
$numFlash = New-Object Windows.Forms.NumericUpDown
$numFlash.SetBounds(($x + 170), 697, 160, 26); $numFlash.Maximum = 1000000; $numFlash.ThousandsSeparator = $true
$form.Controls.Add($numFlash)
New-Hint 'Use the figures shown on System Upgrade > System Disk.' $x 726 | Out-Null

$btnSave = New-Button 'Save settings' $x 750 330 $Paper $Ink
$btnSave.Height = 22
$btnSave.Font = $Small

$divider = New-Object Windows.Forms.Panel
$divider.SetBounds(374, 98, 1, 674)
$divider.BackColor = [Drawing.Color]::FromArgb(214, 208, 196)
$form.Controls.Add($divider)

# ---- run column
$rx = 396
$runLabel = New-Label 'RUN' $rx 98
$runLabel.ForeColor = $Amber

$btnTest = New-Button 'Test run' $rx 124 170 $Amber $Ink
$btnTest.FlatAppearance.BorderColor = $Amber
$btnReal = New-Button 'Real run' ($rx + 182) 124 150 $Paper $Danger
$btnReports = New-Button 'Open reports folder' ($rx + 516) 124 168 $Paper $Ink
$lblStatus = New-Hint 'Start with a test run. It shows what would be deleted and changes nothing.' $rx 166 680

$grid = New-Object Windows.Forms.DataGridView
$grid.SetBounds($rx, 190, 684, 190)
$grid.BackgroundColor = [Drawing.Color]::White
$grid.BorderStyle = 'FixedSingle'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToResizeRows = $false
$grid.ReadOnly = $true
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.AutoSizeColumnsMode = 'Fill'
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.BackColor = $Ink
$grid.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::White
$grid.ColumnHeadersDefaultCellStyle.Font = $Bold
$grid.ColumnHeadersHeight = 32
$grid.GridColor = [Drawing.Color]::FromArgb(230, 226, 218)
$grid.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(236, 230, 216)
$grid.DefaultCellStyle.SelectionForeColor = $Ink
foreach ($c in 'Appliance', 'Node', 'Build', '/var before', '/var after', 'Freed', 'Result') { [void]$grid.Columns.Add($c, $c) }
$form.Controls.Add($grid)

New-Label 'Details' $rx 392 | Out-Null
$tbLog = New-Object Windows.Forms.TextBox
$tbLog.SetBounds($rx, 414, 684, 358)
$tbLog.Multiline = $true; $tbLog.ScrollBars = 'Vertical'; $tbLog.ReadOnly = $true
$tbLog.Font = New-Object Drawing.Font('Consolas', 9)
$tbLog.BackColor = [Drawing.Color]::FromArgb(250, 249, 246)
$tbLog.BorderStyle = 'FixedSingle'
$form.Controls.Add($tbLog)

# ---- wiring
function Split-List($text) { @($text -split '[,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

$script:Folders = @()

function Show-Settings($s) {
    $tbHosts.Text = ($s.appliances -join "`r`n")
    $tbUser.Text = $s.username
    $cbProto.SelectedIndex = switch ($s.protocol) { 'https' { 1 } 'http' { 2 } default { 0 } }
    $script:Folders = @($s.cleanup_folders)
    $chkRunning.Checked = [bool]$s.keep_running_build
    $chkLogs.Checked = [bool]$s.clean_logs
    $chkNsLogs.Checked = [bool]$s.clean_nslogs
    $chkBackup.Checked = [bool]$s.replace_backup
    $cbLevel.SelectedIndex = if ("$($s.backup_level)" -eq 'basic') { 1 } else { 0 }
    $tbKeepBuilds.Text = ($s.keep_builds -join ', ')
    $tbAlwaysKeep.Text = ($s.always_keep -join ', ')
    $numVar.Value = [decimal]$s.minimum_var_mb
    $numFlash.Value = [decimal]$s.minimum_flash_mb
}

function Get-FormSettings {
    $s = Get-DefaultSettings
    $s.appliances = @(Split-List $tbHosts.Text)
    $s.username = $tbUser.Text.Trim()
    $s.protocol = @('auto', 'https', 'http')[[math]::Max(0, $cbProto.SelectedIndex)]
    if ($script:Folders.Count) { $s.cleanup_folders = @($script:Folders) }
    $s.keep_running_build = $chkRunning.Checked
    $s.clean_logs = $chkLogs.Checked
    $s.clean_nslogs = $chkNsLogs.Checked
    $s.replace_backup = $chkBackup.Checked
    $s.backup_level = @('full', 'basic')[[math]::Max(0, $cbLevel.SelectedIndex)]
    $s.keep_builds = @(Split-List $tbKeepBuilds.Text)
    $s.always_keep = @(Split-List $tbAlwaysKeep.Text)
    $s.minimum_var_mb = [int]$numVar.Value
    $s.minimum_flash_mb = [int]$numFlash.Value
    $s
}

function Add-ResultRow($r) {
    $i = $grid.Rows.Add($r.Appliance, $r.Node, $r.RunningBuild, (Format-MB $r.VarFreeBeforeMB),
        (Format-MB $r.VarFreeAfterMB), (Format-MB $r.FreedMB), $r.Result)
    $color = if ($r.Result -like 'PASS*') { $PassBg } elseif ($r.Result -like 'FAIL*') { $FailBg } else { $ErrBg }
    $grid.Rows[$i].DefaultCellStyle.BackColor = $color
}

function Start-Run([bool]$IsReal) {
    $s = Get-FormSettings
    $problem = Test-Settings $s
    if (-not $problem -and -not $s.username) { $problem = 'Enter the NetScaler username.' }
    if (-not $problem -and -not $tbPass.Text) { $problem = 'Enter the NetScaler password.' }
    if ($problem) {
        [void][Windows.Forms.MessageBox]::Show($problem, 'Check settings', 'OK', 'Warning')
        return
    }
    if ($IsReal) {
        $msg = "This will permanently delete the files listed as DELETE in a test run" +
            $(if ($s.replace_backup) { ' (after making a fresh backup)' } else { '' }) + ", on:`r`n`r`n" +
            ($s.appliances -join "`r`n") + "`r`n`r`nRun a test run first if you have not. Continue?"
        $answer = [Windows.Forms.MessageBox]::Show($msg, 'Confirm real run', 'YesNo', 'Warning', 'Button2')
        if ($answer -ne 'Yes') { return }
    }
    Save-Settings $s
    $grid.Rows.Clear(); $tbLog.Clear()
    foreach ($b in $btnTest, $btnReal, $btnSave) { $b.Enabled = $false }
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    $lblStatus.Text = if ($IsReal) { 'Real run in progress...' } else { 'Test run in progress. Nothing is being deleted.' }
    $lblStatus.ForeColor = $Ink
    try {
        $log = { param($m) $tbLog.AppendText("$m`r`n"); [System.Windows.Forms.Application]::DoEvents() }
        $csv = Invoke-Cleanup $s $s.username $tbPass.Text $IsReal $log { param($r) Add-ResultRow $r }
        $lblStatus.Text = "Done. Report saved to $csv"
        $lblStatus.ForeColor = $Muted
    }
    catch {
        $tbLog.AppendText("`r`nUnexpected error: $_`r`n")
        $lblStatus.Text = 'Stopped with an error. See details below.'
        $lblStatus.ForeColor = $Danger
    }
    finally {
        foreach ($b in $btnTest, $btnReal, $btnSave) { $b.Enabled = $true }
        $form.Cursor = [Windows.Forms.Cursors]::Default
    }
}

$btnTest.Add_Click({ Start-Run $false })
$btnReal.Add_Click({ Start-Run $true })
$btnSave.Add_Click({
    $s = Get-FormSettings
    $problem = Test-Settings $s
    if ($problem) { [void][Windows.Forms.MessageBox]::Show($problem, 'Check settings', 'OK', 'Warning'); return }
    Save-Settings $s
    $lblStatus.Text = 'Settings saved.'
})
$btnReports.Add_Click({
    New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
    Start-Process explorer.exe $ReportDir
})

# fonts already follow Windows display scaling (125%, 150%...); scale the layout to match
$g = $form.CreateGraphics()
$k = $g.DpiX / 96
$g.Dispose()
if ($k -ne 1) { $form.Scale((New-Object Drawing.SizeF($k, $k))) }
$area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($form.Height -gt $area.Height) { $form.Height = $area.Height }
if ($form.Width -gt $area.Width) { $form.Width = $area.Width }

try { Show-Settings (Read-Settings) }
catch {
    Show-Settings (Get-DefaultSettings)
    $lblStatus.Text = "Could not read saved settings, defaults loaded: $_"
}
$form.Add_Shown({ $form.Activate(); if ($tbHosts.Text) { $tbPass.Focus() } else { $tbHosts.Focus() } })
[void]$form.ShowDialog()

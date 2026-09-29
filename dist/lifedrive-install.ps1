[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageDirectory,
    [string]$LeitherRoot,
    [Int64]$StorageMaxGB = 0,
    [switch]$NoInstallLeither,
    [switch]$LeitherService,
    [switch]$Upgrade,
    [switch]$Household,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$leitherTaskName = "LifeDrive Leither"
$identityTaskName = "LifeDrive Identity"
$defaultStorageGB = 100
$releaseBase = "http://vzhan.cn/mm/Fc1BRTFafOGzq5P8KmkVJqwS2v2"

function Show-Usage {
    Write-Host @"
Usage: npx --yes @inoku/lifedrive [options]

Windows options:
  --leither-root DIR        Existing node or directory for a new node.
  --storage-max-gb GB       New node storage maximum (default: 100 GB).
  --no-install-leither      Require an already running Leither node.
  --leither-service         Configure Leither startup only.
  --upgrade                 Upgrade an existing Windows LifeDrive installation.
  --household               Accepted for parity; Windows uses household mode by default.

Run Windows Terminal or PowerShell as Administrator. Windows setup supports
native x64 Windows 10/11 and Windows Server; WSL and Git Bash are not required.
"@
}

if ($Help) { Show-Usage; return }
if ($Upgrade -and $LeitherService) { throw "Use -Upgrade and -LeitherService separately." }
if ($StorageMaxGB -lt 0) { throw "Leither storage must be a positive whole number of gigabytes." }
if ($StorageMaxGB -eq 0 -and $env:LIFEDRIVE_STORAGE_MAX_GB) {
    $parsedStorage = 0L
    if (-not [Int64]::TryParse($env:LIFEDRIVE_STORAGE_MAX_GB, [ref]$parsedStorage) -or $parsedStorage -lt 1) {
        throw "LIFEDRIVE_STORAGE_MAX_GB must be a positive whole number."
    }
    $StorageMaxGB = $parsedStorage
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run Windows Terminal or PowerShell as Administrator, then rerun the npx command."
}
if (-not [Environment]::Is64BitOperatingSystem) {
    throw "The official Leither Windows build requires 64-bit Windows."
}
$architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ($architecture -ne "AMD64") {
    throw "The official Leither Windows package currently supports x64 (AMD64) only."
}

function Get-LeitherVersion {
    param([string]$Root)
    $executable = Join-Path $Root "Leither.exe"
    Push-Location $Root
    try {
        $reply = & $executable version --json 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Leither version command failed." }
    } finally {
        Pop-Location
    }
    $parsed = ($reply -join [Environment]::NewLine) | ConvertFrom-Json
    $reported = if ($parsed.data.version) { [string]$parsed.data.version } else { [string]$parsed.version }
    $normalized = $reported.TrimStart("V")
    $version = $null
    if (-not [Version]::TryParse($normalized, [ref]$version) -or $version -lt [Version]"0.24.11") {
        throw "LifeDrive requires Leither V0.24.11 or newer. Existing binaries are never replaced."
    }
    return $version
}

function Get-LeitherPort {
    param([string]$Root)
    $path = @("SystemVars.json", "systemvars.json") | ForEach-Object { Join-Path $Root $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $path) { return 4800 }
    $value = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $port = if ($null -ne $value.ServicePort) { [int]$value.ServicePort } else { 4800 }
    if ($port -lt 1 -or $port -gt 65535) { throw "Invalid Leither ServicePort in $path." }
    return $port
}

function Get-RunningLeitherRoots {
    $roots = @()
    Get-CimInstance Win32_Process -Filter "Name='Leither.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.ExecutablePath) {
            $candidate = [IO.Path]::GetFullPath((Split-Path -Parent $_.ExecutablePath))
            if ($roots -notcontains $candidate) { $roots += $candidate }
        }
    }
    return $roots
}

function Protect-NewNodeDirectory {
    param([string]$Path)
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
    $propagation = [Security.AccessControl.PropagationFlags]::None
    foreach ($sidText in @("S-1-5-18", "S-1-5-32-544", [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
            $propagation, [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Grant-SystemTaskAccess {
    param([string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    $inheritance = [Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
    $sid = [Security.Principal.SecurityIdentifier]::new("S-1-5-18")
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $sid, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
        [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Assert-PortAvailable {
    param([int]$Port)
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    try {
        $listener.Start()
    } catch {
        throw "Leither port $Port is unavailable. Free it or configure a different ServicePort in the selected node's SystemVars.json."
    } finally {
        $listener.Stop()
    }
}

function Install-LeitherBinary {
    param([string]$Root)
    $work = Join-Path ([IO.Path]::GetTempPath()) ("lifedrive-leither-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        Write-Host "Finding the latest official Leither Windows release..."
        $index = (Invoke-WebRequest -UseBasicParsing -Uri ($releaseBase + "/")).Content
        $versions = [regex]::Matches($index, 'href="V(\d+\.\d+\.\d+)/"') | ForEach-Object { [Version]$_.Groups[1].Value } | Sort-Object
        if (-not $versions) { throw "No Leither release was found in the official index." }
        $latest = "V" + $versions[-1].ToString()
        $artifact = "Leither.windows.amd64"
        $binaryURL = "$releaseBase/$latest/$artifact"
        $downloaded = Join-Path $work "Leither.exe"
        $checksum = Join-Path $work "Leither.sha256"
        Write-Host "Downloading Leither $latest for Windows x64..."
        Invoke-WebRequest -UseBasicParsing -Uri $binaryURL -OutFile $downloaded
        Invoke-WebRequest -UseBasicParsing -Uri ($binaryURL + ".sha256") -OutFile $checksum
        $expected = ((Get-Content -LiteralPath $checksum -Raw).Trim() -split "\s+")[0].ToLowerInvariant()
        $actual = (Get-FileHash -LiteralPath $downloaded -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expected -notmatch '^[a-f0-9]{64}$' -or $actual -ne $expected) {
            throw "Leither SHA-256 verification failed; the binary was not installed."
        }
        $destination = Join-Path $Root "Leither.exe"
        if (Test-Path -LiteralPath $destination) { throw "Leither.exe already exists and was not replaced." }
        Move-Item -LiteralPath $downloaded -Destination $destination
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Set-NewNodeStorage {
    param([string]$Root, [Int64]$RequestedGB)
    $config = Join-Path $Root "ds\config"
    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
        throw "Leither initialization did not create $config."
    }
    $driveRoot = [IO.Path]::GetPathRoot($Root)
    $drive = [IO.DriveInfo]::new($driveRoot)
    $availableGB = [Math]::Floor($drive.AvailableFreeSpace / 1000000000)
    Write-Host ""
    Write-Host "Choose the maximum hard-drive space Leither may use for LePan and other data on this node."
    Write-Host "Available now on the selected drive: $availableGB GB."
    $selected = $RequestedGB
    if ($selected -eq 0) {
        if ([Console]::IsInputRedirected) {
            $selected = $defaultStorageGB
            Write-Host "No interactive input was detected; using the $defaultStorageGB GB default."
        } else {
            while ($true) {
                $answer = Read-Host "Maximum Leither storage in GB [$defaultStorageGB]"
                if ([string]::IsNullOrWhiteSpace($answer)) { $selected = $defaultStorageGB }
                else {
                    $candidate = 0L
                    if ([Int64]::TryParse($answer, [ref]$candidate) -and $candidate -gt 0) { $selected = $candidate }
                    else { Write-Warning "Enter a positive whole number of gigabytes."; continue }
                }
                if ($selected -gt $availableGB) { Write-Warning "That exceeds the $availableGB GB currently available."; continue }
                break
            }
        }
    }
    if ($selected -lt 1) { throw "Leither storage must be a positive whole number of gigabytes." }
    if ($selected -gt $availableGB) { throw "The selected limit ($selected GB) exceeds the $availableGB GB currently available." }

    $source = [IO.File]::ReadAllText($config)
    $matches = [regex]::Matches($source, '"StorageMax"\s*:\s*"([^"]*)"')
    if ($matches.Count -ne 1) { throw "Leither datastore StorageMax must occur exactly once." }
    $desired = [string]$selected + "GB"
    $value = $matches[0].Groups[1]
    $next = $source.Substring(0, $value.Index) + $desired + $source.Substring($value.Index + $value.Length)
    $verified = $next | ConvertFrom-Json
    if ([string]$verified.Datastore.StorageMax -ne $desired) { throw "Updated Leither storage configuration did not validate." }
    $temporary = $config + ".lifedrive-install-" + [Guid]::NewGuid().ToString("N")
    $backup = $config + ".lifedrive-install-backup-" + [Guid]::NewGuid().ToString("N")
    [IO.File]::WriteAllText($temporary, $next, [Text.UTF8Encoding]::new($false))
    try {
        [IO.File]::Replace($temporary, $config, $backup, $true)
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    } catch {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        throw
    }
    Write-Host "Leither storage limit saved as $selected GB."
}

function Test-ManagedLeitherTask {
    param($Task, [string]$Root)
    if (-not $Task -or $Task.Actions.Count -ne 1) { return $false }
    $action = $Task.Actions[0]
    $expected = Join-Path $Root "Leither.exe"
    return ([IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($action.Execute)) -eq [IO.Path]::GetFullPath($expected)) -and
        ($action.Arguments -eq "run") -and
        ([IO.Path]::GetFullPath($action.WorkingDirectory) -eq [IO.Path]::GetFullPath($Root))
}

function Register-LeitherTask {
    param([string]$Root, [bool]$StartNow)
    $existing = Get-ScheduledTask -TaskName $leitherTaskName -ErrorAction SilentlyContinue
    if ($existing -and -not (Test-ManagedLeitherTask $existing $Root)) {
        throw "A different scheduled task named '$leitherTaskName' already exists. It was not replaced."
    }
    $action = New-ScheduledTaskAction -Execute (Join-Path $Root "Leither.exe") -Argument "run" -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settingsParameters = @{
        AllowStartIfOnBatteries = $true
        DontStopIfGoingOnBatteries = $true
        ExecutionTimeLimit = [TimeSpan]::Zero
        RestartCount = 999
        RestartInterval = (New-TimeSpan -Minutes 1)
        StartWhenAvailable = $true
        MultipleInstances = "IgnoreNew"
    }
    $settings = New-ScheduledTaskSettingsSet @settingsParameters
    $definition = New-ScheduledTask -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $settings -Description "Leither node installed by LifeDrive"
    Register-ScheduledTask -TaskName $leitherTaskName -InputObject $definition -Force | Out-Null
    if ($StartNow -and (Get-ScheduledTask -TaskName $leitherTaskName).State -ne "Running") {
        Start-ScheduledTask -TaskName $leitherTaskName
    }
}

function Ensure-LeitherFirewall {
    param([string]$Root, [int]$Port)
    $name = "LifeDrive-Leither"
    $program = Join-Path $Root "Leither.exe"
    $rule = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    if ($rule) {
        $application = $rule | Get-NetFirewallApplicationFilter
        $portFilter = $rule | Get-NetFirewallPortFilter
        if ([IO.Path]::GetFullPath($application.Program) -ne [IO.Path]::GetFullPath($program) -or [string]$portFilter.LocalPort -ne [string]$Port -or $portFilter.Protocol -ne "TCP") {
            throw "An existing firewall rule named $name has a different program or port. It was not replaced."
        }
        Enable-NetFirewallRule -Name $name | Out-Null
    } else {
        New-NetFirewallRule -Name $name -DisplayName "LifeDrive Leither node" -Direction Inbound -Action Allow -Enabled True -Profile Any -Protocol TCP -LocalPort $Port -Program $program | Out-Null
    }
}

function Wait-Leither {
    param([string]$Root, [Version]$Version, [int]$Port)
    for ($attempt = 0; $attempt -lt 45; $attempt++) {
        try {
            $reply = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/getvar?name=ver" -TimeoutSec 2
            $reported = ([string]$reply).TrimStart("V")
            $process = Get-CimInstance Win32_Process -Filter "Name='Leither.exe'" -ErrorAction SilentlyContinue | Where-Object {
                $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -eq [IO.Path]::GetFullPath((Join-Path $Root "Leither.exe"))
            }
            if ($process -and $reported -eq $Version.ToString()) { return }
        } catch {}
        Start-Sleep -Seconds 1
    }
    throw "Leither did not become ready. Inspect the '$leitherTaskName' task history."
}

$packageRoot = [IO.Path]::GetFullPath($PackageDirectory)
$archive = Join-Path $packageRoot "lifedrive-bundle.tar.gz"
$checksumFile = $archive + ".sha256"
if (-not (Test-Path -LiteralPath $archive -PathType Leaf) -or -not (Test-Path -LiteralPath $checksumFile -PathType Leaf)) {
    throw "The npm package is incomplete. Reinstall @inoku/lifedrive and try again."
}

$runningRoots = @(Get-RunningLeitherRoots)
if ($LeitherRoot) {
    $root = [IO.Path]::GetFullPath($LeitherRoot)
} elseif ($runningRoots.Count -eq 1) {
    $root = $runningRoots[0]
} elseif ($runningRoots.Count -gt 1) {
    throw "More than one Leither process is running. Rerun with --leither-root."
} else {
    $root = Join-Path $env:ProgramData "LifeDrive\Leither"
}

$binary = Join-Path $root "Leither.exe"
$pending = Join-Path $root ".lifedrive-storage-pending"
$newNode = -not (Test-Path -LiteralPath $binary -PathType Leaf)
if (Test-Path -LiteralPath $pending -PathType Leaf) { $newNode = $true }

if ($newNode) {
    if ($NoInstallLeither -or $Upgrade) { throw "This operation requires an already running Leither node." }
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Protect-NewNodeDirectory $root
    }
    $contents = @(Get-ChildItem -LiteralPath $root -Force)
    $allowedRetry = @(".lifedrive-storage-pending", "Leither.exe", "SystemVars.json", "systemvars.json", "hostkey.cfg", "ds")
    if (($contents | Where-Object { $allowedRetry -notcontains $_.Name }).Count -gt 0) {
        throw "Leither is missing, but $root contains other files. Choose an empty --leither-root; nothing was replaced."
    }
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { Install-LeitherBinary $root }
    if (-not (Test-Path -LiteralPath $pending)) { New-Item -ItemType File -Path $pending | Out-Null }
    if (-not (Test-Path -LiteralPath (Join-Path $root "SystemVars.json")) -and -not (Test-Path -LiteralPath (Join-Path $root "systemvars.json"))) {
        Write-Host "Initializing the new private Leither node at $root..."
        Push-Location $root
        try {
            & $binary init
            if ($LASTEXITCODE -ne 0) { throw "Leither initialization failed; its files were retained at $root." }
        } finally {
            Pop-Location
        }
    }
    $vars = @("SystemVars.json", "systemvars.json") | ForEach-Object { Join-Path $root $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $vars -or -not (Test-Path -LiteralPath (Join-Path $root "hostkey.cfg") -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $root "ds\config") -PathType Leaf)) {
        throw "Leither initialization is incomplete. Its files were retained at $root for inspection."
    }
    Set-NewNodeStorage $root $StorageMaxGB
    Remove-Item -LiteralPath $pending -Force
} elseif ($StorageMaxGB -gt 0) {
    throw "--storage-max-gb is only valid when this installer creates a new Leither node. Change an existing limit from LePan Settings."
}

$version = Get-LeitherVersion $root
$port = Get-LeitherPort $root
$runningAtRoot = $runningRoots -contains $root
if ($NoInstallLeither -and -not $runningAtRoot) { throw "--no-install-leither requires the selected node to be running." }
if ($Upgrade -and -not $runningAtRoot) { throw "--upgrade requires the selected Leither node to be running." }
if (-not $NoInstallLeither -and -not $Upgrade) {
    Grant-SystemTaskAccess $root
    if (-not $runningAtRoot) { Assert-PortAvailable $port }
    Register-LeitherTask $root (-not $runningAtRoot)
}
Ensure-LeitherFirewall $root $port
if (-not $runningAtRoot) { Wait-Leither $root $version $port }
Write-Host "Leither V$version is ready at $root on port $port."

if ($LeitherService) {
    Write-Host "Leither startup and firewall configuration are complete. LifeDrive files were not changed."
    return
}

# The identity task also runs as SYSTEM, including when Leither itself is
# managed separately through --no-install-leither.
Grant-SystemTaskAccess $root

$config = Join-Path $root ".lifedrive-household\identity.json"
$routes = Join-Path $root "lifeDrive.households.json"
if ($Upgrade) {
    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
        throw "LifeDrive upgrade stopped: no Windows household installation was found at $root."
    }
} else {
    if (Test-Path -LiteralPath (Join-Path $root "lifeDrive.owner") -PathType Leaf) {
        throw "This node uses the legacy browser-owner setup, which Windows does not migrate automatically. Its files were left unchanged."
    }
    if (Test-Path -LiteralPath $routes -PathType Leaf) {
        throw "An initialized LifeDrive household already exists. Rerun with --upgrade."
    }
}

$expectedChecksum = ((Get-Content -LiteralPath $checksumFile -Raw).Trim() -split "\s+")[0].ToLowerInvariant()
$actualChecksum = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($expectedChecksum -notmatch '^[a-f0-9]{64}$' -or $actualChecksum -ne $expectedChecksum) {
    throw "LifeDrive release verification failed; the package was not installed."
}

$installTemp = Join-Path ([IO.Path]::GetTempPath()) ("lifedrive-install-" + [Guid]::NewGuid().ToString("N"))
$extract = Join-Path $installTemp "bundle"
New-Item -ItemType Directory -Path $extract -Force | Out-Null
$identityTaskStopped = $false
try {
    & tar.exe -xzf $archive -C $extract
    if ($LASTEXITCODE -ne 0) { throw "LifeDrive release archive could not be extracted." }
    $sourceApp = Join-Path $extract "lifeDrive"
    $sourceIdentity = Join-Path $extract "identity"
    if (-not (Test-Path -LiteralPath (Join-Path $sourceApp "main.go") -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $sourceIdentity "lifedrive-identity-windows-amd64.exe") -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $sourceIdentity "setup-node.ps1") -PathType Leaf)) {
        throw "LifeDrive release verification failed; required Windows files are missing."
    }

    $identityTask = Get-ScheduledTask -TaskName $identityTaskName -ErrorAction SilentlyContinue
    $installedIdentity = Join-Path $root "lifedrive-identity\lifedrive-identity-windows-amd64.exe"
    if ($identityTask) {
        if ($identityTask.Actions.Count -ne 1 -or [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($identityTask.Actions[0].Execute)) -ne [IO.Path]::GetFullPath($installedIdentity)) {
            throw "A different scheduled task named '$identityTaskName' already exists. It was not stopped."
        }
        if ($identityTask.State -eq "Running") {
            Stop-ScheduledTask -TaskName $identityTaskName
            $identityTaskStopped = $true
            for ($attempt = 0; $attempt -lt 30; $attempt++) {
                if ((Get-ScheduledTask -TaskName $identityTaskName).State -ne "Running") { break }
                Start-Sleep -Seconds 1
            }
            if ((Get-ScheduledTask -TaskName $identityTaskName).State -eq "Running") {
                throw "The existing LifeDrive identity task did not stop; installed files were not changed."
            }
        }
    }

    $destinationApp = Join-Path $root "lifeDrive"
    if (Test-Path -LiteralPath $destinationApp -PathType Container) {
        $backupRoot = Join-Path $root ("deploy-backups\lifedrive-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ"))
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        Copy-Item -LiteralPath $destinationApp -Destination $backupRoot -Recurse
        Write-Host "Previous LifeDrive files backed up to $backupRoot"
    }
    New-Item -ItemType Directory -Path $destinationApp -Force | Out-Null
    foreach ($obsolete in @("web", "inoku", "index_entry.js", "index.css", "lifeDrive-install-service.sh")) {
        Remove-Item -LiteralPath (Join-Path $destinationApp $obsolete) -Recurse -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -LiteralPath $sourceApp -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $destinationApp -Recurse -Force
    }

    $destinationIdentity = Join-Path $root "lifedrive-identity"
    New-Item -ItemType Directory -Path $destinationIdentity -Force | Out-Null
    Get-ChildItem -LiteralPath $sourceIdentity -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $destinationIdentity -Recurse -Force
    }
} catch {
    if ($identityTaskStopped) {
        try { Start-ScheduledTask -TaskName $identityTaskName } catch {}
    }
    throw
} finally {
    Remove-Item -LiteralPath $installTemp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Upgrade) {
    try {
        & (Join-Path $root "lifedrive-identity\setup-node.ps1") -LeitherRoot $root -Upgrade
    } catch {
        if ($identityTaskStopped) {
            try { Start-ScheduledTask -TaskName $identityTaskName } catch {}
        }
        throw
    }
    Write-Host "LifeDrive Windows upgrade complete. Leither was not restarted."
    return
}
try {
    & (Join-Path $root "lifedrive-identity\setup-node.ps1") -LeitherRoot $root
} catch {
    if ($identityTaskStopped) {
        try { Start-ScheduledTask -TaskName $identityTaskName } catch {}
    }
    throw
}

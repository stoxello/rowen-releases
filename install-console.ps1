$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'Rowen Console requires 64-bit Windows.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open PowerShell as Administrator and run the installer again.'
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'Rowen-installer' }
$releases = @(Invoke-RestMethod -Uri 'https://api.github.com/repos/stoxello/rowen-releases/releases?per_page=100' -Headers $headers)
$releaseTag = $null
$zipAsset = $null
$hashAsset = $null
foreach ($release in $releases) {
    if ($release.draft) { continue }
    $candidateName = "Rowen-Console-win-x64-$($release.tag_name).zip"
    $candidateZip = @($release.assets | Where-Object { $_.name -eq $candidateName }) | Select-Object -First 1
    $candidateHash = @($release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' }) | Select-Object -First 1
    if ($candidateZip -and $candidateHash) {
        $releaseTag = [string]$release.tag_name
        $zipAsset = $candidateZip
        $hashAsset = $candidateHash
        break
    }
}
if (-not $releaseTag -or $releaseTag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$') {
    throw 'No published Rowen release with a Windows x64 Console ZIP and checksums was found.'
}

$serviceName = 'RowenConsole'
$programFilesRoot = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$installDir = Join-Path $programFilesRoot 'Rowen\Console'
$dataDir = Join-Path $env:ProgramData 'Rowen'
$exePath = Join-Path $installDir 'Rowen.Console.exe'
$configPath = Join-Path $installDir 'appsettings.json'
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('rowen-install-' + [guid]::NewGuid().ToString('N'))
$zipName = "Rowen-Console-win-x64-$releaseTag.zip"
$zipPath = Join-Path $tempDir $zipName
$hashPath = Join-Path $tempDir 'SHA256SUMS.txt'
$stageDir = Join-Path $tempDir 'stage'

New-Item -ItemType Directory -Path $tempDir, $stageDir -Force | Out-Null
try {
    Invoke-WebRequest -Uri $zipAsset.browser_download_url -Headers $headers -OutFile $zipPath
    Invoke-WebRequest -Uri $hashAsset.browser_download_url -Headers $headers -OutFile $hashPath
    $hashText = Get-Content -LiteralPath $hashPath -Raw
    $pattern = '(?m)^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($zipName) + '\s*$'
    $match = [regex]::Match($hashText, $pattern)
    if (-not $match.Success) { throw "No SHA-256 entry for $zipName." }
    $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    if ($actualHash -ine $match.Groups[1].Value) { throw "SHA-256 verification failed for $zipName." }

    Expand-Archive -LiteralPath $zipPath -DestinationPath $stageDir -Force
    if (-not (Test-Path -LiteralPath (Join-Path $stageDir 'Rowen.Console.exe') -PathType Leaf)) {
        throw 'Downloaded archive does not contain Rowen.Console.exe.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $stageDir 'Microsoft.Extensions.Hosting.WindowsServices.dll') -PathType Leaf)) {
        throw 'The newest Console release cannot run as a Windows service yet. Publish a release containing Windows service support.'
    }

    $existing = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction Stop
    if ($existing -and $existing.PathName -notlike "*$exePath*") {
        throw "The $serviceName service already points to another installation: $($existing.PathName)"
    }
    if ($existing -and $existing.State -ne 'Stopped') {
        Stop-Service -Name $serviceName -Force
        (Get-Service -Name $serviceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }

    New-Item -ItemType Directory -Path $installDir, $dataDir -Force | Out-Null
    foreach ($file in Get-ChildItem -LiteralPath $stageDir -Recurse -File) {
        $relativePath = $file.FullName.Substring($stageDir.Length).TrimStart('\')
        if ($relativePath -eq 'appsettings.json' -and (Test-Path -LiteralPath $configPath)) { continue }
        $targetPath = Join-Path $installDir $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $targetPath) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $targetPath -Force
    }

    if (-not (Test-Path -LiteralPath $configPath)) {
        $tokenBytes = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($tokenBytes) } finally { $rng.Dispose() }
        $token = [BitConverter]::ToString($tokenBytes).Replace('-', '')
        $settings = [ordered]@{
            Application = [ordered]@{
                DatabasePath = (Join-Path $dataDir 'Data\rowen.db')
                ModelDirectory = (Join-Path $dataDir 'Models')
                BacktestDirectory = (Join-Path $dataDir 'Backtests')
                LogDirectory = (Join-Path $dataDir 'Logs')
            }
            Qwen = @{ Enabled = $false }
            Risk = @{ LiveTradingEnabled = $false }
            Remote = @{ ControlToken = $token }
        }
        $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8
        Write-Host "Created a control token. Retrieve it later with: `"$exePath`" remote token"
    }

    $adminSid = '*S-1-5-32-544'
    $systemSid = '*S-1-5-18'
    $serviceSid = '*S-1-5-19'
    $userSid = '*' + $identity.User.Value
    & icacls.exe $configPath /inheritance:r /grant:r "${adminSid}:F" "${systemSid}:F" "${serviceSid}:F" "${userSid}:F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict access to appsettings.json.' }
    & icacls.exe $dataDir /inheritance:r /grant:r "${adminSid}:(OI)(CI)F" "${systemSid}:(OI)(CI)F" "${serviceSid}:(OI)(CI)F" "${userSid}:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict access to the Rowen data directory.' }

    if (-not $existing) {
        $binaryPath = '"' + $exePath + '" serve'
        New-Service -Name $serviceName -BinaryPathName $binaryPath -DisplayName 'Rowen Console' -Description 'Rowen paper trading engine and control API' -StartupType Automatic | Out-Null
    } else {
        Set-Service -Name $serviceName -StartupType Automatic
    }
    & sc.exe config $serviceName 'obj=' 'NT AUTHORITY\LocalService' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure the LocalService account.' }
    & sc.exe failure $serviceName 'reset=' '86400' 'actions=' 'restart/5000/restart/5000/restart/5000' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure service recovery.' }
    Start-Service -Name $serviceName
    (Get-Service -Name $serviceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    Write-Host "Installed Rowen Console $releaseTag at $installDir"
    Write-Host "Service $serviceName is running and starts automatically with Windows."
    Write-Host "Check it with: Get-Service $serviceName"
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

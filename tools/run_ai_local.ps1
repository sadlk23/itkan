param(
    [string]$DeviceId = '',
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$clientConfig = Join-Path $projectRoot 'config/ai.emulator.json'
$serverConfig = Join-Path $projectRoot 'config/ai.local.json'
$proxyScript = Join-Path $projectRoot 'tool/local_ai_proxy.mjs'
foreach ($requiredPath in @($serverConfig, $proxyScript)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required local AI file is missing: $requiredPath"
    }
}
$runRoot = & (Join-Path $PSScriptRoot 'prepare_windows.ps1') -PassThru
# Local client gate only; this token may be extracted from the development APK.
# It is unrelated to the provider API key and must never be printed.
$loopbackUrl = 'http://127.0.0.1:8787/ai'
if (Test-Path -LiteralPath $clientConfig) {
    try {
        $clientSettings = Get-Content -LiteralPath $clientConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw 'Could not read the local client configuration. Check config/ai.emulator.json.'
    }
} else {
    $clientSettings = [pscustomobject]@{ AI_BASE_URL = $loopbackUrl; AI_API_FORMAT = 'proxy' }
}
if ($clientSettings.AI_BASE_URL -cne $loopbackUrl -or $clientSettings.AI_API_FORMAT -cne 'proxy') {
    throw 'The emulator client must use the local loopback proxy.'
}
if (-not $clientSettings.PSObject.Properties['AI_PROXY_TOKEN'] -or
    -not $clientSettings.AI_PROXY_TOKEN) {
    $randomBytes = New-Object byte[] 32
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($randomBytes) } finally { $generator.Dispose() }
    $localClientToken = [BitConverter]::ToString($randomBytes).Replace('-', '').ToLowerInvariant()
    $clientSettings | Add-Member -NotePropertyName AI_PROXY_TOKEN -NotePropertyValue $localClientToken -Force
    [IO.File]::WriteAllText($clientConfig, ($clientSettings | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}
if ($clientSettings.AI_PROXY_TOKEN -cnotmatch '^[a-f0-9]{64}$') {
    throw 'Local client token format is invalid. Remove only AI_PROXY_TOKEN and run preparation again.'
}
# Only these client fields belong in an app build, including when an existing
# local config contains additional fields.
$cacheDir = [IO.Directory]::CreateDirectory((Join-Path $projectRoot '.dart_tool')).FullName
$clientDefines = Join-Path $cacheDir 'itkan-ai-client.json'
$defines = [ordered]@{ AI_BASE_URL = $loopbackUrl; AI_API_FORMAT = 'proxy'; AI_PROXY_TOKEN = $clientSettings.AI_PROXY_TOKEN }
[IO.File]::WriteAllText($clientDefines, ($defines | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
function Test-LocalAiProxy {
    try {
        $health = Invoke-RestMethod -Uri 'http://127.0.0.1:8787/health' -TimeoutSec 2
        if ($health.service -eq 'my-fridge-local-ai-proxy' -and $health.ready -eq $true) {
            if ($health.clientAuthentication -ne 'local_token') {
                throw 'An older local AI proxy is running. Restart that proxy before preparing the updated app.'
            }
            return $true
        }
        return $false
    } catch {
        if ($_.Exception.Message -like 'An older local AI proxy*') { throw }
        return $false
    }
}
if (-not (Test-LocalAiProxy)) {
    $nodePath = (Get-Command node -ErrorAction Stop).Source
    Start-Process -FilePath $nodePath -ArgumentList 'tool/local_ai_proxy.mjs' `
        -WorkingDirectory $projectRoot -WindowStyle Hidden | Out-Null
    for ($attempt = 0; $attempt -lt 20 -and -not (Test-LocalAiProxy); $attempt++) {
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-LocalAiProxy)) {
        throw 'The local AI proxy did not become ready. Check its configuration and port 8787.'
    }
}
$adbCommand = Get-Command adb -ErrorAction SilentlyContinue
if ($adbCommand) {
    $adbPath = $adbCommand.Source
} else {
    $sdkRoot = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
    $adbPath = Join-Path $sdkRoot 'platform-tools/adb.exe'
    if (-not (Test-Path -LiteralPath $adbPath)) { throw 'Android adb was not found.' }
}
if (-not $DeviceId) {
    $devices = @(& $adbPath devices | Where-Object { $_ -match '^\S+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
    if ($devices.Count -ne 1) { throw 'Select one running Android device with -DeviceId (for example emulator-5554).' }
    $DeviceId = $devices[0]
}
& $adbPath -s $DeviceId reverse tcp:8787 tcp:8787
if ($LASTEXITCODE -ne 0) { throw 'Could not connect the Android device to the local AI proxy.' }

if ($PrepareOnly) {
    Write-Output 'Local AI proxy and Android forwarding are ready. No provider API key is included in the app.'
    return
}
Push-Location -LiteralPath $runRoot
try {
    $runArguments = @('run', '--debug', '--dart-define-from-file=.dart_tool/itkan-ai-client.json', '-d', $DeviceId)
    & flutter @runArguments
    if ($LASTEXITCODE -ne 0) { throw 'Flutter local AI run failed.' }
} finally {
    Pop-Location
}

param([switch]$PassThru)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$workspaceRoot = Split-Path $projectRoot -Parent
$driveName = 'I:'
if (-not (Test-Path -LiteralPath ($driveName + '\'))) {
    & subst $driveName $workspaceRoot | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the build path alias.' }
}
$mappedProject = Join-Path ($driveName + '\') (Split-Path $projectRoot -Leaf)
if (-not (Test-Path -LiteralPath (Join-Path $mappedProject 'pubspec.yaml') -PathType Leaf)) {
    throw 'I: does not contain this project. Existing drives are never replaced.'
}
# A different clone can have identical source files. A fresh local marker checks
# the directory itself without relying on the console encoding of subst output.
$cacheDir = [IO.Directory]::CreateDirectory((Join-Path $projectRoot '.dart_tool')).FullName
$markerName = 'itkan-drive-' + [guid]::NewGuid().ToString('N') + '.tmp'
$marker = Join-Path $cacheDir $markerName
[IO.File]::Open($marker, [IO.FileMode]::CreateNew).Dispose()
try {
    if (-not (Test-Path -LiteralPath (Join-Path $mappedProject ".dart_tool/$markerName") -PathType Leaf)) {
        throw 'I: points to a different workspace. Its mapping was left unchanged.'
    }
} finally {
    [IO.File]::Delete($marker)
}
if ($PassThru) { return $mappedProject }
Write-Output "Open $mappedProject in Android Studio. Original files stay in the workspace."
Write-Output 'The alias lasts until Windows restarts. Run this script again after restart.'

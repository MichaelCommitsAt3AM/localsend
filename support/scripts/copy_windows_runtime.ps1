param(
    [Parameter(Mandatory = $true)]
    [string]$Destination,
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = 'x64',
    [string]$BuildDirectory,
    [string]$VisualStudioPath
)

$ErrorActionPreference = 'Stop'

# Use the compiler installation selected by CMake, rather than a vendored CRT
# that can be older than the headers used by Flutter and its native plugins.
if (-not $VisualStudioPath) {
    if (-not $BuildDirectory) {
        $BuildDirectory = Join-Path $PSScriptRoot "../../app/build/windows/$Architecture"
    }
    $cache = Join-Path $BuildDirectory 'CMakeCache.txt'
    if (Test-Path -LiteralPath $cache) {
        $prefix = 'CMAKE_GENERATOR_INSTANCE:INTERNAL='
        $instance = Get-Content -LiteralPath $cache | Where-Object { $_.StartsWith($prefix) } | Select-Object -First 1
        if ($instance) { $VisualStudioPath = $instance.Substring($prefix.Length).Trim() }
    }
    if (-not $VisualStudioPath) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
        $VisualStudioPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($LASTEXITCODE -ne 0 -or -not $VisualStudioPath) { throw 'Visual Studio C++ tools were not found' }
    }
}

$versionFile = Join-Path $VisualStudioPath 'VC/Auxiliary/Build/Microsoft.VCRedistVersion.default.txt'
$version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
$redist = Join-Path $VisualStudioPath "VC/Redist/MSVC/$version/$Architecture"
if (-not (Test-Path -LiteralPath $redist)) { throw "Visual Studio does not have the $Architecture redistributable: $redist" }
$crt = @(Get-ChildItem -LiteralPath $redist -Directory | Where-Object { $_.Name -match '^Microsoft\.VC\d+\.CRT$' })
if ($crt.Count -ne 1) { throw "Expected one $Architecture CRT directory in $redist" }

$required = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
foreach ($name in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $crt[0].FullName $name))) { throw "Runtime library missing: $name" }
}
$toolsetVersion = [version](Get-Content -LiteralPath (Join-Path $VisualStudioPath 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
$runtimeVersion = (Get-Item -LiteralPath (Join-Path $crt[0].FullName 'msvcp140.dll')).VersionInfo.FileVersionRaw
if ($runtimeVersion -lt $toolsetVersion) { throw "Runtime $runtimeVersion is older than compiler toolset $toolsetVersion" }

New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$libraries = @(Get-ChildItem -LiteralPath $crt[0].FullName -File -Filter '*.dll')
foreach ($library in $libraries) {
    Copy-Item -LiteralPath $library.FullName -Destination (Join-Path $Destination $library.Name) -Force
}
Write-Output "Bundled $($libraries.Count) $Architecture Microsoft C++ runtime libraries, version $runtimeVersion"

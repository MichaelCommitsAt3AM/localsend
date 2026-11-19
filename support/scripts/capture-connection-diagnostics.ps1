param(
    [string]$PhoneIp,
    [string]$OutputDirectory = (Join-Path $env:TEMP ('localsend-diagnostics-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

# Read-only snapshot: run while the failure is present, before restarting either app.
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
Get-Date -Format o | Set-Content (Join-Path $OutputDirectory 'time.txt')
adb devices -l | Set-Content (Join-Path $OutputDirectory 'adb-devices.txt')
$appProcessId = ((adb shell pidof org.localsend.localsend_app) -join '').Trim()
if ($appProcessId -match '^\d+$') {
    adb logcat -d --pid=$appProcessId -v threadtime | Set-Content (Join-Path $OutputDirectory 'phone-app-log.txt')
}
adb shell dumpsys package org.localsend.localsend_app | Select-String 'versionName|versionCode' | Set-Content (Join-Path $OutputDirectory 'phone-version.txt')
$phoneInterfaces = adb shell ip -o -4 addr show
$phoneInterfaces | Set-Content (Join-Path $OutputDirectory 'phone-addresses.txt')
if (!$PhoneIp) {
    $wifi = $phoneInterfaces | Select-String '\b(?:s?wlan)\d+\s+inet\s+(\d+\.\d+\.\d+\.\d+)' | Select-Object -First 1
    if ($wifi) { $PhoneIp = $wifi.Matches[0].Groups[1].Value }
}
Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress, PrefixLength | Format-Table | Out-String | Set-Content (Join-Path $OutputDirectory 'pc-addresses.txt')
Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 53317,53318 -or $_.RemotePort -in 53317,53318 } | Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess | Format-Table | Out-String | Set-Content (Join-Path $OutputDirectory 'pc-connections.txt')
if ($PhoneIp) {
    foreach ($port in 53317,53318) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $attempt = $client.ConnectAsync($PhoneIp, $port)
            if (!$attempt.Wait(2000)) { throw 'TCP connection timed out after 2 seconds' }
            "${PhoneIp}:${port} TCP reachable (does not prove HTTP/TLS or request handling is healthy)" | Add-Content (Join-Path $OutputDirectory 'phone-port-probes.txt')
        } catch {
            "${PhoneIp}:${port} FAILED: $($_.Exception.Message)" | Add-Content (Join-Path $OutputDirectory 'phone-port-probes.txt')
        } finally { $client.Dispose() }
    }
}
# Persistent connection logs (since 1.0.7) survive restarts, so collect them even after a force-stop.
$phoneLogs = '/sdcard/Android/data/org.localsend.localsend_app/files/logs'
foreach ($name in 'connection.log', 'connection.log.1') {
    adb pull "$phoneLogs/$name" (Join-Path $OutputDirectory "phone-$name") 2>&1 | Out-Null
}
Get-ChildItem $env:APPDATA -Recurse -Depth 4 -Filter 'connection.log*' -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -eq 'logs' } |
    ForEach-Object { Copy-Item $_.FullName (Join-Path $OutputDirectory "pc-$($_.Name)") }
Write-Output "Diagnostics saved to $OutputDirectory"


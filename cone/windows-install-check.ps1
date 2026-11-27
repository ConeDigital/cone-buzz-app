# What a person gets on Windows (cone-buzz-infra Slice 48, criteria 5a–5d on
# the runner): the installer cone/windows-build.sh made, run silently into a
# scratch folder of this disposable runner as upstream checks its own, every
# Cone setting read back from what it wrote, then the uninstaller. Run from the
# repository root by both Windows build jobs of cone-desktop.yml:
#
#   cone/windows-install-check.ps1 -Version <v>                               the unsigned check
#   cone/windows-install-check.ps1 -Version <v> -Signed -SignTool <signtool>   the release
#
# -Signed adds decision W7's check: the installer before it runs, and then
# Buzz.exe, every bin\*.exe helper and the installed uninstall.exe (tauri#15018:
# a custom sign command has left it unsigned) signed by the publisher in
# cone/tauri.cone.windows.conf.json and timestamped
# (cone/windows-signature-check.ps1). Without it the signatures are listed for
# information only. Exits 1 listing every failed check.
param(
  [Parameter(Mandatory)] [string] $Version,
  [switch] $Signed,
  [string] $SignTool
)
$ErrorActionPreference = 'Stop'
if ($Signed -and -not $SignTool) { throw '-Signed needs -SignTool' }
$fail = [System.Collections.Generic.List[string]]::new()
function Check([bool] $ok, [string] $what) {
  if ($ok) { Write-Output "ok   $what" } else { Write-Output "FAIL $what"; $fail.Add($what) }
}
function Signatures([string] $what, [string[]] $files) {
  & (Join-Path $PSScriptRoot 'windows-signature-check.ps1') -SignTool $SignTool -Publisher $publisher -Path $files
  Check ($LASTEXITCODE -eq 0) "$what signed by $publisher and timestamped"
}
$cone = Get-Content cone/tauri.cone.conf.json -Raw | ConvertFrom-Json
$product = $cone.productName
$identifier = $cone.identifier
$publisher = (Get-Content cone/tauri.cone.windows.conf.json -Raw | ConvertFrom-Json).bundle.publisher
$pubkey = (Get-Content cone/updater.pub -Raw) -replace '\s', ''
$endpoint = (Select-String -Path cone/build.env -Pattern '^BUZZ_UPDATER_ENDPOINT=(.+)$').Matches.Groups[1].Value
$installer = (Resolve-Path "target/release/bundle/nsis/${product}_${Version}_x64-setup.exe").Path
$dest = Join-Path $env:RUNNER_TEMP 'cone-install'
# The Cone icon, frame for frame, in the setup exe (installerIcon in
# cone/tauri.cone.windows.conf.json; NSIS's generic icon otherwise) and in the
# app (bundle.icon): each .ico frame is a PNG copied into the PE's icon
# resources byte for byte.
$ico = [IO.File]::ReadAllBytes((Resolve-Path cone/icons/icon.ico).Path)
$frames = @(for ($i = 0; $i -lt [BitConverter]::ToUInt16($ico, 4); $i++) {
  $size = if ($ico[6 + 16 * $i] -eq 0) { 256 } else { $ico[6 + 16 * $i] }
  $length = [BitConverter]::ToInt32($ico, 6 + 16 * $i + 8); $offset = [BitConverter]::ToInt32($ico, 6 + 16 * $i + 12)
  [pscustomobject]@{ Size = $size; Text = [Text.Encoding]::Latin1.GetString($ico, $offset, $length) }
})
$setup = [Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($installer))
$found = @($frames | Where-Object { $setup.Contains($_.Text) } | ForEach-Object Size)
Check ($found -contains 256) "the setup exe carries cone/icons/icon.ico (frames found: $($found -join ', ') px)"

if ($Signed) {
  Write-Output "== The installer's signature, before it runs"
  Signatures 'the installer' @($installer)
}

# NSIS /D must be last and unquoted.
$process = Start-Process $installer -ArgumentList "/S /D=$dest" -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "the installer exited $($process.ExitCode)" }

Write-Output "== What the installer laid down in $dest"
Get-ChildItem $dest -Recurse -File | Sort-Object FullName | ForEach-Object {
  '{0,12}  {1}' -f $_.Length, $_.FullName.Substring($dest.Length + 1)
}

Write-Output "== The files"
$exe = Join-Path $dest 'Buzz.exe'
Check (Test-Path $exe) "the app is Buzz.exe (upstream's Cargo binary name, as Contents/MacOS/Buzz on a Mac)"
Check (Test-Path (Join-Path $dest 'uninstall.exe')) "uninstall.exe"
foreach ($bin in @('buzz.exe', 'goose-acp.exe', 'buzz-agent-command.exe')) {
  Check (Test-Path (Join-Path $dest "bin\$bin")) "bin\$bin"
}
& (Join-Path $dest 'bin\buzz.exe') --help | Out-Null
Check ($LASTEXITCODE -eq 0) "bin\buzz.exe --help runs"

# Tauri signs a bundled .exe only when it is not signed already, so a helper
# someone else signed would keep that signature: the release fails on it
# (every helper is unsigned upstream today, run 45979828686).
$signable = @(Get-ChildItem $dest -Recurse -Include *.exe, *.dll | Sort-Object FullName)
if ($Signed) {
  Write-Output "== Authenticode signatures (decision W7)"
  Signatures "Buzz.exe, uninstall.exe and the $(@($signable | Where-Object { $_.DirectoryName -eq (Join-Path $dest 'bin') }).Count) bin\ helper(s) — every .exe and .dll installed" @($signable | ForEach-Object FullName)
} else {
  Write-Output "== Authenticode signatures (information only: the unsigned check)"
  $signable | ForEach-Object {
    $sig = Get-AuthenticodeSignature $_.FullName
    '{0,-14} {1}  {2}' -f $sig.Status, $_.FullName.Substring($dest.Length + 1), $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' })
  }
}

Write-Output "== Apps & features (the uninstall entry)"
$uninstall = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$product"
$entry = Get-ItemProperty -LiteralPath $uninstall -ErrorAction SilentlyContinue
if ($entry) { $entry | Select-Object DisplayName, Publisher, DisplayVersion, InstallLocation, DisplayIcon, UninstallString, MainBinaryName | Format-List | Out-String | Write-Output }
Check ($entry.DisplayName -eq $product) "product name '$($entry.DisplayName)' is '$product'"
Check ($entry.Publisher -eq $publisher) "publisher '$($entry.Publisher)' is '$publisher'"
Check ($entry.DisplayVersion -eq $Version) "version '$($entry.DisplayVersion)' is '$Version'"
foreach ($block in @('Buzz Foundation', 'Buzz')) {
  Check (-not (Test-Path -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$block")) "no uninstall entry '$block' (upstream's Windows product name lost to Cone's)"
}

Write-Output "== The identifier and the buzz:// scheme"
$scheme = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Classes\buzz' -ErrorAction SilentlyContinue).'(default)'
$open = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Classes\buzz\shell\open\command' -ErrorAction SilentlyContinue).'(default)'
Check ($scheme -eq "URL:$identifier protocol") "the scheme is '$scheme' (the bundle identifier $identifier)"
Check ($open -eq "`"$exe`" `"%1`"") "buzz:// opens $open"

Write-Output "== Shortcuts and PATH"
$shell = New-Object -ComObject WScript.Shell
foreach ($folder in @('Programs', 'Desktop')) {
  $lnk = Join-Path ([Environment]::GetFolderPath($folder)) "$product.lnk"
  $target = if (Test-Path $lnk) { $shell.CreateShortcut($lnk).TargetPath } else { '<absent>' }
  Check ($target -eq $exe) "$folder\$product.lnk -> $target"
}
$userPath = (Get-ItemProperty HKCU:\Environment).Path -split ';'
# The merge of Cone's deltas kept upstream's bundle.windows.nsis.installerHooks.
Check ($userPath -contains (Join-Path $dest 'bin')) "the user PATH has $dest\bin (upstream's installerHooks ran)"

Write-Output "== The executable"
(Get-Item $exe).VersionInfo | Select-Object ProductName, FileDescription, CompanyName, ProductVersion, FileVersion, LegalCopyright, OriginalFilename | Format-List | Out-String | Write-Output
Check ((Get-Item $exe).VersionInfo.ProductName -eq $product) "its version resource names $product"
$binary = [Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($exe))
$found = @($frames | Where-Object { $binary.Contains($_.Text) } | ForEach-Object Size)
Check ($found -contains 256) "Buzz.exe carries cone/icons/icon.ico (frames found: $($found -join ', ') px)"
Check ($binary.Contains($pubkey)) "cone/updater.pub's key is compiled in"
# The x86_64 compiler may store a short literal as 8-byte immediates (Slice 29
# defect 237): the whole URL, or else every 8-byte piece of it.
if ($binary.Contains($endpoint)) {
  Check $true "the feed $endpoint is compiled in, whole"
} else {
  $pieces = @(for ($i = 0; $i + 8 -le $endpoint.Length; $i += 8) { $endpoint.Substring($i, 8) }) + $endpoint.Substring($endpoint.Length - 8)
  $missing = @($pieces | Where-Object { -not $binary.Contains($_) })
  Check ($missing.Count -eq 0) "the feed $endpoint is compiled in, in 8-byte pieces (missing: $($missing -join ', '))"
}
Check ($binary.Contains('Could not fetch a valid release JSON from the remote')) "the updater plugin is linked (build.rs saw the key and the feed)"
Check (-not ($binary -match 'github\.com/block/buzz(-app)?/releases')) "no Block update endpoint"
Write-Output "info: the identifier $identifier appears in Buzz.exe whole: $($binary.Contains($identifier))"

# A first start, for the record only: the app's data folders follow the
# identifier. A runner may not show a window; nothing fails here.
Write-Output "== A first start (information only)"
$app = Start-Process $exe -PassThru
Start-Sleep -Seconds 30
Write-Output "running after 30 s: $(-not $app.HasExited)"
foreach ($dir in @("$env:APPDATA\$identifier", "$env:LOCALAPPDATA\$identifier", "$env:APPDATA\xyz.block.buzz.desktop", "$env:LOCALAPPDATA\xyz.block.buzz.desktop", "$env:USERPROFILE\.buzz")) {
  Write-Output "$dir exists: $(Test-Path $dir)"
}
Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($dest, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object {
  Write-Output "stopping $($_.Path)"
  Stop-Process -Id $_.Id -Force
}
Start-Sleep -Seconds 5

Write-Output "== The uninstaller"
# _?= runs it in place and waits (NSIS otherwise copies it and returns).
$process = Start-Process (Join-Path $dest 'uninstall.exe') -ArgumentList "/S _?=$dest" -Wait -PassThru
Check ($process.ExitCode -eq 0) "uninstall.exe /S exited $($process.ExitCode)"
Check (-not (Test-Path $exe)) "Buzz.exe removed"
Check (-not (Test-Path -LiteralPath $uninstall)) "the uninstall entry removed"
Check (-not (Test-Path -LiteralPath 'HKCU:\Software\Classes\buzz')) "the buzz:// scheme removed"
Check (-not (Test-Path (Join-Path ([Environment]::GetFolderPath('Programs')) "$product.lnk"))) "the Start menu shortcut removed"
$userPath = (Get-ItemProperty HKCU:\Environment).Path -split ';'
Check (-not ($userPath -contains (Join-Path $dest 'bin'))) "the user PATH entry removed"
# _?= keeps the uninstaller (and so its folder); nothing else may stay.
$left = @(Get-ChildItem $dest -Recurse -File | ForEach-Object { $_.FullName.Substring($dest.Length + 1) })
Check (($left.Count -eq 1) -and ($left[0] -eq 'uninstall.exe')) "the install folder holds only uninstall.exe (left: $($left -join ', '))"

if ($fail.Count -gt 0) { throw "$($fail.Count) check(s) failed: $($fail -join '; ')" }
Write-Output "verify: all checks passed"

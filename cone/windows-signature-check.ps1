# Is each file Authenticode-signed by Cone, and timestamped? (cone-buzz-infra
# Slice 48 decision W7 and criterion 5a, ADR-492.) Run by the Windows jobs of
# cone-desktop.yml: the sign probe on its test file, the release build on the
# installer and on everything the installer laid down.
#
#   cone/windows-signature-check.ps1 -SignTool <signtool.exe> -Publisher <CN> -Path <file>...
#
# Per file, both readers must agree: `signtool verify /pa /all /tw` exits 0
# (the Authenticode policy, every signature, a warning — so a failure — when
# one is not timestamped), and Get-AuthenticodeSignature says Valid with a
# signer whose CN is exactly <Publisher> (cone/tauri.cone.windows.conf.json's
# bundle.publisher, the certificate's subject by decision W5) and a timestamp
# authority. Prints the signer, its issuer and the timestamp authority of
# every file; exits 1 naming each file that fails. Nothing here is secret.
param(
  [Parameter(Mandatory)] [string] $SignTool,
  [Parameter(Mandatory)] [string] $Publisher,
  [Parameter(Mandatory)] [string[]] $Path
)
# signtool writes to stderr on a failure; that must reach the log, not stop
# the script before the other files are judged.
$ErrorActionPreference = 'Continue'
if (-not (Test-Path -LiteralPath $SignTool)) { throw "signtool not found at $SignTool" }
$failed = [System.Collections.Generic.List[string]]::new()
foreach ($file in $Path) {
  $name = Split-Path $file -Leaf
  if (-not (Test-Path -LiteralPath $file)) { Write-Output "FAIL $file`: missing"; $failed.Add($file); continue }
  $verify = & $SignTool verify /pa /all /tw $file 2>&1 | Out-String
  $rc = $LASTEXITCODE
  $sig = Get-AuthenticodeSignature -LiteralPath $file
  $signer = $sig.SignerCertificate
  $cn = if ($signer) { $signer.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) } else { '' }
  $issuer = if ($signer) { $signer.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $true) } else { '' }
  $tsa = if ($sig.TimeStamperCertificate) { $sig.TimeStamperCertificate.Subject } else { '' }
  $why = @()
  if ($rc -ne 0) { $why += "signtool verify exited $rc" }
  if ($sig.Status -ne 'Valid') { $why += "status $($sig.Status)" }
  if ($cn -cne $Publisher) { $why += "signer CN '$cn', not '$Publisher'" }
  if (-not $tsa) { $why += 'no timestamp' }
  if ($why.Count -eq 0) {
    Write-Output "ok   $name — $($sig.Status), signer '$($signer.Subject)', issuer '$issuer', valid $($signer.NotBefore.ToString('u'))..$($signer.NotAfter.ToString('u')), timestamp '$tsa'"
  } else {
    Write-Output "FAIL $name — $($why -join '; ') (signer '$(if ($signer) { $signer.Subject })', timestamp '$tsa')"
    Write-Output $verify
    $failed.Add($name)
  }
}
if ($failed.Count -gt 0) {
  Write-Output "signature check: $($failed.Count) of $($Path.Count) not signed by $Publisher with a timestamp: $($failed -join ', ')"
  exit 1
}
Write-Output "signature check: $($Path.Count) file(s) signed by $Publisher, timestamped"

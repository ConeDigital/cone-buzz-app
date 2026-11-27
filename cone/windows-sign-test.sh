#!/usr/bin/env bash
# Tests for cone/windows-sign.sh (cone-buzz-infra Slice 48 decision W7)
# against mocks: a package built here in the dlib's layout, dotnet, signtool
# and az as scripts. No network, no Azure, no Windows: what only a Windows
# runner can show (the registry, the real dlib signing) is the sign probe's
# (cone-desktop.yml, job sign-probe). Each case names the change to the script
# it must catch.
#
#   bash cone/windows-sign-test.sh      (from anywhere)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/cone-sign-test.XXXXXX")"
T="$(cd "$T" && pwd)"
trap 'rm -rf "$T"' EXIT

pass=0 fail=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }
eq() { # <case> <want> <got>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: want '$2', got '$3'"; fi
}
has() { # <case> <needle>: $out contains it
  if grep -qE -- "$2" "$out"; then ok "$1"; else bad "$1: no /$2/ in: $(cat "$out")"; fi
}

# A scratch repository holding the script and a lock pinned to the package
# made here.
repo="$T/repo"
mkdir -p "$repo/cone" "$T/bin" "$T/pkg/bin/x64"
cp "$here/windows-sign.sh" "$repo/cone/"
printf 'dlib' > "$T/pkg/bin/x64/Azure.CodeSigning.Dlib.dll"
runtimeconfig() { # <version> <rollForward>
  printf '{"runtimeOptions":{"tfm":"net10.0","framework":{"name":"Microsoft.NETCore.App","version":"%s"},"rollForward":"%s"}}\n' "$1" "$2" \
    > "$T/pkg/bin/x64/Azure.CodeSigning.Dlib.runtimeconfig.json"
  rm -f "$T/pkg.nupkg"
  (cd "$T/pkg" && python3 -m zipfile -c "$T/pkg.nupkg" bin >/dev/null)
}
runtimeconfig 10.0.0 Major
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
lockfile() { # <sha256> [extra line]
  sed -e "s/^DLIB_SHA256=.*/DLIB_SHA256=$1/" "$here/windows-sign.lock" > "$repo/cone/windows-sign.lock"
  if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" >> "$repo/cone/windows-sign.lock"; fi
}
lockfile "$(sha "$T/pkg.nupkg")"

# dotnet lists $RUNTIMES (CRLF, as on Windows); signtool records its argv
# per call and exits $SIGNTOOL_RC; az answers expires_on with $AZ_EXPIRES and
# refuses any call that would print the token itself.
cat > "$T/bin/dotnet" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == --list-runtimes ]] || exit 2
for r in $RUNTIMES; do printf 'Microsoft.NETCore.App %s [C:\\Program Files\\dotnet\\shared\\Microsoft.NETCore.App]\r\n' "$r"; done
printf 'Microsoft.WindowsDesktop.App 10.0.1 [C:\\Program Files\\dotnet\\shared\\Microsoft.WindowsDesktop.App]\r\n'
EOF
cat > "$T/bin/signtool.exe" <<'EOF'
#!/usr/bin/env bash
n=$(( $(ls "$SIGNLOG" 2>/dev/null | wc -l) ))
printf '%s\n' "$@" > "$SIGNLOG/$n"
exit "${SIGNTOOL_RC:-0}"
EOF
cat > "$T/bin/az" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AZLOG"
[[ "$*" == "account get-access-token --resource https://codesigning.azure.net --query expires_on --output tsv" ]] || { echo "az mock: unexpected call: $*" >&2; exit 2; }
printf '%s\r\n' "$AZ_EXPIRES"
EOF
chmod +x "$T/bin/"*
export CONE_DOTNET="$T/bin/dotnet" CONE_SIGNTOOL="$T/bin/signtool.exe" CONE_SIGN_NUPKG="$T/pkg.nupkg"
export CONE_SIGN_ENDPOINT=https://neu.codesigning.azure.net/ CONE_SIGN_ACCOUNT=probe-account CONE_SIGN_PROFILE=probe-profile
export RUNTIMES="8.0.22 10.0.1" SIGNLOG="$T/signlog" AZLOG="$T/azlog"
: > "$AZLOG"
mkdir -p "$SIGNLOG"
W="$repo/cone/windows-sign.sh"
out="$T/out"
prepare() { "$W" prepare "$T/sign" >"$out" 2>&1; }
refused() { # <case> <needle>: prepare refuses, naming <needle>
  if prepare; then bad "$1: accepted"; elif grep -qF -- "$2" "$out"; then ok "$1"; else bad "$1: refused without \"$2\": $(cat "$out")"; fi
}

echo "windows-sign prepare:"
if prepare; then ok "the pinned package, .NET 10, signtool: prepared"; else bad "prepare failed: $(cat "$out")"; fi
delta="$T/sign/tauri.cone-sign.conf.json"
# Kills: the string form (Tauri splits it on spaces), or "%1" glued to
# another argument, or signtool not the command.
got="$(node -e 'const s = require(process.argv[1]).bundle.windows.signCommand;
  console.log([typeof s, s.cmd, s.args.filter((a) => a === "%1").length, s.args[s.args.length - 1]].join("|"))' "$delta")"
eq "the delta: object form, signtool the cmd, \"%1\" one argument, last" "object|$T/bin/signtool.exe|1|%1" "$got"
# Kills: no timestamp (signatures would die with the 72-hour certificate), the
# x86 dlib, the metadata not passed.
got="$(node -e 'const a = require(process.argv[1]).bundle.windows.signCommand.args; console.log(a.slice(0, -1).join(" "))' "$delta")"
want="sign /v /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 /dlib $T/sign/package/bin/x64/Azure.CodeSigning.Dlib.dll /dmdf $T/sign/metadata.json"
eq "the delta: SHA-256, the RFC 3161 timestamp, the x64 dlib, the metadata" "$want" "$got"
# Kills: a credential type left in (DefaultAzureCredential would try it), the
# Azure CLI excluded, or the identifiers not written.
got="$(node -e 'const m = require(process.argv[1]); console.log([m.Endpoint, m.CodeSigningAccountName, m.CertificateProfileName, m.ExcludeCredentials.length, m.ExcludeCredentials.includes("AzureCliCredential"), m.ExcludeCredentials.includes("EnvironmentCredential")].join("|"))' "$T/sign/metadata.json")"
eq "the metadata: the identifiers, nine credential types excluded, the Azure CLI not" "https://neu.codesigning.azure.net/|probe-account|probe-profile|9|false|true" "$got"
# Kills: an identifier echoed into the run log.
if grep -qE 'probe-account|probe-profile|neu\.codesigning' "$out"; then bad "the identifiers are printed: $(cat "$out")"; else ok "no identifier printed"; fi
eq "signtool.path names signtool" "$T/bin/signtool.exe" "$(cat "$T/sign/signtool.path")"

# Kills: the hash not compared (or compared with the lock's own value).
lockfile 0000000000000000000000000000000000000000000000000000000000000000
refused "another package's SHA-256" "the lock pins 0000"
lockfile "$(sha "$T/pkg.nupkg")" DLIB_VERSION=9.9.9
# Kills: a duplicated lock key read as its first or last value.
refused "a lock key twice" "2 lines for DLIB_VERSION"
lockfile "$(sha "$T/pkg.nupkg")"
# Kills: the runtime not checked (the dlib then fails silently at signing).
RUNTIMES="8.0.22 9.0.11" refused "no .NET 10 on the runner" "needs Microsoft.NETCore.App 10.0.0"
# Kills: rollForward ignored (a later major refused although the dlib takes it).
if RUNTIMES="11.0.0" prepare; then ok "rollForward Major: .NET 11 alone is enough"; else bad "rollForward Major: .NET 11 refused: $(cat "$out")"; fi
# Kills: any major accepted whatever the dlib's rollForward says.
runtimeconfig 10.0.0 Minor
lockfile "$(sha "$T/pkg.nupkg")"
RUNTIMES="11.0.0" refused "rollForward Minor: .NET 11 is not 10" "rollForward Minor"
runtimeconfig 10.0.0 Major
lockfile "$(sha "$T/pkg.nupkg")"
# Kills: an endpoint the dlib refuses (or a wrong host) passed through.
CONE_SIGN_ENDPOINT=https://neu.example.com/ refused "an endpoint not *.codesigning.azure.net" "CONE_SIGN_ENDPOINT is not"
if grep -qF example.com "$out"; then bad "a refused endpoint is printed"; else ok "a refused endpoint is not printed"; fi
CONE_SIGN_ACCOUNT='' refused "no account" "CONE_SIGN_ACCOUNT"
# Kills: the signing files written into the tree (the clean-tree check would
# fail after the build, or worse, they would be committed).
if "$W" prepare "$repo/cone/sign" >"$out" 2>&1; then bad "a directory inside the tree accepted"; else has "a directory inside the tree refused" "inside the repository"; fi
prepare >/dev/null

echo "windows-sign sign:"
printf 'one' > "$T/one.exe"; printf 'two' > "$T/two dir.exe"
if (cd "$T" && "$W" sign "$T/sign" one.exe "two dir.exe") >"$out" 2>&1; then
  # Kills: "%1" not replaced, a relative path passed, a path with a space split.
  got="$(tail -n 1 "$SIGNLOG/0")|$(tail -n 1 "$SIGNLOG/1")|$(wc -l < "$SIGNLOG/1" | tr -d ' ')|$(find "$SIGNLOG" -type f | wc -l | tr -d ' ')"
  eq "each file signed once, by its absolute path, \"%1\" replaced" "$T/one.exe|$T/two dir.exe|13|2" "$got"
  # Kills: the probe signing with arguments other than the delta's.
  eq "the probe runs the delta's own arguments" \
    "$(node -e 'require(process.argv[1]).bundle.windows.signCommand.args.slice(0, -1).forEach((a) => console.log(a))' "$delta")" \
    "$(head -n 12 "$SIGNLOG/0")"
else
  bad "sign failed: $(cat "$out")"
fi
# Kills: signtool's failure swallowed.
if SIGNTOOL_RC=1 "$W" sign "$T/sign" "$T/one.exe" >"$out" 2>&1; then bad "a failing signtool passed"; else ok "a failing signtool fails the signing"; fi

echo "windows-sign token:"
# Kills: the expiry not checked, or the token itself requested.
# The mock az, never a signed-in one on the workstation.
token() { PATH="$T/bin:$PATH" AZ_EXPIRES="$1" "$W" token >"$out" 2>&1; }
if token $(( $(date +%s) + 3600 )); then has "an hour's token: accepted, its minutes printed" 'for (59|60) more minutes'; else bad "an hour's token refused: $(cat "$out")"; fi
if token $(( $(date +%s) + 600 )); then bad "a 10-minute token accepted"; else has "a 10-minute token refused" "would not outlast"; fi
if token ""; then bad "no token accepted"; else has "no token refused" "gave no token"; fi
eq "az was asked for the expiry alone, three times" 3 "$(grep -c -- '--query expires_on' "$AZLOG")"

echo "windows-sign-test: $pass passed, $fail failed"
(( fail == 0 ))

#!/usr/bin/env bash
# The Windows Authenticode signature: Azure Artifact Signing over GitHub OIDC,
# inside Tauri's build (cone-buzz-infra Slice 48 decision W7, ADR-492). Runs
# in Git Bash on the Windows runner; its pinned inputs are
# cone/windows-sign.lock.
#
#   cone/windows-sign.sh prepare <dir>
#       Before the compile, needing no Azure sign-in: fetch the lock's dlib
#       package, check its SHA-256, find its x64 dlib, assert the .NET runtime
#       its runtimeconfig names is installed (never installed here), find
#       signtool through the Windows SDK's registry root, and write outside
#       the tree, into <dir>:
#         metadata.json            the endpoint, the account, the profile, and
#                                  every credential type but the lock's one
#                                  excluded (from CONE_SIGN_ENDPOINT,
#                                  CONE_SIGN_ACCOUNT, CONE_SIGN_PROFILE; never
#                                  printed)
#         tauri.cone-sign.conf.json  the per-run delta
#                                  bundle.windows.signCommand, object form:
#                                  signtool's path as `cmd`, "%1" an argument
#                                  of its own (the string form splits on spaces)
#         signtool.path            signtool's Windows path, for the checks
#   cone/windows-sign.sh token
#       Right after azure/login: the Azure CLI fetches the token the dlib asks
#       for, so it is cached while GitHub's assertion is fresh; prints when it
#       expires (never the token) and refuses one with under 20 minutes left.
#   cone/windows-sign.sh sign <dir> <file>...
#       Runs <dir>'s signCommand on each file exactly as Tauri does
#       (tauri-bundler 2.10.3 windows/sign.rs: no shell, "%1" replaced by the
#       path): the sign probe signs with the very delta the build uses.
#   cone/windows-sign.sh oidc-lifetime
#       The sign probe's measurement: how long GitHub's OIDC assertion for
#       Azure lives (exp − iat), read from a fresh one; prints no token, and
#       gives the seconds to the step as its output `lifetime`.
#
# Test seams (cone/windows-sign-test.sh, never set by the workflow):
# CONE_SIGN_NUPKG a local package instead of the download (its SHA-256 is
# still checked), CONE_SIGNTOOL a signtool path instead of the registry's,
# CONE_DOTNET the dotnet command.
set -euo pipefail
CALLER_PWD="$PWD"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

die() { echo "windows-sign: $*" >&2; exit 1; }

LOCK=cone/windows-sign.lock
lock() { # <key>: the lock's one value for it
  local v n
  n="$(grep -cE "^$1=" "$LOCK" || true)"
  [[ "$n" == 1 ]] || die "$LOCK has $n lines for $1, not one"
  v="$(sed -n "s/^$1=//p" "$LOCK" | tr -d '\r')"
  [[ -n "$v" ]] || die "$LOCK: $1 is empty"
  printf '%s' "$v"
}

# Every value of the lock, read once here: a missing or doubled key stops the
# script before anything is fetched or written.
DLIB_PACKAGE="$(lock DLIB_PACKAGE)"
DLIB_VERSION="$(lock DLIB_VERSION)"
DLIB_SHA256="$(lock DLIB_SHA256)"
DLIB_PATH="$(lock DLIB_PATH)"
TIMESTAMP_URL="$(lock TIMESTAMP_URL)"
TOKEN_RESOURCE="$(lock TOKEN_RESOURCE)"
CREDENTIAL="$(lock CREDENTIAL)"
KNOWN_CREDENTIALS="$(lock KNOWN_CREDENTIALS)"
SIGNTOOL_MIN_BUILD="$(lock SIGNTOOL_MIN_BUILD)"
[[ "$DLIB_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "$LOCK: DLIB_SHA256 is not a SHA-256"
[[ "$SIGNTOOL_MIN_BUILD" =~ ^[0-9]+$ ]] || die "$LOCK: SIGNTOOL_MIN_BUILD is not a build number"
grep -qw -- "$CREDENTIAL" <<<"$KNOWN_CREDENTIALS" || die "$LOCK: CREDENTIAL $CREDENTIAL is not among KNOWN_CREDENTIALS"

# An argument as the caller meant it: relative to where the script was run.
from_caller() { if [[ "$1" == /* || "$1" == [A-Za-z]:* ]]; then printf '%s' "$1"; else printf '%s' "$CALLER_PWD/$1"; fi; }

# Native Windows programs take D:\… paths, and Git Bash must not rewrite their
# /flags into paths.
if command -v cygpath >/dev/null 2>&1; then
  winpath() { cygpath -w "$1"; }
  unixpath() { cygpath -u "$1"; }
else
  winpath() { printf '%s' "$1"; }
  unixpath() { printf '%s' "$1"; }
fi
native() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$@"; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

find_signtool() {
  if [[ -n "${CONE_SIGNTOOL:-}" ]]; then
    [[ -f "$CONE_SIGNTOOL" ]] || die "CONE_SIGNTOOL '$CONE_SIGNTOOL' is not a file"
    printf '%s' "$CONE_SIGNTOOL"
    return
  fi
  # As tauri-bundler's signtool(): HKLM\SOFTWARE\Microsoft\Windows Kits\Installed
  # Roots, KitsRoot10, its versioned bin folders newest first, x64.
  local key='HKLM\SOFTWARE\Microsoft\Windows Kits\Installed Roots' root kits kit min="$SIGNTOOL_MIN_BUILD" path
  # The 64-bit view first, as Tauri reads it; the SDK also writes the 32-bit
  # one, which some images fill alone.
  root="$( { native reg query "$key" /v KitsRoot10 2>/dev/null || native reg query "$key" /v KitsRoot10 /reg:32 2>/dev/null || true; } \
    | tr -d '\r' | sed -n 's/^ *KitsRoot10 *REG_SZ *//p' | head -n 1)"
  [[ -n "$root" ]] || die "no KitsRoot10 under $key: is the Windows SDK installed?"
  kits="$( { native reg query "$key" 2>/dev/null || true; native reg query "$key" /reg:32 2>/dev/null || true; } | tr -d '\r' \
    | sed -n 's/^HKEY_LOCAL_MACHINE\\.*\\Installed Roots\\\(10\.[0-9.]*\)$/\1/p' | sort -u -t. -k1,1nr -k2,2nr -k3,3nr -k4,4nr)"
  for kit in $kits; do
    (( 10#$(cut -d. -f3 <<<"$kit") >= min )) || continue
    path="$(unixpath "$root")"
    path="${path%/}/bin/$kit/x64/signtool.exe"
    if [[ -f "$path" ]]; then printf '%s' "$path"; return; fi
  done
  die "no x64 signtool.exe of an SDK build $min or later under $root (kits: $(tr '\n' ' ' <<<"$kits"))"
}

cmd_prepare() {
  local dir="${1:-}" package version want file got pkg dlib cfg runtime rt_name rt_version rt_roll dotnet line major found signtool parent
  [[ -n "$dir" ]] || die "usage: cone/windows-sign.sh prepare <dir>"
  dir="$(from_caller "$dir")"
  # Outside the tree: the metadata is the environment's, and a clean tree is
  # asserted after the build.
  parent="$(cd "$(dirname "$dir")" && pwd)" || die "$(dirname "$dir") does not exist"
  [[ "$parent/" != "$PWD/"* ]] || die "$dir is inside the repository; the signing files live outside the tree"
  local endpoint="${CONE_SIGN_ENDPOINT:-}" account="${CONE_SIGN_ACCOUNT:-}" profile="${CONE_SIGN_PROFILE:-}"
  # The identifiers are cone-release secrets: checked for shape, never printed.
  [[ "$endpoint" =~ ^https://[a-z0-9]+\.codesigning\.azure\.net/?$ ]] \
    || die "CONE_SIGN_ENDPOINT is not an https://<region>.codesigning.azure.net endpoint (the dlib accepts no other)"
  [[ "$account" =~ ^[A-Za-z][A-Za-z0-9-]{2,23}$ ]] || die "CONE_SIGN_ACCOUNT is not an Artifact Signing account name"
  [[ "$profile" =~ ^[A-Za-z][A-Za-z0-9-]{4,99}$ ]] || die "CONE_SIGN_PROFILE is not a certificate profile name"

  package="$DLIB_PACKAGE" version="$DLIB_VERSION" want="$DLIB_SHA256"
  dir="$parent/$(basename "$dir")"
  rm -rf "$dir"
  mkdir -p "$dir/package"
  file="$dir/$package.$version.nupkg"
  if [[ -n "${CONE_SIGN_NUPKG:-}" ]]; then
    cp "$CONE_SIGN_NUPKG" "$file"
  else
    local id
    id="$(tr '[:upper:]' '[:lower:]' <<<"$package")"
    curl -fsSL --retry 3 -o "$file" "https://api.nuget.org/v3-flatcontainer/$id/$version/$id.$version.nupkg"
  fi
  got="$(sha256 "$file")"
  [[ "$got" == "$want" ]] || die "$package $version: SHA-256 $got, the lock pins $want — refusing it"
  echo "windows-sign: $package $version, SHA-256 $got (as pinned)"

  # A nupkg is a zip: unzip where there is one, else bsdtar (Windows' own
  # tar.exe, a Mac's tar).
  pkg="$dir/package"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$file" -d "$pkg"
  elif [[ -n "${SYSTEMROOT:-}" && -x "$(unixpath "$SYSTEMROOT")/System32/tar.exe" ]]; then
    native "$(unixpath "$SYSTEMROOT")/System32/tar.exe" -xf "$(winpath "$file")" -C "$(winpath "$pkg")"
  else
    tar -xf "$file" -C "$pkg"
  fi
  dlib="$pkg/$DLIB_PATH"
  [[ -f "$dlib" ]] || die "$package $version has no $DLIB_PATH"
  echo "windows-sign: dlib $DLIB_PATH"

  # The runtime the dlib's host needs: a missing one fails silently, at
  # signing time. Its runtimeconfig names it; rollForward Major takes any
  # later major too.
  cfg="${dlib%.dll}.runtimeconfig.json"
  [[ -f "$cfg" ]] || die "no ${cfg##*/} beside the dlib"
  runtime="$(node -e 'const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).runtimeOptions || {};
    const f = c.framework || {}; if (!f.name || !f.version) process.exit(1);
    console.log([f.name, f.version, c.rollForward || "Minor"].join(" "));' "$cfg")" \
    || die "${cfg##*/} names no framework"
  read -r rt_name rt_version rt_roll <<<"$runtime"
  dotnet="${CONE_DOTNET:-}"
  if [[ -z "$dotnet" ]]; then
    if [[ -n "${PROGRAMFILES:-}" && -f "$(unixpath "$PROGRAMFILES")/dotnet/dotnet.exe" ]]; then
      dotnet="$(unixpath "$PROGRAMFILES")/dotnet/dotnet.exe"
    else
      dotnet=dotnet
    fi
  fi
  major="${rt_version%%.*}"
  found=""
  while read -r line; do
    [[ "$line" =~ ^"$rt_name "([0-9]+)\.[0-9]+\.[0-9]+ ]] || continue
    local m="${BASH_REMATCH[1]}"
    if (( m == major )) || { [[ "$rt_roll" == Major || "$rt_roll" == LatestMajor ]] && (( m > major )); }; then
      found="$line"
    fi
  done < <("$dotnet" --list-runtimes | tr -d '\r')
  [[ -n "$found" ]] || die "the dlib needs $rt_name $rt_version (rollForward $rt_roll); $dotnet --list-runtimes has none — the runner image changed (never installed here, ADR-492)"
  echo "windows-sign: the dlib needs $rt_name $rt_version (rollForward $rt_roll); installed: $found"

  signtool="$(find_signtool)"
  echo "windows-sign: signtool $(winpath "$signtool")"

  # The metadata: every credential type the dlib knows but the lock's one
  # excluded, so only the Azure CLI's sign-in can sign.
  local credential="$CREDENTIAL" known="$KNOWN_CREDENTIALS"
  # shellcheck disable=SC2086 # $known is the lock's space-separated list
  ( umask 077
    node -e 'const [file, endpoint, account, profile, keep, ...known] = process.argv.slice(1);
      const exclude = known.filter((k) => k !== keep);
      require("fs").writeFileSync(file, JSON.stringify({ Endpoint: endpoint, CodeSigningAccountName: account,
        CertificateProfileName: profile, ExcludeCredentials: exclude }, null, 2) + "\n");' \
      "$dir/metadata.json" "$endpoint" "$account" "$profile" "$credential" $known )
  echo "windows-sign: metadata.json (endpoint, account, profile; only $credential allowed)"

  # The delta: signtool sign /v /fd SHA256 /tr <timestamp> /td SHA256
  # /dlib <dlib> /dmdf <metadata> "%1".
  node -e 'const [file, cmd, timestamp, dlib, metadata] = process.argv.slice(1);
    const args = ["sign", "/v", "/fd", "SHA256", "/tr", timestamp, "/td", "SHA256", "/dlib", dlib, "/dmdf", metadata, "%1"];
    require("fs").writeFileSync(file, JSON.stringify({ bundle: { windows: { signCommand: { cmd, args } } } }, null, 2) + "\n");' \
    "$dir/tauri.cone-sign.conf.json" "$(winpath "$signtool")" "$TIMESTAMP_URL" "$(winpath "$dlib")" "$(winpath "$dir/metadata.json")"
  winpath "$signtool" > "$dir/signtool.path"
  echo "windows-sign: $(winpath "$dir/tauri.cone-sign.conf.json"):"
  cat "$dir/tauri.cone-sign.conf.json"
}

cmd_token() {
  local resource="$TOKEN_RESOURCE" exp now left
  exp="$(az account get-access-token --resource "$resource" --query expires_on --output tsv | tr -d '\r')"
  [[ "$exp" =~ ^[0-9]+$ ]] || die "the Azure CLI gave no token for $resource (signed in by azure/login?)"
  now="$(date +%s)"
  left=$(( (exp - now) / 60 ))
  echo "windows-sign: the Azure CLI holds a token for $resource for $left more minutes (until $(date -u -d "@$exp" +%H:%M:%SZ 2>/dev/null || date -u -r "$exp" +%H:%M:%SZ))"
  (( left >= 20 )) || die "a token with $left minutes left would not outlast the signing"
}

cmd_sign() {
  local dir="${1:-}" file cmd a
  shift || true
  [[ -n "$dir" && $# -gt 0 ]] || die "usage: cone/windows-sign.sh sign <dir> <file>..."
  dir="$(from_caller "$dir")"
  [[ -f "$dir/tauri.cone-sign.conf.json" ]] || die "$dir has no tauri.cone-sign.conf.json: run prepare first"
  for file in "$@"; do
    file="$(from_caller "$file")"
    [[ -f "$file" ]] || die "$file is not a file"
    local argv=()
    while IFS= read -r -d '' a; do argv+=("$a"); done < <(node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).bundle.windows.signCommand;
      if (typeof s.cmd !== "string" || !Array.isArray(s.args)) process.exit(1);
      process.stdout.write([s.cmd, ...s.args.map((a) => a === "%1" ? process.argv[2] : a)].map((a) => a + "\0").join(""));' \
      "$dir/tauri.cone-sign.conf.json" "$(winpath "$(cd "$(dirname "$file")" && pwd)/$(basename "$file")")")
    (( ${#argv[@]} > 1 )) || die "$dir/tauri.cone-sign.conf.json has no object-form signCommand"
    cmd="$(unixpath "${argv[0]}")"
    echo "windows-sign: signing $file"
    native "$cmd" "${argv[@]:1}"
  done
}

cmd_oidc_lifetime() {
  [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]] \
    || die "no OIDC request URL: the job needs id-token: write"
  # The request token goes in through stdin, the assertion straight into node;
  # only its iat and exp come out.
  # shellcheck disable=SC2016 # a JavaScript template literal
  printf 'Authorization: bearer %s' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    | curl -fsS -H @- "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" \
    | node -e 'let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
        const c = JSON.parse(Buffer.from(JSON.parse(s).value.split(".")[1], "base64url").toString());
        console.log(`windows-sign: GitHub OIDC assertion for Azure: lives ${c.exp - c.iat} s (iat ${new Date(c.iat * 1000).toISOString()}, exp ${new Date(c.exp * 1000).toISOString()})`);
        if (process.env.GITHUB_OUTPUT) require("fs").appendFileSync(process.env.GITHUB_OUTPUT, `lifetime=${c.exp - c.iat}\n`);
      });'
}

case "${1:-}" in
  prepare) shift; cmd_prepare "$@" ;;
  token) cmd_token ;;
  sign) shift; cmd_sign "$@" ;;
  oidc-lifetime) cmd_oidc_lifetime ;;
  *) die "usage: cone/windows-sign.sh prepare <dir> | token | sign <dir> <file>... | oidc-lifetime" ;;
esac

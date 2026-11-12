# shellcheck shell=bash
# Sourced by cone/cone.just. The build's configuration is cone/build.env and
# nothing else (Slice 29's rule, review of ConeDigital/cone-buzz#1, carried to
# this base by Slice 48). On Buzz 1.0 three readers take BUZZ_* values: build.rs
# (its `rerun-if-env-changed` lines), the plugin manager's native build
# (process values and repository-root .env.local), and vite.config.ts (process
# values, then .env, .env.local, .env.<mode>, .env.<mode>.local). So the build
# refuses any repository-root env file, clears every exported BUZZ_* variable
# and every name those readers mention, and then loads cone/build.env.
# A leftover BUZZ_BUILDERLAB_URL would bring Block's sign-in back; a leftover
# BUZZ_DEFAULT_COMMUNITY_URL would send a new install elsewhere.

cone_build_vars() { # every BUZZ_* name the build's readers mention, and cone/build.env's, one per line
  {
    grep -o 'rerun-if-env-changed=[A-Z0-9_]*' src-tauri/build.rs | cut -d= -f2
    grep -oh 'BUZZ_[A-Z0-9_]*' vite.config.ts
    grep -oE '^BUZZ_[A-Z0-9_]*=' cone/build.env | tr -d =
  } | grep -E '^BUZZ_[A-Z0-9_]+$' | sort -u
}

cone_env_files() { # repository-root env files a reader would load, one per line
  local f
  for f in .env .env.*; do
    [[ -e "$f" && "$f" != .env.example ]] && printf '%s\n' "$f"
  done
  return 0
}

cone_build_env() { # refuse env files, clear every BUZZ_* variable, then load cone/build.env
  local files vars v
  files="$(cone_env_files)"
  if [[ -n "$files" ]]; then
    printf 'cone_build_env: repository-root env file(s) the build would read; move them away:\n%s\n' "$files" >&2
    return 1
  fi
  vars="$(cone_build_vars)"
  [[ "$vars" == *BUZZ_BUILDERLAB_URL* ]] || { echo "cone_build_env: no BUZZ_BUILDERLAB_URL among the build's readers; refusing to guess" >&2; return 1; }
  for v in $vars $(compgen -e | grep '^BUZZ_' || true); do unset "$v"; done
  set -a
  # shellcheck source=cone/build.env
  . cone/build.env
  set +a
}

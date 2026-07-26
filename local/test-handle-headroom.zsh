#!/bin/zsh
set -eu
setopt PIPE_FAIL
umask 077

readonly MANAGER="${0:A:h}/handle-headroom.sh"
typeset -g TEST_ROOT
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
  print -u2 -- "FAIL: $*"
  exit 1
}

assert_contains() {
  local file="$1" text="$2"
  grep -F -- "$text" "$file" >/dev/null || fail "${file} lacks: ${text}"
}

make_repo() {
  local repo="$1"
  mkdir -p "$repo/headroom"
  print -r -- '[project]' > "$repo/pyproject.toml"
  print -r -- 'SOURCE_BYTES_MUST_SURVIVE' > "$repo/headroom/marker"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name "Headroom test"
  git -C "$repo" add pyproject.toml headroom/marker
  git -C "$repo" commit -qm initial
}

make_stubs() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/uv" <<'EOF'
#!/bin/zsh
print -r -- "$PWD|$*" >> "$UV_LOG"
if [[ "$1 $2 $3" == "tool install --force" && "${UV_FAIL_TOOL:-no}" == yes ]]; then
  return 23
fi
if [[ "$1 $2 $3" == "tool install --force" && "${UV_MUTATE_SOURCE:-no}" == yes ]]; then
  print -r -- '# changed during install' >> "$UV_MUTATE_SOURCE_DIR/pyproject.toml"
fi
if [[ "$1 $2" == "python find" ]]; then
  print -r -- /usr/bin/python3
elif [[ "$1 $2 $3" == "tool dir --bin" ]]; then
  print -r -- "$HEADROOM_STUB_BIN"
fi
EOF
  cat > "$bin/headroom" <<'EOF'
#!/bin/zsh
case "$*" in
  "--version") print "headroom test" ;;
  "install apply --help") print -- "--learn --memory-storage --memory opencode" ;;
  "install --help") print -- "apply start stop remove status" ;;
  "proxy --help") print -- "--learn --memory-storage" ;;
esac
EOF
  chmod 700 "$bin/uv" "$bin/headroom"
}

typeset repo="${TEST_ROOT}/source"
make_repo "$repo"

(
  export HOME="${TEST_ROOT}/valid-home"
  export HEADROOM_SOURCE_DIR="$repo"
  export HEADROOM_INSTALL_MODE=editable
  source "$MANAGER" --help >/dev/null
  prepare_headroom_source
  [[ "$SOURCE_SHA" == "$(git -C "$repo" rev-parse HEAD)" ]] || fail "wrong source SHA"
  [[ "$SOURCE_DIRTY" == no ]] || fail "clean source reported dirty"
)

(
  export HOME="${TEST_ROOT}/missing-home"
  export HEADROOM_SOURCE_DIR="${TEST_ROOT}/missing"
  export HEADROOM_INSTALL_MODE=editable
  source "$MANAGER" --help >/dev/null
  if prepare_headroom_source >/dev/null 2>&1; then
    fail "missing source accepted"
  fi
)

(
  export HOME="${TEST_ROOT}/bad-mode-home"
  export HEADROOM_SOURCE_DIR="$repo"
  export HEADROOM_INSTALL_MODE=wheel
  source "$MANAGER" --help >/dev/null
  if prepare_headroom_source >/dev/null 2>&1; then
    fail "invalid install mode accepted"
  fi
)

print -r -- '# dirty' >> "$repo/pyproject.toml"
(
  export HOME="${TEST_ROOT}/dirty-no-home"
  export HEADROOM_SOURCE_DIR="$repo"
  export HEADROOM_INSTALL_MODE=editable
  source "$MANAGER" --help >/dev/null
  if print n | prepare_headroom_source >/dev/null 2>&1; then
    fail "dirty source accepted without confirmation"
  fi
)
(
  export HOME="${TEST_ROOT}/dirty-yes-home"
  export HEADROOM_SOURCE_DIR="$repo"
  export HEADROOM_INSTALL_MODE=editable
  source "$MANAGER" --help >/dev/null
  print y | prepare_headroom_source >/dev/null
  [[ "$SOURCE_DIRTY" == yes ]] || fail "confirmed dirty source not recorded"
)
git -C "$repo" restore pyproject.toml

typeset stub_bin="${TEST_ROOT}/bin"
make_stubs "$stub_bin"

(
  export HOME="${TEST_ROOT}/editable-home"
  export HEADROOM_SOURCE_DIR="$repo"
  export HEADROOM_INSTALL_MODE=editable
  export HEADROOM_STUB_BIN="$stub_bin"
  export UV_LOG="${TEST_ROOT}/editable-uv.log"
  export PATH="${stub_bin}:/usr/bin:/bin"
  source "$MANAGER" --help >/dev/null
  prepare_headroom_source

  print -r -- sentinel > "$HEADROOM_INSTALL_META"
  print -r -- stale > "$repo/headroom/stale"
  git -C "$repo" add headroom/stale
  git -C "$repo" commit -qm stale
  if install_package_with_uv >/dev/null 2>&1; then
    fail "source changed after preflight was accepted"
  fi
  [[ "$(<"$HEADROOM_INSTALL_META")" == sentinel ]] ||
    fail "stale source state replaced provenance"
  prepare_headroom_source

  export UV_MUTATE_SOURCE=yes
  export UV_MUTATE_SOURCE_DIR="$repo"
  if install_package_with_uv >/dev/null 2>&1; then
    fail "source changed during install was accepted"
  fi
  [[ "$(<"$HEADROOM_INSTALL_META")" == sentinel ]] ||
    fail "mid-install source change replaced provenance"
  git -C "$repo" restore pyproject.toml
  export UV_MUTATE_SOURCE=no
  prepare_headroom_source

  export UV_FAIL_TOOL=yes
  if install_package_with_uv >/dev/null 2>&1; then
    fail "failed uv install accepted"
  fi
  [[ "$(<"$HEADROOM_INSTALL_META")" == sentinel ]] ||
    fail "failed install replaced provenance"

  export UV_FAIL_TOOL=no
  install_package_with_uv >/dev/null
  /usr/bin/python3 - "$HEADROOM_INSTALL_META" "${repo:A}" "$SOURCE_SHA" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["source_dir"] == sys.argv[2]
assert data["commit"] == sys.argv[3]
assert data["branch"]
assert data["dirty"] is False
assert data["install_mode"] == "editable"
assert data["installed_at"]
assert set(data) == {
    "source_dir", "commit", "branch", "dirty", "install_mode", "installed_at"
}
PY
  (( $? == 0 )) || fail "source metadata incomplete"
  assert_contains "$UV_LOG" "$repo|tool install --force --python 3.13 --editable .[all,pytorch-mps]"
  if grep -F 'headroom-ai' "$UV_LOG" >/dev/null; then
    fail "local install invoked headroom-ai from PyPI"
  fi

  print -r -- changed > "$repo/headroom/new-file"
  git -C "$repo" add headroom/new-file
  git -C "$repo" commit -qm next
  show_source_status > "${TEST_ROOT}/divergence.txt"
  assert_contains "${TEST_ROOT}/divergence.txt" "DIVERGED"
)

(
  export HOME="${TEST_ROOT}/snapshot-home"
  export HEADROOM_SOURCE_DIR="$repo"
  export HEADROOM_INSTALL_MODE=snapshot
  export HEADROOM_STUB_BIN="$stub_bin"
  export UV_LOG="${TEST_ROOT}/snapshot-uv.log"
  export PATH="${stub_bin}:/usr/bin:/bin"
  source "$MANAGER" --help >/dev/null
  prepare_headroom_source
  install_package_with_uv >/dev/null
  assert_contains "$UV_LOG" "$repo|tool install --force --python 3.13 .[all,pytorch-mps]"
  if grep -F -- '--editable' "$UV_LOG" >/dev/null; then
    fail "snapshot install used --editable"
  fi

  print -r -- '# dirty divergence' >> "$repo/pyproject.toml"
  show_source_status > "${TEST_ROOT}/dirty-divergence.txt"
  assert_contains "${TEST_ROOT}/dirty-divergence.txt" "DIVERGED"
  git -C "$repo" restore pyproject.toml

  typeset original_branch="$(git -C "$repo" branch --show-current)"
  git -C "$repo" switch -qc alternate
  show_source_status > "${TEST_ROOT}/branch-divergence.txt"
  assert_contains "${TEST_ROOT}/branch-divergence.txt" "DIVERGED"
  git -C "$repo" switch -q "$original_branch"
)

(
  export HOME="${TEST_ROOT}/profiles-home"
  export HEADROOM_SOURCE_DIR="$repo"
  source "$MANAGER" --help >/dev/null
  [[ "${PROFILE_PORT[headroom-full]}" == 8787 ]] || fail "slot A port drifted"
  [[ "${PROFILE_PORT[headroom-full-b]}" == 8789 ]] || fail "slot B port drifted"
  [[ "${PROFILE_PORT[headroom-full-global]}" == 8788 ]] || fail "recovery port drifted"
  for profile in $DIAGNOSTIC_PROFILES; do
    [[ "${PROFILE_PORT[$profile]}" != 8787 &&
      "${PROFILE_PORT[$profile]}" != 8788 &&
      "${PROFILE_PORT[$profile]}" != 8789 ]] ||
      fail "diagnostic profile uses reserved port: ${profile}"
  done

  SELECTED_APPS=(claude codex)
  launchd_enable_profile() { return 0 }
  launchd_disable_profile() { return 0 }
  cleanup_failed_profile_start() { return 0 }
  headroom() { return 0 }
  run_logged() {
    print -r -- "$*" >> "${TEST_ROOT}/native-apply.txt"
    return 0
  }
  install_one_profile headroom-full >/dev/null
  assert_contains "${TEST_ROOT}/native-apply.txt" \
    "--memory --learn --memory-storage project"
  assert_contains "${TEST_ROOT}/native-apply.txt" \
    "--target claude --target codex"
  if grep -F -- '--target opencode' "${TEST_ROOT}/native-apply.txt" >/dev/null; then
    fail "optional OpenCode target installed by default"
  fi
  if grep -F -- '--min-evidence' "${TEST_ROOT}/native-apply.txt" >/dev/null; then
    fail "manager overrode candidate/live min_evidence default"
  fi
  if typeset -f patch_profile_manifest >/dev/null ||
    typeset -f apply_installer_compatibility >/dev/null; then
    fail "obsolete manifest compatibility patch remains"
  fi
)

(
  export HOME="${TEST_ROOT}/backup-home"
  export HEADROOM_SOURCE_DIR="$repo"
  source "$MANAGER" --help >/dev/null
  mkdir -p "${HEADROOM_DEPLOY_ROOT}/headroom-full"
  print -r -- '{"profile":"headroom-full"}' \
    > "${HEADROOM_DEPLOY_ROOT}/headroom-full/manifest.json"
  print -r -- '{"source_dir":"'"$repo"'"}' > "$HEADROOM_INSTALL_META"
  backup_headroom_manager_state test manual
  typeset backup="${BACKUP_ROOT}/headroom-manager/test"
  [[ -f "${backup}/headroom-source.json" ]] || fail "source metadata not backed up"
  [[ -f "${backup}/manifests/headroom-full/manifest.json" ]] ||
    fail "manifest not backed up"
  if grep -R -F 'SOURCE_BYTES_MUST_SURVIVE' "$backup" >/dev/null; then
    fail "source checkout content entered backup"
  fi
  [[ ! -e "${backup}/headroom/marker" ]] || fail "source checkout became backup payload"
)

(
  export HOME="${TEST_ROOT}/uninstall-home"
  export HEADROOM_SOURCE_DIR="$repo"
  export HEADROOM_STUB_BIN="$stub_bin"
  export PATH="${stub_bin}:/usr/bin:/bin"
  export UV_LOG="${TEST_ROOT}/uninstall-uv.log"
  source "$MANAGER" --help >/dev/null
  require_macos() { return 0 }
  refresh_uv_path() { return 0 }
  warn_running_apps() { return 0 }
  persist_opencode_config_path() { return 0 }
  find_latest_preinstall_backup() { return 0 }
  load_managed_apps() { SELECTED_APPS=(claude codex opencode) }
  stop_disable_all_profiles() { return 0 }
  remove_one_profile() { return 0 }
  backup_configs() { fail "optional uninstall backup unexpectedly ran" }
  pause() { return 0 }
  confirm() {
    [[ "$1" == "Kontynuować?" || "$1" == "Odinstalować również pakiet uv tool 'headroom-ai'?" ]]
  }
  run_logged() { "$@" }
  uninstall_setup >/dev/null
  [[ "$(<"${repo}/headroom/marker")" == SOURCE_BYTES_MUST_SURVIVE ]] ||
    fail "uninstall changed source checkout"
  git -C "$repo" fsck --no-progress >/dev/null
)

print "PASS: isolated local manager regression"

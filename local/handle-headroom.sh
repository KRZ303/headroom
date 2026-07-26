#!/bin/zsh
# handle-headroom.sh
# Interactive Headroom setup/profile/config manager for macOS + zsh.
#
# Manages seven mutually exclusive persistent profiles:
#   headroom-full                       project slot A, memory + learn + intercept
#   headroom-full-b                     project slot B, memory + learn + intercept
#   headroom-full-global                manual global recovery
#   headroom-no-mem                     diagnostic: no memory + intercept
#   headroom-no-tool-intercept          diagnostic: project memory, no intercept
#   headroom-no-tool-intercept-global   diagnostic: global memory, no intercept
#   headroom-lite                       diagnostic: no memory, no intercept
#
# Claude Code, Codex/ChatGPT Desktop, and OpenCode are the managed install targets.
# No MCP servers are installed or modified.
#
# Canonical source: the live local manager copied on 2026-07-26, then versioned
# here with local-checkout installation and provenance tracking.

emulate -L zsh
setopt PIPE_FAIL
unsetopt NOMATCH
umask 077

readonly SCRIPT_VERSION="1.4.0"
readonly STATE_ROOT="${HOME}/.handle-headroom"
readonly BACKUP_ROOT="${STATE_ROOT}/backup"
readonly SETS_ROOT="${BACKUP_ROOT}/_sets"
readonly LOG_ROOT="${STATE_ROOT}/log"
readonly MANAGED_APPS_FILE="${STATE_ROOT}/managed-apps.txt"
readonly LAST_PREINSTALL_FILE="${STATE_ROOT}/last-pre-install-backup"
readonly OPENCODE_PATH_FILE="${STATE_ROOT}/opencode-config-path"
readonly HEADROOM_INSTALL_META="${STATE_ROOT}/headroom-source.json"
readonly HEADROOM_DEPLOY_ROOT="${HOME}/.headroom/deploy"
readonly HEADROOM_SETTINGS_FILE="${HOME}/.headroom/settings.json"
readonly HEADROOM_SOURCE_DIR="${HEADROOM_SOURCE_DIR:-${HOME}/Dev/headroom}"
readonly HEADROOM_INSTALL_MODE="${HEADROOM_INSTALL_MODE:-editable}"
readonly INITIAL_OPENCODE_CONFIG="${OPENCODE_CONFIG:-}"
readonly STARTUP_READY_GRACE_SECONDS=180

# Different ports are intentional: they prevent one profile from mistaking
# another profile's healthy endpoint for its own process.
typeset -ga MANAGED_PROFILES=(
  headroom-full
  headroom-full-b
  headroom-full-global
  headroom-no-mem
  headroom-no-tool-intercept
  headroom-no-tool-intercept-global
  headroom-lite
)
typeset -ga DIAGNOSTIC_PROFILES=(
  headroom-no-mem
  headroom-no-tool-intercept
  headroom-no-tool-intercept-global
  headroom-lite
)

typeset -gA PROFILE_PORT PROFILE_MEMORY PROFILE_GLOBAL PROFILE_INTERCEPT
PROFILE_PORT=(
  headroom-full 8787
  headroom-full-b 8789
  headroom-full-global 8788
  headroom-no-mem 8790
  headroom-no-tool-intercept 8791
  headroom-no-tool-intercept-global 8792
  headroom-lite 8793
)
PROFILE_MEMORY=(
  headroom-full yes
  headroom-full-b yes
  headroom-full-global yes
  headroom-no-mem no
  headroom-no-tool-intercept yes
  headroom-no-tool-intercept-global yes
  headroom-lite no
)
PROFILE_GLOBAL=(
  headroom-full no
  headroom-full-b no
  headroom-full-global yes
  headroom-no-mem no
  headroom-no-tool-intercept no
  headroom-no-tool-intercept-global yes
  headroom-lite no
)
PROFILE_INTERCEPT=(
  headroom-full yes
  headroom-full-b yes
  headroom-full-global yes
  headroom-no-mem yes
  headroom-no-tool-intercept no
  headroom-no-tool-intercept-global no
  headroom-lite no
)

typeset -ga SELECTED_APPS=()
typeset -ga CHANGED_APPS=()
typeset -g CHOSEN_PROFILE=""
typeset -g CHOSEN_BACKUP_SET=""
typeset -g PYTHON_BIN=""
typeset -g SOURCE_DIR="" SOURCE_SHA="" SOURCE_BRANCH="" SOURCE_DIRTY=""

if [[ -t 1 ]]; then
  readonly C_RESET=$'\e[0m'
  readonly C_BOLD=$'\e[1m'
  readonly C_RED=$'\e[31m'
  readonly C_GREEN=$'\e[32m'
  readonly C_YELLOW=$'\e[33m'
  readonly C_BLUE=$'\e[34m'
  readonly C_CYAN=$'\e[36m'
else
  readonly C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

mkdir -p "$STATE_ROOT" "$BACKUP_ROOT" "$SETS_ROOT" "$LOG_ROOT" || {
  print -u2 -- "ERROR: Nie można utworzyć katalogów stanu w ${STATE_ROOT}."
  exit 1
}
chmod 700 "$STATE_ROOT" "$BACKUP_ROOT" "$SETS_ROOT" "$LOG_ROOT" || {
  print -u2 -- "ERROR: Nie można zabezpieczyć katalogów stanu w ${STATE_ROOT}."
  exit 1
}
readonly RUN_LOG="${LOG_ROOT}/handle-headroom-$(date +%Y%m%d-%H%M%S).log"

print_header() {
  print
  print -P "%F{cyan}%Bhandle-headroom.sh%b%f  v${SCRIPT_VERSION}"
  print "State: ${STATE_ROOT}"
  print
}

info()    { print -P "%F{blue}INFO:%f $*"; }
success() { print -P "%F{green}OK:%f $*"; }
warn()    { print -P "%F{yellow}WARN:%f $*"; }
error()   { print -P "%F{red}ERROR:%f $*" >&2; }

pause() {
  local _dummy
  print
  read -r "_dummy?Naciśnij Enter, aby kontynuować... "
}

confirm() {
  local prompt="$1"
  local default_answer="${2:-yes}"
  local suffix answer
  if [[ "$default_answer" == "yes" ]]; then
    suffix="[T/n]"
  else
    suffix="[t/N]"
  fi
  read -r "answer?${prompt} ${suffix} "
  answer="$(print -r -- "$answer" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "$answer" ]]; then
    [[ "$default_answer" == "yes" ]]
    return
  fi
  [[ "$answer" == "t" || "$answer" == "tak" || "$answer" == "y" || "$answer" == "yes" ]]
}

run_logged() {
  {
    print -n -- "+"
    printf ' %q' "$@"
    print
  } >> "$RUN_LOG" || {
    error "Nie można zapisać logu: ${RUN_LOG}"
    return 1
  }
  "$@" 2>&1 | tee -a "$RUN_LOG"
  local command_rc=${pipestatus[1]} tee_rc=${pipestatus[2]}
  (( command_rc != 0 )) && return $command_rc
  return $tee_rc
}

expand_user_path() {
  local value="$1"
  if [[ "$value" == "~" ]]; then
    print -r -- "$HOME"
  elif [[ "$value" == '~/'* ]]; then
    print -r -- "$HOME/${value#~/}"
  else
    print -r -- "$value"
  fi
}

refresh_uv_path() {
  if command -v uv >/dev/null 2>&1; then
    local uv_bin
    uv_bin="$(uv tool dir --bin 2>/dev/null || true)"
    if [[ -n "$uv_bin" && -d "$uv_bin" ]]; then
      path=("$uv_bin" $path)
      export PATH
      rehash
    fi
  fi
}

require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    error "Ten skrypt jest przeznaczony dla macOS."
    return 1
  fi
}

resolve_python_runtime() {
  if [[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]]; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
    return 0
  fi
  if command -v uv >/dev/null 2>&1; then
    PYTHON_BIN="$(uv python find 3.13 2>/dev/null || true)"
    if [[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]]; then
      return 0
    fi
  fi
  error "Brak interpretera Python. Instalacja setupu może dodać Python 3.13 przez uv."
  return 1
}

require_headroom() {
  refresh_uv_path
  if ! command -v headroom >/dev/null 2>&1; then
    error "Komenda 'headroom' nie jest zainstalowana. Uruchom opcję instalacji setupu."
    return 1
  fi
}

headroom_tool_python() {
  local headroom_bin shebang tool_python
  headroom_bin="$(command -v headroom)" || return 1
  shebang="$(head -n 1 "$headroom_bin")" || return 1
  tool_python="${shebang#\#!}"
  if [[ "$shebang" != '#!'* || ! -x "$tool_python" ]]; then
    error "Nie można znaleźć interpretera zainstalowanego pakietu Headroom."
    return 1
  fi
  print -r -- "$tool_python"
}

require_headroom_capabilities() {
  local apply_help install_help proxy_help flag command_name tool_python
  apply_help="$(headroom install apply --help 2>&1)" || {
    error "Nie można odczytać capabilities: headroom install apply --help"
    return 1
  }
  install_help="$(headroom install --help 2>&1)" || return 1
  proxy_help="$(headroom proxy --help 2>&1)" || return 1

  for flag in --preset --runtime --scope --providers --target --profile --port \
    --no-telemetry --env --memory --learn --memory-storage --min-evidence \
    --memory-project-root --intercept-tool-results; do
    if [[ "$apply_help" != *"$flag"* ]]; then
      error "Ta wersja Headrooma nie obsługuje wymaganej flagi ${flag}."
      return 1
    fi
  done
  if (( ${SELECTED_APPS[(Ie)opencode]} )) && [[ "$apply_help" != *"opencode"* ]]; then
    error "Ta wersja Headrooma nie obsługuje targetu OpenCode."
    return 1
  fi
  for command_name in apply start stop remove status; do
    if [[ "$install_help" != *"$command_name"* ]]; then
      error "Ta wersja Headrooma nie obsługuje 'headroom install ${command_name}'."
      return 1
    fi
  done
  for flag in --learn --memory-storage; do
    if [[ "$proxy_help" != *"$flag"* ]]; then
      error "Ta wersja Headrooma nie obsługuje wymaganej flagi proxy ${flag}."
      return 1
    fi
  done
  if (( ${SELECTED_APPS[(Ie)opencode]} )); then
    tool_python="$(headroom_tool_python)" || return 1
    if ! "$tool_python" -c \
      'from headroom.providers.opencode.config import _parse_json_loose, headroom_provider_entry'; then
      error "Ta wersja Headrooma nie udostępnia wymaganych helperów OpenCode."
      return 1
    fi
  fi
}

prepare_headroom_source() {
  local confirm_dirty="${1:-yes}"
  case "$HEADROOM_INSTALL_MODE" in
    editable|snapshot) ;;
    *)
      error "HEADROOM_INSTALL_MODE musi mieć wartość editable albo snapshot."
      return 1
      ;;
  esac

  SOURCE_DIR="${HEADROOM_SOURCE_DIR:A}"
  [[ -f "${SOURCE_DIR}/pyproject.toml" ]] || {
    error "Brak ${SOURCE_DIR}/pyproject.toml."
    return 1
  }
  [[ -d "${SOURCE_DIR}/headroom" ]] || {
    error "Brak katalogu ${SOURCE_DIR}/headroom/."
    return 1
  }
  [[ "$(git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]] || {
    error "${SOURCE_DIR} nie jest worktree Git."
    return 1
  }
  [[ "$(git -C "$SOURCE_DIR" rev-parse --show-toplevel 2>/dev/null)" == "$SOURCE_DIR" ]] || {
    error "${SOURCE_DIR} nie jest katalogiem głównym worktree Git."
    return 1
  }

  SOURCE_SHA="$(git -C "$SOURCE_DIR" rev-parse HEAD)" || return 1
  SOURCE_BRANCH="$(git -C "$SOURCE_DIR" branch --show-current)" || return 1
  [[ -n "$SOURCE_BRANCH" ]] || SOURCE_BRANCH="(detached)"
  if [[ -n "$(git -C "$SOURCE_DIR" status --porcelain)" ]]; then
    SOURCE_DIRTY=yes
    warn "Źródło Headroom ma niezacommitowane zmiany: ${SOURCE_DIR}"
    if [[ "$confirm_dirty" == yes ]]; then
      confirm "Zainstalować jawnie z dirty worktree ${SOURCE_SHA}?" no || {
        error "Instalacja z dirty worktree odrzucona."
        return 1
      }
    fi
  else
    SOURCE_DIRTY=no
  fi
}

write_source_metadata() {
  local tmp="${HEADROOM_INSTALL_META}.tmp.$$"
  SOURCE_META_DIR="$SOURCE_DIR" SOURCE_META_SHA="$SOURCE_SHA" \
    SOURCE_META_BRANCH="$SOURCE_BRANCH" SOURCE_META_DIRTY="$SOURCE_DIRTY" \
    SOURCE_META_MODE="$HEADROOM_INSTALL_MODE" \
    "$PYTHON_BIN" - "$tmp" <<'PY'
import datetime
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = {
    "source_dir": os.environ["SOURCE_META_DIR"],
    "commit": os.environ["SOURCE_META_SHA"],
    "branch": os.environ["SOURCE_META_BRANCH"],
    "dirty": os.environ["SOURCE_META_DIRTY"] == "yes",
    "install_mode": os.environ["SOURCE_META_MODE"],
    "installed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
os.chmod(path, 0o600)
PY
  (( $? == 0 )) || {
    rm -f -- "$tmp"
    return 1
  }
  mv -f "$tmp" "$HEADROOM_INSTALL_META"
}

profile_manifest() {
  print -r -- "${HEADROOM_DEPLOY_ROOT}/$1/manifest.json"
}

profile_installed() {
  [[ -f "$(profile_manifest "$1")" ]]
}

any_profile_installed() {
  local profile
  for profile in $MANAGED_PROFILES; do
    profile_installed "$profile" && return 0
  done
  return 1
}

launchd_label() {
  print -r -- "gui/$(id -u)/com.headroom.$1"
}

launchd_disable_profile() {
  local profile="$1"
  if ! run_logged launchctl disable "$(launchd_label "$profile")"; then
    error "Nie udało się trwale wyłączyć profilu ${profile} w launchd."
    return 1
  fi
}

launchd_enable_profile() {
  local profile="$1"
  if ! run_logged launchctl enable "$(launchd_label "$profile")"; then
    error "Nie udało się trwale włączyć profilu ${profile} w launchd."
    return 1
  fi
}

stop_disable_profile() {
  local profile="$1"
  if profile_installed "$profile" && command -v headroom >/dev/null 2>&1; then
    if ! headroom install stop --profile "$profile" >/dev/null 2>&1; then
      error "Nie udało się zatrzymać profilu ${profile}."
      return 1
    fi
  fi
  launchd_disable_profile "$profile"
}

stop_disable_all_profiles() {
  local profile failed=0
  for profile in $MANAGED_PROFILES; do
    stop_disable_profile "$profile" || failed=1
  done
  return $failed
}

assert_managed_ports_free() {
  if ! command -v lsof >/dev/null 2>&1; then
    error "Brak systemowej komendy lsof; nie można bezpiecznie sprawdzić portów Headrooma."
    return 1
  fi

  local profile port attempt
  local -a busy_profiles=()
  for attempt in {1..20}; do
    busy_profiles=()
    for profile in $MANAGED_PROFILES; do
      port="${PROFILE_PORT[$profile]}"
      lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && busy_profiles+=("$profile")
    done
    (( ${#busy_profiles} == 0 )) && return 0
    (( attempt < 20 )) && sleep 0.25
  done

  error "Porty zarządzane przez skrypt nadal są zajęte: ${busy_profiles[*]}"
  for profile in $busy_profiles; do
    port="${PROFILE_PORT[$profile]}"
    print -u2 -- "--- ${profile}, port ${port} ---"
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >&2 || true
  done
  return 1
}

profile_runtime_alive() {
  local profile="$1"
  local pid_file="${HEADROOM_DEPLOY_ROOT}/${profile}/runner.pid"
  local pid
  [[ -f "$pid_file" ]] || return 1
  pid="$(<"$pid_file")"
  [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null
}

wait_profile_ready() {
  local profile="$1" elapsed
  local port="${PROFILE_PORT[$profile]}"
  for (( elapsed = 0; elapsed < STARTUP_READY_GRACE_SECONDS; elapsed++ )); do
    curl -fsS --max-time 1 "http://127.0.0.1:${port}/readyz" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

start_profile_with_grace() {
  local profile="$1"
  run_logged headroom install start --profile "$profile" && return 0
  profile_runtime_alive "$profile" || return 1

  warn "Proces ${profile} nadal startuje; czekam do ${STARTUP_READY_GRACE_SECONDS}s na MPS/memory."
  wait_profile_ready "$profile" || return 1
  # The second call sees a ready proxy and only activates provider mutations.
  run_logged headroom install start --profile "$profile"
}

cleanup_failed_profile_start() {
  local profile="$1" failed=0
  if profile_installed "$profile" && command -v headroom >/dev/null 2>&1; then
    if ! run_logged headroom install stop --profile "$profile"; then
      error "Nie udało się zatrzymać częściowo uruchomionego profilu ${profile}."
      failed=1
    fi
  fi
  launchd_disable_profile "$profile" || failed=1
  return $failed
}

resolve_config_path() {
  local app="$1" saved_path
  case "$app" in
    claude)
      print -r -- "${HOME}/.claude/settings.json"
      ;;
    codex)
      print -r -- "${HOME}/.codex/config.toml"
      ;;
    opencode)
      if [[ -n "$INITIAL_OPENCODE_CONFIG" ]]; then
        saved_path="$(expand_user_path "$INITIAL_OPENCODE_CONFIG")"
        print -r -- "${saved_path:A}"
      elif [[ -s "$OPENCODE_PATH_FILE" ]]; then
        saved_path="$(<"$OPENCODE_PATH_FILE")"
        [[ -n "$saved_path" ]] && print -r -- "$saved_path"
      elif [[ -f "${HOME}/.config/opencode/opencode.jsonc" ]]; then
        print -r -- "${HOME}/.config/opencode/opencode.jsonc"
      else
        print -r -- "${HOME}/.config/opencode/opencode.json"
      fi
      ;;
    headroom)
      print -r -- "$HEADROOM_SETTINGS_FILE"
      ;;
    *)
      return 1
      ;;
  esac
}

persist_opencode_config_path() {
  local config_path tmp
  config_path="$(resolve_config_path opencode)" || return 1
  config_path="${config_path:A}"
  tmp="${OPENCODE_PATH_FILE}.tmp.$$"
  print -r -- "$config_path" > "$tmp" || return 1
  chmod 600 "$tmp" || return 1
  mv -f "$tmp" "$OPENCODE_PATH_FILE" || return 1
  export OPENCODE_CONFIG="$config_path"
}

ensure_opencode_config_exists() {
  local config_path="$(resolve_config_path opencode)"
  [[ -e "$config_path" ]] && return 0
  mkdir -p "$(dirname "$config_path")" || return 1
  print -r -- '{}' > "$config_path" || return 1
  chmod 600 "$config_path" || return 1
  info "Utworzono pustą konfigurację OpenCode: ${config_path}"
}

preflight_opencode_config() {
  local config_path="$(resolve_config_path opencode)"
  local tool_python
  [[ -f "$config_path" ]] || {
    error "Brak konfiguracji OpenCode: ${config_path}"
    return 1
  }
  tool_python="$(headroom_tool_python)" || return 1
  "$tool_python" - "$config_path" <<'PY'
import json
import re
import sys
from pathlib import Path

from headroom.providers.opencode.config import _parse_json_loose

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
try:
    data = json.loads(text)
except ValueError:
    data = _parse_json_loose(text)
    without_comments = re.sub(r"(?m)//.*$", "", text)
    if data == {} and not re.fullmatch(r"\s*\{\s*\}\s*", without_comments):
        raise SystemExit(
            f"{path}: Headroom nie potrafi bezpiecznie sparsować JSONC; "
            "usuń np. trailing commas lub zapisz plik jako poprawny JSON"
        )
if not isinstance(data, dict):
    raise SystemExit(f"{path} nie zawiera obiektu JSON")
PY
}

app_label() {
  case "$1" in
    claude) print "Claude Code" ;;
    codex) print "Codex / ChatGPT Desktop" ;;
    opencode) print "OpenCode App / CLI" ;;
    headroom) print "Headroom settings" ;;
    *) print "$1" ;;
  esac
}

select_apps() {
  local prompt="${1:-Wybierz aplikacje}"
  local answer token
  local -a tokens=()
  SELECTED_APPS=()

  print
  print -P "%B${prompt}%b"
  print "  1) Wszystkie: Claude + Codex/ChatGPT + OpenCode"
  print "  2) Claude Code"
  print "  3) Codex / ChatGPT Desktop"
  print "  4) OpenCode App / CLI"
  print "Możesz podać kilka pozycji, np. 2,4."
  read -r "answer?Wybór: "

  answer="${${answer//,/ }:l}"
  IFS=' ' read -rA tokens <<< "$answer"
  for token in $tokens; do
    case "$token" in
      1|all|wszystkie)
        SELECTED_APPS=(claude codex opencode)
        return 0
        ;;
      2|claude) SELECTED_APPS+=(claude) ;;
      3|codex|chatgpt) SELECTED_APPS+=(codex) ;;
      4|opencode) SELECTED_APPS+=(opencode) ;;
    esac
  done

  local -a unique_apps=()
  local candidate existing found
  for candidate in $SELECTED_APPS; do
    found=no
    for existing in $unique_apps; do
      [[ "$candidate" == "$existing" ]] && found=yes
    done
    [[ "$found" == no ]] && unique_apps+=("$candidate")
  done
  SELECTED_APPS=("${unique_apps[@]}")
  if (( ${#SELECTED_APPS} == 0 )); then
    warn "Nie wybrano żadnej aplikacji."
    return 1
  fi
}

save_managed_apps() {
  print -l -- $SELECTED_APPS > "$MANAGED_APPS_FILE" || {
    error "Nie można zapisać ${MANAGED_APPS_FILE}."
    return 1
  }
}

load_managed_apps() {
  SELECTED_APPS=()
  if [[ -f "$MANAGED_APPS_FILE" ]]; then
    while IFS= read -r app; do
      [[ -n "$app" ]] && SELECTED_APPS+=("$app")
    done < "$MANAGED_APPS_FILE"
  fi
  if (( ${#SELECTED_APPS} == 0 )); then
    SELECTED_APPS=(claude codex opencode)
  fi
}

# ------------------------- Backup / diff / restore -------------------------

backup_one_app() {
  local app="$1" timestamp="$2" purpose="$3"
  local source dest_dir dest_file
  source="$(resolve_config_path "$app")" || return 1
  dest_dir="${BACKUP_ROOT}/${app}/${timestamp}"
  mkdir -p "$dest_dir" || {
    error "Nie można utworzyć katalogu backupu: ${dest_dir}"
    return 1
  }
  print -r -- "$source" > "${dest_dir}/original-path.txt" || return 1
  print -r -- "$purpose" > "${dest_dir}/purpose.txt" || return 1

  if [[ -e "$source" ]]; then
    dest_file="${dest_dir}/$(basename "$source")"
    cp -p "$source" "$dest_file" || {
      error "Nie można skopiować ${source} do backupu."
      return 1
    }
    shasum -a 256 "$dest_file" > "${dest_dir}/sha256.txt" || {
      error "Nie można zapisać sumy kontrolnej backupu ${dest_file}."
      return 1
    }
    success "Backup $(app_label "$app"): ${dest_file}"
  else
    : > "${dest_dir}/MISSING" || return 1
    info "$(app_label "$app"): plik nie istniał; zapisano stan MISSING."
  fi
}

backup_headroom_manager_state() {
  local timestamp="$1" purpose="$2"
  local dest="${BACKUP_ROOT}/headroom-manager/${timestamp}"
  mkdir -p "${dest}/manifests" || return 1
  print -r -- "$purpose" > "${dest}/purpose.txt" || return 1

  if [[ -f "$HEADROOM_INSTALL_META" ]]; then
    cp -p "$HEADROOM_INSTALL_META" "${dest}/headroom-source.json" || return 1
  else
    : > "${dest}/SOURCE_METADATA_MISSING" || return 1
  fi

  local manifest profile found=no
  for manifest in "${HEADROOM_DEPLOY_ROOT}"/*/manifest.json; do
    [[ -f "$manifest" ]] || continue
    profile="${manifest:h:t}"
    mkdir -p "${dest}/manifests/${profile}" || return 1
    cp -p "$manifest" "${dest}/manifests/${profile}/manifest.json" || return 1
    found=yes
  done
  [[ "$found" == yes ]] || : > "${dest}/MANIFESTS_MISSING"
  find "$dest" -type f ! -name sha256.txt -exec shasum -a 256 {} + \
    > "${dest}/sha256.txt" || return 1
}

backup_configs() {
  local purpose="${1:-manual}"
  shift || true
  local -a apps
  apps=("$@")
  if (( ${#apps} == 0 )); then
    apps=(claude codex opencode)
  fi

  local timestamp app set_dir
  timestamp="$(date +%Y%m%d-%H%M%S)"
  set_dir="${SETS_ROOT}/${timestamp}"
  if [[ -e "$set_dir" ]]; then
    timestamp="${timestamp}-$$"
    set_dir="${SETS_ROOT}/${timestamp}"
  fi

  local -a backup_apps=("${apps[@]}" headroom)
  mkdir -p "$set_dir" || return 1
  if ! print -r -- "$purpose" > "${set_dir}/purpose.txt" ||
    ! print -l -- "${apps[@]}" > "${set_dir}/apps.txt"; then
    rm -rf -- "$set_dir"
    error "Nie można zapisać metadanych backupu ${timestamp}."
    return 1
  fi

  for app in $backup_apps; do
    if ! backup_one_app "$app" "$timestamp" "$purpose"; then
      error "Backup ${timestamp} jest niekompletny; usuwam niedokończony zestaw."
      rm -rf -- "$set_dir"
      local cleanup_app
      for cleanup_app in $backup_apps; do
        rm -rf -- "${BACKUP_ROOT}/${cleanup_app}/${timestamp}"
      done
      return 1
    fi
  done
  if ! backup_headroom_manager_state "$timestamp" "$purpose"; then
    error "Backup ${timestamp} jest niekompletny; usuwam niedokończony stan managera."
    rm -rf -- "$set_dir" "${BACKUP_ROOT}/headroom-manager/${timestamp}"
    local cleanup_app
    for cleanup_app in $backup_apps; do
      rm -rf -- "${BACKUP_ROOT}/${cleanup_app}/${timestamp}"
    done
    return 1
  fi

  if [[ "$purpose" == "pre-install" ]]; then
    print -r -- "$timestamp" > "$LAST_PREINSTALL_FILE" || {
      error "Backup powstał, ale nie można zapisać wskaźnika baseline: ${LAST_PREINSTALL_FILE}"
      return 1
    }
  fi

  success "Utworzono zestaw backupu: ${timestamp}"
  print -r -- "$timestamp"
}

find_latest_preinstall_backup() {
  if [[ -f "$LAST_PREINSTALL_FILE" ]]; then
    local value="$(<"$LAST_PREINSTALL_FILE")"
    if [[ -d "${SETS_ROOT}/${value}" ]]; then
      print -r -- "$value"
      return 0
    fi
  fi

  local latest="" set_dir
  for set_dir in "$SETS_ROOT"/*; do
    [[ -d "$set_dir" ]] || continue
    if [[ -f "${set_dir}/purpose.txt" && "$(cat "${set_dir}/purpose.txt")" == "pre-install" ]]; then
      latest="$(basename "$set_dir")"
    fi
  done
  [[ -n "$latest" ]] && print -r -- "$latest"
}

list_backup_sets() {
  local set_dir purpose apps
  print
  print -P "%BDostępne zestawy backupu:%b"
  for set_dir in "$SETS_ROOT"/*; do
    [[ -d "$set_dir" ]] || continue
    if [[ -f "${set_dir}/purpose.txt" ]]; then
      purpose="$(cat "${set_dir}/purpose.txt")"
    else
      purpose="unknown"
    fi
    if [[ -f "${set_dir}/apps.txt" ]]; then
      apps="$(tr '\n' ',' < "${set_dir}/apps.txt" | sed 's/,$//')"
    else
      apps="<missing>"
    fi
    printf "  %-18s  %-14s  %s\n" "$(basename "$set_dir")" "$purpose" "$apps"
  done
}

choose_backup_set() {
  local default_set="${1:-}"
  local answer
  CHOSEN_BACKUP_SET=""
  list_backup_sets
  if [[ -n "$default_set" ]]; then
    read -r "answer?Timestamp backupu [${default_set}]: "
    answer="${answer:-$default_set}"
  else
    read -r "answer?Timestamp backupu: "
  fi
  if [[ ! -d "${SETS_ROOT}/${answer}" ]]; then
    error "Nie ma zestawu backupu '${answer}'."
    return 1
  fi
  CHOSEN_BACKUP_SET="$answer"
}

backup_payload_path() {
  local app="$1" timestamp="$2"
  local dir="${BACKUP_ROOT}/${app}/${timestamp}"
  local payload_path
  for payload_path in "$dir"/*; do
    [[ -f "$payload_path" ]] || continue
    case "$(basename "$payload_path")" in
      original-path.txt|purpose.txt|sha256.txt|MISSING) ;;
      *) print -r -- "$payload_path"; return 0 ;;
    esac
  done
  return 1
}

compare_one_app() {
  local app="$1" timestamp="$2"
  local dir="${BACKUP_ROOT}/${app}/${timestamp}"
  local current backup

  if [[ ! -d "$dir" ]]; then
    warn "Brak backupu dla $(app_label "$app") w zestawie ${timestamp}."
    return 2
  fi

  if [[ ! -f "${dir}/original-path.txt" ]]; then
    error "Backup ${timestamp} nie ma original-path.txt dla ${app}."
    return 2
  fi
  current="$(<"${dir}/original-path.txt")"
  if [[ -z "$current" ]]; then
    error "Backup ${timestamp} ma pusty original-path.txt dla ${app}."
    return 2
  fi
  print
  print -P "%B$(app_label "$app")%b"
  print "  bieżący: ${current}"
  print "  backup:  ${dir}"

  if [[ -f "${dir}/MISSING" ]]; then
    if [[ ! -e "$current" ]]; then
      success "Bez zmian: plik nadal nie istnieje."
      return 0
    fi
    warn "Przed instalacją plik nie istniał, obecnie istnieje."
    diff -u /dev/null "$current" || true
    return 1
  fi

  backup="$(backup_payload_path "$app" "$timestamp")" || {
    error "Nie znaleziono pliku backupu dla ${app}."
    return 2
  }
  if [[ ! -f "${dir}/sha256.txt" ]] ||
    ! shasum -a 256 -c "${dir}/sha256.txt" >/dev/null 2>&1; then
    error "Backup ${timestamp} dla ${app} ma nieprawidłową sumę kontrolną."
    return 2
  fi

  if [[ ! -e "$current" ]]; then
    warn "Bieżący plik nie istnieje."
    diff -u "$backup" /dev/null || true
    return 1
  fi

  if cmp -s "$backup" "$current"; then
    success "Plik jest identyczny z backupem."
    return 0
  fi

  warn "Plik różni się od backupu:"
  diff -u "$backup" "$current" || true
  return 1
}

restore_one_app() {
  local app="$1" timestamp="$2"
  local dir="${BACKUP_ROOT}/${app}/${timestamp}"
  local current backup
  [[ -d "$dir" ]] || return 1
  [[ -f "${dir}/original-path.txt" ]] || return 1
  current="$(<"${dir}/original-path.txt")"
  [[ -n "$current" ]] || return 1

  if [[ -f "${dir}/MISSING" ]]; then
    if [[ -e "$current" ]]; then
      warn "Backup mówi, że plik wcześniej nie istniał: ${current}"
      if confirm "Usunąć obecny plik, aby odtworzyć stan MISSING?" no; then
        rm -f "$current" || {
          error "Nie można usunąć ${current}."
          return 1
        }
        success "Usunięto ${current}."
      fi
    fi
    return 0
  fi

  backup="$(backup_payload_path "$app" "$timestamp")" || return 1
  if [[ ! -f "${dir}/sha256.txt" ]] ||
    ! shasum -a 256 -c "${dir}/sha256.txt" >/dev/null 2>&1; then
    error "Backup ${timestamp} dla ${app} ma nieprawidłową sumę kontrolną."
    return 1
  fi
  mkdir -p "$(dirname "$current")" || return 1
  cp -p "$backup" "$current" || {
    error "Nie można przywrócić ${current}."
    return 1
  }
  success "Przywrócono $(app_label "$app"): ${current}"
}

compare_and_offer_restore() {
  local timestamp="$1"
  shift || true
  local -a apps
  apps=("$@")
  (( ${#apps} > 0 )) || apps=(claude codex opencode)
  CHANGED_APPS=()

  local app rc fatal=0
  for app in $apps; do
    compare_one_app "$app" "$timestamp"
    rc=$?
    if (( rc == 1 )); then
      CHANGED_APPS+=("$app")
    elif (( rc == 2 )); then
      fatal=1
    fi
  done

  if (( fatal )); then
    error "Backup ${timestamp} jest niekompletny lub uszkodzony; restore został przerwany."
    return 1
  fi

  if (( ${#CHANGED_APPS} == 0 )); then
    success "Wszystkie porównane konfiguracje odpowiadają backupowi."
    return 0
  fi

  print
  warn "Różnice wykryto dla: ${CHANGED_APPS[*]}"
  for app in $CHANGED_APPS; do
    if confirm "Przywrócić $(app_label "$app") z backupu ${timestamp}?" no; then
      restore_one_app "$app" "$timestamp" || return 1
    fi
  done
}

interactive_backup() {
  select_apps "Które konfiguracje zbackupować?" || return
  backup_configs manual $SELECTED_APPS || return
  pause
}

interactive_compare() {
  local default_set timestamp
  default_set="$(find_latest_preinstall_backup || true)"
  choose_backup_set "$default_set" || return
  timestamp="$CHOSEN_BACKUP_SET"
  select_apps "Które konfiguracje porównać?" || return
  compare_and_offer_restore "$timestamp" $SELECTED_APPS || {
    pause
    return 1
  }
  pause
}

# ------------------------- Status -------------------------

process_status() {
  local name="$1" pattern="$2"
  if pgrep -if "$pattern" >/dev/null 2>&1; then
    print -P "  ${C_GREEN}●${C_RESET} ${name}: uruchomiony"
  else
    print -P "  ${C_YELLOW}○${C_RESET} ${name}: nieuruchomiony"
  fi
}

read_profile_state() {
  local manifest="$1"
  "$PYTHON_BIN" - "$manifest" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
if not isinstance(data, dict):
    raise SystemExit("manifest is not an object")
args = data.get("proxy_args")
base_env = data.get("base_env")
port = data.get("port")
if not isinstance(args, list) or not all(isinstance(arg, str) for arg in args):
    raise SystemExit("proxy_args is not a list of strings")
if not isinstance(base_env, dict):
    raise SystemExit("base_env is not an object")
if not isinstance(port, int):
    raise SystemExit("port is not an integer")

global_memory = any(
    args[i] == "--memory-storage" and i + 1 < len(args) and args[i + 1] == "global"
    for i in range(len(args))
)
mode_override = "--mode" in args or "HEADROOM_MODE" in base_env
flags = " ".join(
    (
        f"mem={'yes' if '--memory' in args else 'no'}",
        f"global={'yes' if global_memory else 'no'}",
        f"learn={'yes' if '--learn' in args else 'no'}",
        f"intercept={'yes' if '--intercept-tool-results' in args else 'no'}",
        f"mode_override={'yes' if mode_override else 'no'}",
    )
)
print(f"{port}\t{flags}")
PY
}

show_profile_statuses() {
  print -P "%BProfile Headroom:%b"

  local profile manifest port ready flags state expected_flags drift
  for profile in $MANAGED_PROFILES; do
    manifest="$(profile_manifest "$profile")"
    if [[ ! -f "$manifest" ]]; then
      printf "  %-38s  %s\n" "$profile" "niezainstalowany"
      continue
    fi
    if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
      printf "  %-38s  %s\n" "$profile" "manifest obecny; brak Pythona do walidacji"
      continue
    fi
    state="$(read_profile_state "$manifest")" || {
      printf "  %-38s  %s\n" "$profile" "manifest INVALID"
      continue
    }
    IFS=$'\t' read -r port flags <<< "$state"
    if curl -fsS --max-time 1 "http://127.0.0.1:${port}/readyz" >/dev/null 2>&1; then
      ready="ACTIVE"
    else
      ready="stopped"
    fi
    expected_flags="mem=${PROFILE_MEMORY[$profile]} global=${PROFILE_GLOBAL[$profile]} learn=${PROFILE_MEMORY[$profile]} intercept=${PROFILE_INTERCEPT[$profile]} mode_override=no"
    drift=""
    if [[ "$port" != "${PROFILE_PORT[$profile]}" || "$flags" != "$expected_flags" ]]; then
      drift=" DRIFT"
    fi
    printf "  %-38s  port=%-5s %-7s %s%s\n" "$profile" "$port" "$ready" "$flags" "$drift"
  done
}

show_claude_status() {
  local config_path="$(resolve_config_path claude)"
  print -P "%BClaude Code:%b"
  print "  config: ${config_path}"
  if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
    warn "  brak interpretera Python do odczytu konfiguracji"
    return
  fi
  if [[ ! -f "$config_path" ]]; then
    warn "  plik nie istnieje"
    return
  fi
  "$PYTHON_BIN" - "$config_path" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
try:
    data = json.loads(p.read_text())
except Exception as e:
    print(f"  parse error: {e}")
    raise SystemExit

env = data.get("env") if isinstance(data, dict) else None
env = env if isinstance(env, dict) else {}
print("  ANTHROPIC_BASE_URL:", env.get("ANTHROPIC_BASE_URL", "<native/direct>"))
print("  ENABLE_TOOL_SEARCH:", env.get("ENABLE_TOOL_SEARCH", "<unset>"))
PY
}

show_codex_status() {
  local config_path="$(resolve_config_path codex)"
  print -P "%BCodex / ChatGPT Desktop:%b"
  print "  config: ${config_path}"
  if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
    warn "  brak interpretera Python do odczytu konfiguracji"
    return
  fi
  if [[ ! -f "$config_path" ]]; then
    warn "  plik nie istnieje"
    return
  fi
  "$PYTHON_BIN" - "$config_path" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors="replace")
managed = "# --- Headroom persistent provider ---" in text
provider = re.search(r'(?m)^\s*model_provider\s*=\s*"([^"]+)"', text)
url = re.search(r'(?m)^\s*openai_base_url\s*=\s*"([^"]+)"', text)
print("  Headroom managed block:", "yes" if managed else "no")
print("  model_provider:", provider.group(1) if provider else "<native/default>")
print("  openai_base_url:", url.group(1) if url else "<native/default>")
PY
}

show_opencode_status() {
  local config_path="$(resolve_config_path opencode)"
  print -P "%BOpenCode:%b"
  print "  config: ${config_path}"
  if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
    warn "  brak interpretera Python do odczytu konfiguracji"
    return
  fi
  if [[ ! -f "$config_path" ]]; then
    warn "  plik nie istnieje"
    return
  fi
  "$PYTHON_BIN" - "$config_path" <<'PY'
import json, re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors="replace")
try:
    data = json.loads(text)
except ValueError:
    data = None

if isinstance(data, dict):
    providers = data.get("provider")
    providers = providers if isinstance(providers, dict) else {}
    headroom = providers.get("headroom")
    headroom = headroom if isinstance(headroom, dict) else {}
    options = headroom.get("options")
    options = options if isinstance(options, dict) else {}
    models = headroom.get("models")
    models = models if isinstance(models, dict) else {}
    has_provider = bool(headroom)
    url_value = options.get("baseURL")
    model_name = data.get("model") if isinstance(data.get("model"), str) else None
else:
    has_provider = bool(re.search(r'["\']headroom["\']\s*:', text))
    url = re.search(
        r'["\']headroom["\']\s*:\s*\{.*?["\']baseURL["\']\s*:\s*["\']([^"\']+)',
        text,
        re.DOTALL,
    )
    model = re.search(r'(?m)^\s*["\']model["\']\s*:\s*["\']([^"\']+)', text)
    url_value = url.group(1) if url else None
    model_name = model.group(1) if model else None
    models = {}

print("  provider.headroom:", "yes" if has_provider else "no")
print("  headroom baseURL:", url_value if has_provider and url_value else "<not found>")
print("  headroom models:", len(models) if models else "<missing>")
print("  configured default model:", model_name or "<not pinned in config>")
if has_provider and not models:
    print("  routing:", "BROKEN - provider.headroom has no models")
elif model_name and model_name.startswith("headroom/"):
    print("  routing:", "Headroom")
elif model_name:
    print("  routing:", "BYPASS - choose a headroom/... model")
elif has_provider:
    print("  routing:", "VERIFY - active OpenCode model is stored outside this config")
PY
}

show_source_status() {
  print -P "%BŹródło Headroom:%b"
  if [[ ! -f "$HEADROOM_INSTALL_META" ]]; then
    print "  instalacja: brak zapisanej proweniencji"
    return
  fi
  if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
    print "  metadata: ${HEADROOM_INSTALL_META}; brak Pythona do odczytu"
    return
  fi

  local installed
  installed="$("$PYTHON_BIN" - "$HEADROOM_INSTALL_META" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
required = ("source_dir", "commit", "branch", "dirty", "install_mode", "installed_at")
if not isinstance(data, dict) or any(key not in data for key in required):
    raise SystemExit("incomplete source metadata")
print(
    data["source_dir"],
    data["commit"],
    data["branch"],
    "yes" if data["dirty"] else "no",
    data["install_mode"],
    data["installed_at"],
    sep="\t",
)
PY
  )" || {
    print "  metadata: INVALID"
    return
  }

  local installed_dir installed_sha installed_branch installed_dirty installed_mode installed_at
  IFS=$'\t' read -r installed_dir installed_sha installed_branch installed_dirty installed_mode installed_at <<< "$installed"
  local current_dir="${HEADROOM_SOURCE_DIR:A}" current_sha="<invalid>"
  local current_branch="<invalid>" current_dirty="<unknown>" divergence=""
  if [[ -d "$current_dir" ]] &&
    [[ "$(git -C "$current_dir" rev-parse --is-inside-work-tree 2>/dev/null)" == true ]]; then
    current_sha="$(git -C "$current_dir" rev-parse HEAD 2>/dev/null || print '<invalid>')"
    current_branch="$(git -C "$current_dir" branch --show-current 2>/dev/null || print '<invalid>')"
    [[ -n "$current_branch" ]] || current_branch="(detached)"
    [[ -n "$(git -C "$current_dir" status --porcelain 2>/dev/null)" ]] &&
      current_dirty=yes || current_dirty=no
  fi
  [[ "$installed_dir" != "$current_dir" || "$installed_sha" != "$current_sha" ||
    "$installed_branch" != "$current_branch" || "$installed_dirty" != "$current_dirty" ]] &&
    divergence=" DIVERGED"

  print "  installed source: ${installed_dir}"
  print "  installed commit: ${installed_sha} (${installed_branch}, dirty=${installed_dirty})"
  print "  install mode:     ${installed_mode}"
  print "  installed at:     ${installed_at}"
  print "  current source:   ${current_dir}"
  print "  current commit:   ${current_sha} (${current_branch}, dirty=${current_dirty})${divergence}"
}

show_status() {
  print_header
  refresh_uv_path
  resolve_python_runtime || warn "Szczegóły konfiguracji JSON/TOML będą niedostępne."
  if command -v headroom >/dev/null 2>&1; then
    print "Headroom binary: $(command -v headroom)"
    print "Headroom version: $(headroom --version 2>/dev/null || print unknown)"
  else
    warn "Headroom nie jest zainstalowany lub nie znajduje się w PATH."
  fi
  show_source_status
  if [[ -n "${HEADROOM_MODE:-}" ]]; then
    warn "Bieżąca powłoka eksportuje HEADROOM_MODE=${HEADROOM_MODE}; jawny env może nadpisać panel."
  fi
  if [[ -n "${HEADROOM_SAVINGS_PROFILE:-}" ]]; then
    info "Bieżąca powłoka eksportuje HEADROOM_SAVINGS_PROFILE=${HEADROOM_SAVINGS_PROFILE}."
  fi
  print
  show_profile_statuses
  print
  show_claude_status
  print
  show_codex_status
  print
  show_opencode_status
  print
  print -P "%BProcesy aplikacji:%b"
  process_status "Claude CLI" '(^|/)claude( |$)'
  process_status "ChatGPT Desktop" '/ChatGPT.app/|^ChatGPT$'
  process_status "OpenCode CLI/App" '(^|/)opencode( |$)|/OpenCode.app/'
  print
  info "Command Code (cmd) nie jest natywnym targetem Headroom i nie jest zarządzany przez ten skrypt."
}

# ------------------------- Package + profile installation -------------------------

ensure_uv() {
  if command -v uv >/dev/null 2>&1; then
    return 0
  fi
  warn "Nie znaleziono uv."
  if command -v brew >/dev/null 2>&1 && confirm "Zainstalować uv przez Homebrew?" yes; then
    run_logged brew install uv || return 1
  else
    error "Zainstaluj uv i uruchom skrypt ponownie."
    return 1
  fi
}

ensure_uv_python() {
  ensure_uv || return 1
  run_logged uv python install 3.13 || return 1
  PYTHON_BIN="$(uv python find 3.13 2>/dev/null)" || return 1
  if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
    error "uv nie zwrócił działającego interpretera Python 3.13."
    return 1
  fi
}

install_package_with_uv() {
  [[ -n "$SOURCE_DIR" && -n "$SOURCE_SHA" ]] || {
    error "Źródło Headroom nie zostało zweryfikowane."
    return 1
  }
  local approved_dir="$SOURCE_DIR" approved_sha="$SOURCE_SHA"
  local approved_branch="$SOURCE_BRANCH" approved_dirty="$SOURCE_DIRTY"
  prepare_headroom_source no || return 1
  if [[ "$SOURCE_DIR" != "$approved_dir" || "$SOURCE_SHA" != "$approved_sha" ||
    "$SOURCE_BRANCH" != "$approved_branch" || "$SOURCE_DIRTY" != "$approved_dirty" ]]; then
    error "Źródło Headroom zmieniło się od preflightu; rozpocznij instalację ponownie."
    return 1
  fi
  ensure_uv_python || return 1
  local -a cmd=(uv tool install --force --python 3.13)
  [[ "$HEADROOM_INSTALL_MODE" == "editable" ]] && cmd+=(--editable)
  cmd+=('.[all,pytorch-mps]')

  info "Instaluję Headroom z ${SOURCE_DIR} (${SOURCE_SHA}, ${HEADROOM_INSTALL_MODE})."
  (
    cd "$SOURCE_DIR" || return 1
    run_logged "${cmd[@]}"
  ) || return 1

  refresh_uv_path
  require_headroom || return 1
  prepare_headroom_source no || return 1
  if [[ "$SOURCE_DIR" != "$approved_dir" || "$SOURCE_SHA" != "$approved_sha" ||
    "$SOURCE_BRANCH" != "$approved_branch" || "$SOURCE_DIRTY" != "$approved_dirty" ]]; then
    error "Źródło Headroom zmieniło się podczas instalacji; proweniencja nie została zapisana."
    return 1
  fi
  write_source_metadata || {
    error "Instalacja zakończona, ale nie udało się atomowo zapisać ${HEADROOM_INSTALL_META}."
    return 1
  }
  success "Zainstalowano: $(headroom --version 2>/dev/null || print headroom)"
}

warn_running_apps() {
  local running=()
  pgrep -if '(^|/)claude( |$)' >/dev/null 2>&1 && running+=("Claude")
  pgrep -if '/ChatGPT.app/|^ChatGPT$' >/dev/null 2>&1 && running+=("ChatGPT")
  pgrep -if '(^|/)opencode( |$)|/OpenCode.app/' >/dev/null 2>&1 && running+=("OpenCode")
  if (( ${#running} > 0 )); then
    warn "Uruchomione aplikacje: ${running[*]}"
    warn "Konfiguracja providera jest globalna; zamknij je przed instalacją/przełączaniem."
    confirm "Kontynuować mimo to?" no
    return
  fi
  return 0
}

configure_shared_settings() {
  mkdir -p "$(dirname "$HEADROOM_SETTINGS_FILE")" || return 1
  "$PYTHON_BIN" - "$HEADROOM_SETTINGS_FILE" <<'PY'
import json
import os
import tempfile
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
except (OSError, ValueError) as exc:
    raise SystemExit(f"Nie można odczytać {path}: {exc}")
if not isinstance(data, dict):
    raise SystemExit(f"{path} nie zawiera obiektu JSON")

# Shared by all profiles; profiles differ only in memory/intercept/storage scope.
data["savings_profile"] = "coding"
data["code_aware_enabled"] = True
data["no_memory_tools"] = False
data["no_memory_context"] = False
data.setdefault("min_evidence", 5)

path.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print(path)
PY
  (( $? == 0 )) || return 1
  success "Ustawiono wspólne settings.json: coding/cache, code-aware=on, memory injection/tools=on."
}

configure_opencode_provider_models() {
  local port="$1"
  local config_path="$(resolve_config_path opencode)"
  local tool_python

  [[ -f "$config_path" ]] || {
    error "Headroom nie utworzył konfiguracji OpenCode: ${config_path}"
    return 1
  }
  tool_python="$(headroom_tool_python)" || return 1

  HEADROOM_OPENCODE_PORT="$port" "$tool_python" - "$config_path" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
if not isinstance(data, dict):
    raise SystemExit(f"{path} nie zawiera obiektu JSON")
providers = data.get("provider")
if not isinstance(providers, dict):
    raise SystemExit(f"{path} nie zawiera provider map")
current = providers.get("headroom")
if not isinstance(current, dict):
    raise SystemExit(f"{path} nie zawiera provider.headroom")

port = int(os.environ["HEADROOM_OPENCODE_PORT"])
expected_url = f"http://127.0.0.1:{port}/v1"
models = current.get("models")
options = current.get("options")
if (
    isinstance(models, dict)
    and models
    and isinstance(options, dict)
    and options.get("baseURL") == expected_url
):
    raise SystemExit(0)

from headroom.providers.opencode.config import headroom_provider_entry

providers["headroom"] = headroom_provider_entry(port)
payload = json.dumps(data, indent=2) + "\n"
tmp = path.with_name(path.name + ".tmp")
tmp.write_text(payload, encoding="utf-8")
os.chmod(tmp, path.stat().st_mode & 0o777)
os.replace(tmp, path)
PY
  (( $? == 0 )) || return 1
}

install_one_profile() {
  local profile="$1"
  local port="${PROFILE_PORT[$profile]}"
  local memory="${PROFILE_MEMORY[$profile]}"
  local global="${PROFILE_GLOBAL[$profile]}"
  local intercept="${PROFILE_INTERCEPT[$profile]}"
  local -a cmd

  cmd=(
    headroom install apply
    --profile "$profile"
    --preset persistent-service
    --runtime python
    --scope provider
    --providers manual
    --port "$port"
    --no-telemetry
    --env PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
    --env HEADROOM_EMBEDDER_RUNTIME=pytorch_mps
    --env HEADROOM_KOMPRESS_BACKEND=pytorch_mps
  )

  local app
  for app in $SELECTED_APPS; do
    cmd+=(--target "$app")
  done
  [[ "$intercept" == "yes" ]] && cmd+=(--intercept-tool-results)
  if [[ "$memory" == yes ]]; then
    cmd+=(--memory --learn --memory-storage)
    [[ "$global" == yes ]] && cmd+=(global) || cmd+=(project)
  fi

  print
  print -P "%BInstaluję ${profile}%b (port ${port})"
  # A profile may have been persistently disabled by an earlier switch.
  # Re-enable its launchd label before install/apply bootstraps the new plist.
  launchd_enable_profile "$profile" || return 1
  if ! run_logged "${cmd[@]}"; then
    error "headroom install apply nie powiódł się dla ${profile}; uruchamiam cleanup."
    cleanup_failed_profile_start "$profile" || error "Cleanup ${profile} nie zakończył się w pełni."
    return 1
  fi

  # Leave every newly installed profile inactive until an explicit switch.
  if ! headroom install stop --profile "$profile" >/dev/null 2>&1; then
    error "Nie udało się zatrzymać świeżo utworzonego profilu ${profile}."
    cleanup_failed_profile_start "$profile" || error "Cleanup ${profile} nie zakończył się w pełni."
    return 1
  fi
  launchd_disable_profile "$profile" || return 1

  success "Profil ${profile} zainstalowany i pozostawiony wyłączony."
}

choose_profile() {
  local prompt="${1:-Wybierz profil}"
  local answer
  CHOSEN_PROFILE=""
  print
  print -P "%B${prompt}%b"
  print "  1) headroom-full                       project slot A (8787)"
  print "  2) headroom-full-b                     project slot B (8789)"
  print "  3) headroom-full-global                manual global recovery (8788)"
  print "  4) headroom-no-mem                     diagnostic"
  print "  5) headroom-no-tool-intercept          diagnostic"
  print "  6) headroom-no-tool-intercept-global   diagnostic"
  print "  7) headroom-lite                       diagnostic"
  read -r "answer?Wybór: "
  case "$answer" in
    1|headroom-full|full) CHOSEN_PROFILE="headroom-full" ;;
    2|headroom-full-b|full-b) CHOSEN_PROFILE="headroom-full-b" ;;
    3|headroom-full-global|full-global) CHOSEN_PROFILE="headroom-full-global" ;;
    4|headroom-no-mem|no-mem) CHOSEN_PROFILE="headroom-no-mem" ;;
    5|headroom-no-tool-intercept|no-tool-intercept|no-intercept) CHOSEN_PROFILE="headroom-no-tool-intercept" ;;
    6|headroom-no-tool-intercept-global|no-tool-intercept-global|no-intercept-global) CHOSEN_PROFILE="headroom-no-tool-intercept-global" ;;
    7|headroom-lite|lite) CHOSEN_PROFILE="headroom-lite" ;;
    *) return 1 ;;
  esac
}

switch_to_profile() {
  local target="$1"
  require_headroom || return 1
  if (( ${SELECTED_APPS[(Ie)opencode]} )); then
    persist_opencode_config_path || return 1
  fi
  profile_installed "$target" || {
    error "Profil ${target} nie jest zainstalowany."
    return 1
  }

  stop_disable_all_profiles || return 1
  assert_managed_ports_free || return 1
  launchd_enable_profile "$target" || return 1
  if ! start_profile_with_grace "$target"; then
    error "Start ${target} nie powiódł się; uruchamiam cleanup."
    cleanup_failed_profile_start "$target" || error "Cleanup ${target} nie zakończył się w pełni."
    return 1
  fi
  if (( ${SELECTED_APPS[(Ie)opencode]} )) &&
    ! configure_opencode_provider_models "${PROFILE_PORT[$target]}"; then
    error "Nie udało się uzupełnić modeli providera OpenCode; wycofuję start ${target}."
    cleanup_failed_profile_start "$target" || error "Cleanup ${target} nie zakończył się w pełni."
    return 1
  fi

  success "Aktywny profil: ${target}"
  headroom install status --profile "$target" || true
  warn "Uruchom ponownie Claude/Codex/OpenCode lub rozpocznij nową sesję."
}

interactive_switch() {
  require_macos || return
  require_headroom || return
  warn_running_apps || return
  local target
  choose_profile "Który profil aktywować?" || {
    warn "Nieprawidłowy wybór."
    return
  }
  target="$CHOSEN_PROFILE"
  switch_to_profile "$target" || {
    pause
    return 1
  }
  pause
}

install_setup() {
  require_macos || return
  prepare_headroom_source || return
  ensure_uv_python || return
  warn_running_apps || return
  SELECTED_APPS=(claude codex)
  if confirm "Dodać opcjonalny target OpenCode?" no; then
    SELECTED_APPS+=(opencode)
    persist_opencode_config_path || return
  fi
  save_managed_apps || return

  local profile backup_purpose="pre-install"
  if any_profile_installed; then
    require_headroom || return
    info "Zatrzymuję istniejące profile przed backupem reinstall."
    stop_disable_all_profiles || return
    if [[ -n "$(find_latest_preinstall_backup || true)" ]]; then
      backup_purpose="pre-reinstall"
    fi
  fi

  if confirm "Utworzyć backup konfiguracji przed instalacją?" yes; then
    backup_configs "$backup_purpose" $SELECTED_APPS || return
  else
    warn "Bez backupu automatyczne porównanie i przywracanie po uninstall będzie ograniczone."
  fi
  if (( ${SELECTED_APPS[(Ie)opencode]} )); then
    ensure_opencode_config_exists || return
  fi

  install_package_with_uv || return
  require_headroom || return
  require_headroom_capabilities || return
  preflight_opencode_config || return

  info "Zatrzymuję wszystkie profile zarządzane przez ten skrypt."
  stop_disable_all_profiles || return
  assert_managed_ports_free || return

  for profile in $MANAGED_PROFILES; do
    install_one_profile "$profile" || {
      if (( ${DIAGNOSTIC_PROFILES[(Ie)$profile]} )); then
        warn "Diagnostyczny profil ${profile} nie został zainstalowany; kontynuuję."
        continue
      fi
      error "Instalacja przerwana na profilu ${profile}. Sprawdź log: ${RUN_LOG}"
      return
    }
  done

  if confirm "Ustawić wspólne panel settings: coding/cache + code-aware + memory tools/context?" yes; then
    configure_shared_settings || return
  fi

  local target
  if choose_profile "Który profil uruchomić teraz?"; then
    target="$CHOSEN_PROFILE"
  else
    target="headroom-full"
  fi
  switch_to_profile "$target" || return

  (( ${SELECTED_APPS[(Ie)opencode]} )) &&
    warn "OpenCode: wybierz model headroom/...; skrypt nie zmienia modelu domyślnego."
  success "Cały setup został zainstalowany."
  print "Log: ${RUN_LOG}"
  pause
}

# ------------------------- Uninstall -------------------------

remove_one_profile() {
  local profile="$1"
  if ! profile_installed "$profile"; then
    launchd_enable_profile "$profile" || return 1
    return 0
  fi

  stop_disable_profile "$profile" || return 1
  # Clear the persisted launchd disabled state before deleting the label.
  launchd_enable_profile "$profile" || return 1

  if run_logged headroom install remove --profile "$profile"; then
    success "Usunięto profil ${profile}."
    return 0
  fi

  warn "Standardowe usunięcie profilu ${profile} nie powiodło się."
  if confirm "Wymusić usunięcie plist i katalogu profilu ${profile}?" no; then
    launchctl bootout "$(launchd_label "$profile")" >/dev/null 2>&1 || true
    rm -f "${HOME}/Library/LaunchAgents/com.headroom.${profile}.plist" || return 1
    rm -rf "${HEADROOM_DEPLOY_ROOT}/${profile}" || return 1
    success "Wymuszono usunięcie ${profile}."
  else
    return 1
  fi
}

uninstall_setup() {
  require_macos || return
  refresh_uv_path
  if ! command -v headroom >/dev/null 2>&1; then
    warn "Komenda headroom nie jest dostępna; mogę usunąć tylko pozostałości profili ręcznie."
  fi
  warn_running_apps || return

  print
  warn "Uninstall usunie wszystkie sześć profili i odłączy wszystkie targety zapisane w manifestach."
  confirm "Kontynuować?" no || return
  persist_opencode_config_path || return

  local preinstall
  preinstall="$(find_latest_preinstall_backup || true)"
  if [[ -n "$preinstall" ]]; then
    info "Po uninstall porównam configi z backupem pre-install: ${preinstall}."
  else
    warn "Nie znaleziono backupu pre-install."
  fi

  # Optional safety snapshot of the current Headroom-wired state; this is NOT
  # used as the baseline for restore.
  load_managed_apps
  if confirm "Utworzyć dodatkowy backup stanu bezpośrednio przed uninstall?" yes; then
    backup_configs pre-uninstall $SELECTED_APPS || return
  fi

  stop_disable_all_profiles || return
  local profile
  local -a failed_profiles=()
  for profile in $MANAGED_PROFILES; do
    if ! remove_one_profile "$profile"; then
      failed_profiles+=("$profile")
    fi
  done

  if (( ${#failed_profiles} > 0 )); then
    error "Nie usunięto profili: ${failed_profiles[*]}"
    error "Pakiet i backupy pozostają bez zmian, aby można było dokończyć cleanup."
    return 1
  fi

  if confirm "Odinstalować również pakiet uv tool 'headroom-ai'?" no; then
    if command -v uv >/dev/null 2>&1; then
      run_logged uv tool uninstall headroom-ai || {
        error "uv nie odinstalował headroom-ai."
        return 1
      }
      refresh_uv_path
    else
      error "Brak uv; pakiet headroom-ai nie został odinstalowany."
      return 1
    fi
  fi

  if [[ -n "$preinstall" ]]; then
    compare_and_offer_restore "$preinstall" $SELECTED_APPS headroom || return
  else
    warn "Pominięto diff/restore: brak backupu pre-install."
  fi

  success "Procedura uninstall zakończona."
  print "Log: ${RUN_LOG}"
  pause
}

# ------------------------- Main menu -------------------------

usage() {
  cat <<EOF
handle-headroom.sh ${SCRIPT_VERSION}

Interactive macOS/zsh manager for Headroom profiles and app configuration.

Usage:
  ./handle-headroom.sh             interactive menu
  ./handle-headroom.sh --status    status and config inspection
  ./handle-headroom.sh --help      this help

State and backups:
  ${STATE_ROOT}
EOF
}

main_menu() {
  while true; do
    print_header
    print "Co chcesz zrobić?"
    print "  1) Sprawdź stan Headrooma i konfiguracji aplikacji"
    print "  2) Backup konfiguracji Claude / Codex / OpenCode"
    print "  3) Zainstaluj lub przeinstaluj setup z lokalnego checkoutu"
    print "  4) Przełącz aktywny profil"
    print "  5) Odinstaluj setup + diff + opcjonalny restore"
    print "  6) Porównaj bieżące configi z backupem"
    print "  0) Wyjście"
    print

    local choice
    read -r "choice?Wybór: "
    case "$choice" in
      1) show_status; pause ;;
      2) interactive_backup ;;
      3) install_setup ;;
      4) interactive_switch ;;
      5) uninstall_setup ;;
      6) interactive_compare ;;
      0|q|Q) print "Do widzenia."; return 0 ;;
      *) warn "Nieprawidłowy wybór."; pause ;;
    esac
  done
}

case "${1:-}" in
  --help|-h)
    usage
    ;;
  --status)
    show_status
    ;;
  "")
    main_menu
    ;;
  *)
    error "Nieznany argument: $1"
    usage
    exit 2
    ;;
esac

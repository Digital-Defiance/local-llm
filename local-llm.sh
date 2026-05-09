#!/bin/bash
set -euo pipefail

# Profiles:
#   indexed — embedding + LLM + Qdrant (aliases: vectored, roo)
#   plain   — LLM only, no index (aliases: aider, aider-vision, cursor)
# Usage: ./local-llm.sh [profile] <start|stop|status|help> [stop options...]
#
# Configuration (highest precedence first):
#   1. Environment variables already set (export or VAR=val ./local-llm.sh)
#   2. ~/.config/local-llm/env, then local-llm.env, then .env (later file wins)
#   4. Built-in defaults below
#
# Model names — friendly aliases map to Ollama names:
#   INDEX_MODEL / EMBEDDING_MODEL  →  embedding (indexed profile)
#   DATA_MODEL / CHAT_MODEL / LLM_MODEL  →  chat / generate model

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_LLM_CONFIG_FILE=""

# Vars already set in the environment (export or VAR=val ./local-llm.sh) win over config files.
CONFIG_VARS=(
    LLM_MODE LLM_MODEL DATA_MODEL CHAT_MODEL
    EMBEDDING_MODEL INDEX_MODEL
    OLLAMA_HOST QDRANT_STORAGE QDRANT_CONTAINER_NAME
    ROO_AGENT
)

__LOCAL_LLM_CFG_KEYS=()
__LOCAL_LLM_CFG_VALUES=()

save_config_overrides() {
    local v
    __LOCAL_LLM_CFG_KEYS=()
    __LOCAL_LLM_CFG_VALUES=()
    for v in "${CONFIG_VARS[@]}"; do
        if [[ -n "${!v+x}" ]]; then
            __LOCAL_LLM_CFG_KEYS+=("$v")
            __LOCAL_LLM_CFG_VALUES+=("${!v}")
        fi
    done
}

restore_config_overrides() {
    local i v
    for i in "${!__LOCAL_LLM_CFG_KEYS[@]}"; do
        v="${__LOCAL_LLM_CFG_KEYS[$i]}"
        printf -v "$v" '%s' "${__LOCAL_LLM_CFG_VALUES[$i]}"
    done
}

load_env_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    # shellcheck disable=SC1090
    set -a
    source "$file"
    set +a
    LOCAL_LLM_CONFIG_FILE="$file"
}

load_config() {
    save_config_overrides
    load_env_file "${XDG_CONFIG_HOME:-${HOME}/.config}/local-llm/env"
    load_env_file "${SCRIPT_DIR}/local-llm.env"
    load_env_file "${SCRIPT_DIR}/.env"
    restore_config_overrides
}

load_config

OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
QDRANT_STORAGE="${QDRANT_STORAGE:-${SCRIPT_DIR}/qdrant_storage}"
QDRANT_CONTAINER_NAME="${QDRANT_CONTAINER_NAME:-qdrant}"
EMBEDDING_MODEL="${EMBEDDING_MODEL:-${INDEX_MODEL:-nomic-embed-text}}"
LLM_MODEL="${LLM_MODEL:-${DATA_MODEL:-${CHAT_MODEL:-qwen3.6:27b-q4_K_M}}}"

# LLM_MODE: indexed | plain (ROO_AGENT is deprecated; roo/cursor still accepted)
if [[ -n "${ROO_AGENT:-}" && -z "${LLM_MODE:-}" ]]; then
    LLM_MODE="${ROO_AGENT}"
fi
LLM_MODE="${LLM_MODE:-indexed}"

resolve_llm_mode() {
    case "$1" in
        indexed|vectored|roo) echo "indexed" ;;
        plain|aider|aider-vision|cursor) echo "plain" ;;
        *)
            log_error "Unknown profile: $1"
            show_usage
            return 1
            ;;
    esac
}

normalize_llm_mode() {
    local resolved
    resolved=$(resolve_llm_mode "${LLM_MODE}") || return 1
    LLM_MODE="${resolved}"
}

llm_mode_is_indexed() { [[ "${LLM_MODE}" == "indexed" ]]; }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 is not installed or not in PATH"
        return 1
    fi
}

check_ollama() {
    log_info "Checking if Ollama is running..."
    if curl -s --connect-timeout 5 "${OLLAMA_HOST}/api/tags" > /dev/null 2>&1; then
        log_info "Ollama is already running"
        return 0
    fi

    log_warn "Ollama is not running at ${OLLAMA_HOST}, starting with OLLAMA_MLX=1..."

    local log_dir="${HOME}/.ollama/logs"
    mkdir -p "${log_dir}"
    local log_file="${log_dir}/server.log"

    local max_loaded=2
    if ! llm_mode_is_indexed; then
        max_loaded=1
    fi
    OLLAMA_MAX_LOADED_MODELS="${max_loaded}" OLLAMA_CONTEXT_LENGTH=32768 OLLAMA_MLX=1 \
        nohup ollama serve >> "${log_file}" 2>&1 &
    local ollama_pid=$!
    disown "${ollama_pid}" 2>/dev/null || true
    log_info "Started ollama serve (PID ${ollama_pid}), logs: ${log_file}"

    local max_wait=30 waited=0
    while [ $waited -lt $max_wait ]; do
        if curl -s --connect-timeout 2 "${OLLAMA_HOST}/api/tags" > /dev/null 2>&1; then
            log_info "Ollama is running"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    log_error "Ollama failed to start within ${max_wait}s. Check ${log_file}"
    return 1
}

check_docker() {
    log_info "Checking if Docker is running..."
    if ! docker info > /dev/null 2>&1; then
        log_error "Docker is not running. Please start Docker first."
        return 1
    fi
    log_info "Docker is running"
}

is_model_pulled() {
    local model="$1"
    local model_name="${model%%:*}"
    local model_tag="${model#*:}"
    [ "$model_tag" = "$model" ] && model_tag="latest"
    ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -q "^${model_name}:${model_tag}$"
}

is_model_loaded() {
    local model="$1"
    local response
    response=$(curl -s --connect-timeout 5 "${OLLAMA_HOST}/api/ps" 2>/dev/null)
    if [ -z "$response" ]; then
        return 1
    fi
    if [[ "$model" == *:* ]]; then
        echo "$response" | grep -q "\"name\":\"${model}\""
    else
        echo "$response" | grep -qE "\"name\":\"${model}(:[^\"]+)?\""
    fi
}

pull_model() {
    local model="$1"
    local max_retries=3 retry=0

    if is_model_pulled "${model}"; then
        log_info "Model ${model} is already pulled, skipping"
        return 0
    fi

    log_info "Pulling Ollama model: ${model}"
    while [ $retry -lt $max_retries ]; do
        if ollama pull "${model}"; then
            log_info "Successfully pulled ${model}"
            return 0
        fi
        retry=$((retry + 1))
        log_warn "Failed to pull ${model}, attempt ${retry}/${max_retries}"
        sleep 2
    done

    log_error "Failed to pull ${model} after ${max_retries} attempts"
    return 1
}

keep_model_loaded() {
    local model="$1" endpoint="$2" data="$3"

    if is_model_loaded "${model}"; then
        log_info "Model ${model} is already loaded in memory, skipping"
        return 0
    fi

    log_info "Loading ${model} into memory via /api/${endpoint}..."

    local response http_code
    response=$(curl -s -w "\n%{http_code}" --connect-timeout 10 --max-time 300 \
        "${OLLAMA_HOST}/api/${endpoint}" -d "${data}" 2>&1) || true
    http_code=$(echo "${response}" | tail -n1)
    local body
    body=$(echo "${response}" | sed '$d')

    if [ "${http_code}" != "200" ]; then
        log_warn "Failed to pre-load ${model} (HTTP ${http_code}): ${body}"
        return 1
    fi

    if is_model_loaded "${model}"; then
        log_info "${model} loaded successfully"
    else
        log_warn "${model} request succeeded but model is not showing as loaded"
    fi
}

unload_model() {
    local model="$1" endpoint="$2" data="$3"

    if is_model_loaded "${model}"; then
        log_info "Unloading ${model} from memory..."
        if curl -s --connect-timeout 10 --max-time 30 \
            "${OLLAMA_HOST}/api/${endpoint}" -d "${data}" > /dev/null 2>&1; then
            log_info "${model} unloaded successfully"
        else
            log_warn "Failed to unload ${model} gracefully"
        fi
    else
        log_info "${model} is not loaded, skipping"
    fi
}

unload_models() {
    if ! curl -s --connect-timeout 2 "${OLLAMA_HOST}/api/tags" > /dev/null 2>&1; then
        return 0
    fi
    unload_model "${LLM_MODEL}" "generate" "{\"model\": \"${LLM_MODEL}\", \"keep_alive\": 0}"
    if llm_mode_is_indexed; then
        unload_model "${EMBEDDING_MODEL}" "embed" \
            "{\"model\": \"${EMBEDDING_MODEL}\", \"input\": \"\", \"keep_alive\": 0}"
    fi
}

wait_for_qdrant() {
    log_info "Waiting for Qdrant to be ready..."
    local max_wait="${1:-30}" waited=0
    while [ $waited -lt $max_wait ]; do
        if curl -s --connect-timeout 2 "http://localhost:6333/readyz" > /dev/null 2>&1; then
            log_info "Qdrant is ready"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    log_warn "Qdrant did not become ready within ${max_wait}s"
    return 1
}

start_qdrant() {
    log_info "Setting up Qdrant..."

    if [ ! -d "${QDRANT_STORAGE}" ]; then
        log_info "Creating Qdrant storage directory: ${QDRANT_STORAGE}"
        mkdir -p "${QDRANT_STORAGE}"
    fi

    if docker ps -a --format '{{.Names}}' | grep -q "^${QDRANT_CONTAINER_NAME}$"; then
        if docker ps --format '{{.Names}}' | grep -q "^${QDRANT_CONTAINER_NAME}$"; then
            log_info "Qdrant container is already running"
        else
            log_info "Starting existing Qdrant container..."
            docker start "${QDRANT_CONTAINER_NAME}" > /dev/null
        fi
        wait_for_qdrant 30
        return 0
    fi

    log_info "Creating and starting new Qdrant container..."
    docker run -d \
        --name "${QDRANT_CONTAINER_NAME}" \
        -p 6333:6333 \
        -p 6334:6334 \
        -v "${QDRANT_STORAGE}:/qdrant/storage:z" \
        --restart unless-stopped \
        qdrant/qdrant > /dev/null

    wait_for_qdrant 30
}

stop_qdrant() {
    log_info "Stopping Qdrant..."

    if ! command -v docker &> /dev/null; then
        log_warn "Docker command not found, skipping Qdrant"
        return 0
    fi

    if ! docker info > /dev/null 2>&1; then
        log_warn "Docker is not running, skipping Qdrant"
        return 0
    fi

    if docker ps --format '{{.Names}}' | grep -q "^${QDRANT_CONTAINER_NAME}$"; then
        log_info "Stopping Qdrant container by name..."
        docker stop "${QDRANT_CONTAINER_NAME}"
        log_info "Qdrant container stopped"
        return 0
    fi

    local container_ids
    container_ids=$(docker ps -q --filter "ancestor=qdrant/qdrant" 2>/dev/null || true)
    if [ -n "$container_ids" ]; then
        log_info "Stopping Qdrant container(s) by image..."
        echo "$container_ids" | xargs docker stop
        log_info "Qdrant container(s) stopped"
    else
        log_info "No running Qdrant containers found"
    fi
}

stop_ollama() {
    log_info "Stopping Ollama..."
    unload_models
    sleep 1

    if pgrep -x "Ollama" > /dev/null 2>&1 || pgrep -x "ollama" > /dev/null 2>&1; then
        if killall Ollama 2>/dev/null || killall ollama 2>/dev/null; then
            log_info "Ollama process terminated"
        else
            log_warn "Could not terminate Ollama process"
        fi
    else
        log_info "Ollama is not running"
    fi
}

force_stop() {
    local keep_ollama="$1" keep_qdrant="$2"

    log_warn "Force mode enabled, skipping graceful shutdown"

    if [ "$keep_ollama" = false ]; then
        killall -9 Ollama 2>/dev/null || killall -9 ollama 2>/dev/null || true
        log_info "Ollama force killed"
    fi

    if llm_mode_is_indexed && [ "$keep_qdrant" = false ]; then
        docker kill "${QDRANT_CONTAINER_NAME}" 2>/dev/null || true
        local container_ids
        container_ids=$(docker ps -q --filter "ancestor=qdrant/qdrant" 2>/dev/null || true)
        if [ -n "$container_ids" ]; then
            echo "$container_ids" | xargs docker kill 2>/dev/null || true
        fi
        log_info "Qdrant force killed"
    elif ! llm_mode_is_indexed; then
        log_info "Plain profile: not touching Qdrant"
    fi
}

show_status() {
    echo ""
    echo "=== Environment Status (${LLM_MODE}) ==="
    echo ""
    echo "Chat model:       ${LLM_MODEL}"
    if llm_mode_is_indexed; then
        echo "Index model:      ${EMBEDDING_MODEL}"
    fi
    if [[ -n "${LOCAL_LLM_CONFIG_FILE}" ]]; then
        echo "Config file:      ${LOCAL_LLM_CONFIG_FILE}"
    fi
    echo ""

    echo -n "Ollama Server:    "
    if curl -s --connect-timeout 2 "${OLLAMA_HOST}/api/tags" > /dev/null 2>&1; then
        echo -e "${GREEN}Running${NC}"
    else
        echo -e "${RED}Not Running${NC}"
    fi

    echo -n "Model ${LLM_MODEL}:  "
    if is_model_pulled "${LLM_MODEL}"; then
        echo -e "${GREEN}Pulled${NC}"
    else
        echo -e "${YELLOW}Not Pulled${NC}"
    fi

    if llm_mode_is_indexed; then
        echo -n "Model ${EMBEDDING_MODEL}: "
        if is_model_pulled "${EMBEDDING_MODEL}"; then
            echo -e "${GREEN}Pulled${NC}"
        else
            echo -e "${YELLOW}Not Pulled${NC}"
        fi
    fi

    echo -n "${LLM_MODEL} loaded:  "
    if is_model_loaded "${LLM_MODEL}"; then
        echo -e "${GREEN}Yes${NC}"
    else
        echo -e "${YELLOW}No${NC}"
    fi

    if llm_mode_is_indexed; then
        echo -n "${EMBEDDING_MODEL} loaded: "
        if is_model_loaded "${EMBEDDING_MODEL}"; then
            echo -e "${GREEN}Yes${NC}"
        else
            echo -e "${YELLOW}No${NC}"
        fi

        echo -n "Docker:           "
        if docker info > /dev/null 2>&1; then
            echo -e "${GREEN}Running${NC}"
        else
            echo -e "${RED}Not Running${NC}"
        fi

        echo -n "Qdrant Container: "
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${QDRANT_CONTAINER_NAME}$"; then
            echo -e "${GREEN}Running${NC}"
        elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${QDRANT_CONTAINER_NAME}$"; then
            echo -e "${YELLOW}Stopped${NC}"
        else
            echo -e "${YELLOW}Not Created${NC}"
        fi

        echo -n "Qdrant API:       "
        if curl -s --connect-timeout 2 "http://localhost:6333/readyz" > /dev/null 2>&1; then
            echo -e "${GREEN}Ready${NC}"
        else
            echo -e "${YELLOW}Not Ready${NC}"
        fi
    fi

    echo ""
}

show_usage() {
    echo "Usage: $0 [profile] <command> [options]"
    echo "       $0 <command> [profile]         (profile may follow the command)"
    echo "       $0 <command>                   (default profile: indexed)"
    echo ""
    echo "Profiles:"
    echo "  indexed (vectored)     embedding + LLM + Qdrant — max 2 loaded models"
    echo "  plain (aider-vision)   LLM only, no vector index — max 1 loaded model"
    echo ""
    echo "Aliases:"
    echo "  vectored, roo          → indexed"
    echo "  aider, aider-vision, cursor → plain"
    echo ""
    echo "Environment: LLM_MODE (indexed|plain); ROO_AGENT is deprecated"
    echo ""
    echo "Commands:"
    echo "  start   Start services (default)"
    echo "  stop    Stop services"
    echo "  status  Show status"
    echo "  help    Show this help"
    echo ""
    echo "Stop options:"
    echo "  --keep-ollama    Unload models but leave Ollama running"
    echo "  --keep-qdrant    Do not stop Qdrant (indexed profile only)"
    echo "  --force          Force kill without graceful shutdown"
    echo ""
}

start_services() {
    log_info "Starting environment (${LLM_MODE})..."

    check_command ollama || exit 1
    check_command curl || exit 1
    if llm_mode_is_indexed; then
        check_command docker || exit 1
    fi

    check_ollama || exit 1

    if llm_mode_is_indexed; then
        check_docker || exit 1
        pull_model "${EMBEDDING_MODEL}" || exit 1
        pull_model "${LLM_MODEL}" || exit 1
        keep_model_loaded "${LLM_MODEL}" "generate" \
            "{\"model\": \"${LLM_MODEL}\", \"keep_alive\": -1}"
        keep_model_loaded "${EMBEDDING_MODEL}" "embed" \
            "{\"model\": \"${EMBEDDING_MODEL}\", \"input\": \"initial load\", \"keep_alive\": -1}"
        start_qdrant || exit 1
    else
        pull_model "${LLM_MODEL}" || exit 1
        keep_model_loaded "${LLM_MODEL}" "generate" \
            "{\"model\": \"${LLM_MODEL}\", \"keep_alive\": -1}"
    fi

    log_info "Setup complete (${LLM_MODE})!"
    echo ""
    show_status
}

stop_services() {
    local keep_ollama=false keep_qdrant=false force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep-ollama) keep_ollama=true; shift ;;
            --keep-qdrant) keep_qdrant=true; shift ;;
            --force)       force=true; shift ;;
            *)
                log_error "Unknown stop option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    log_info "Stopping environment (${LLM_MODE})..."

    if [ "$force" = true ]; then
        force_stop "$keep_ollama" "$keep_qdrant"
    else
        if [ "$keep_ollama" = false ]; then
            stop_ollama
        else
            log_info "Keeping Ollama running (--keep-ollama)"
            unload_models
        fi

        if llm_mode_is_indexed && [ "$keep_qdrant" = false ]; then
            stop_qdrant
        elif llm_mode_is_indexed && [ "$keep_qdrant" = true ]; then
            log_info "Keeping Qdrant running (--keep-qdrant)"
        else
            log_info "Plain profile: leaving Qdrant unchanged"
        fi
    fi

    log_info "Shutdown complete (${LLM_MODE})"
}

is_profile_arg() {
    case "$1" in
        indexed|vectored|roo|plain|aider|aider-vision|cursor) return 0 ;;
        *) return 1 ;;
    esac
}

main() {
    local args=("$@")

    local filtered=() profile_seen=false resolved
    for arg in "${args[@]}"; do
        if is_profile_arg "$arg"; then
            if [[ "$profile_seen" == true ]]; then
                log_error "Specify only one profile"
                show_usage
                exit 1
            fi
            resolved=$(resolve_llm_mode "$arg") || exit 1
            LLM_MODE="${resolved}"
            profile_seen=true
        else
            filtered+=("$arg")
        fi
    done
    args=("${filtered[@]}")

    normalize_llm_mode || exit 1

    local command="${args[0]:-start}"
    local rest=()
    if ((${#args[@]} > 0)); then
        rest=("${args[@]:1}")
    fi

    case "$command" in
        start)
            start_services
            ;;
        stop)
            stop_services ${rest[@]+"${rest[@]}"}
            ;;
        status)
            show_status
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"

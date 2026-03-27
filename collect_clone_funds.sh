#!/bin/bash

# ============================================
# COLLECT CLONE FUNDS - REPUBLIC AI
# Chuyen so du tu cac vi clone dele_* ve vi dich trong config.json
# ============================================

# --- Cau hinh he thong ---
REPUBLIC_HOME="${REPUBLIC_HOME:=$HOME/.republicd}"
BINARY_PATH="${BINARY_PATH:=/usr/local/bin/republicd}"
CHAIN_ID="${CHAIN_ID:=raitestnet_77701-1}"
KEYRING_BACKEND="${KEYRING_BACKEND:=test}"

# --- Cau hinh chuyen tien ---
CONFIG_FILE="config.json"
MIN_BALANCE=0.02
RESERVE_AMOUNT=0.01
GAS_LIMIT=120000
FEES="5000000000000000arai"
SLEEP_SECONDS=3
DRY_RUN=0

# --- Mau sac ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Ham tien ich ---
msg() { echo -e "${GREEN}[*] $(date '+%Y-%m-%d %H:%M:%S')${NC} $1"; }
err() { echo -e "${RED}[!] $(date '+%Y-%m-%d %H:%M:%S')${NC} $1"; }
warn() { echo -e "${YELLOW}[!] $(date '+%Y-%m-%d %H:%M:%S')${NC} $1"; }
info() { echo -e "${BLUE}[i] $(date '+%Y-%m-%d %H:%M:%S')${NC} $1"; }

check_dependencies() {
    local deps=("jq" "bc" "republicd")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            err "Thieu dependency: $cmd"
            exit 1
        fi
    done
    msg "Da kiem tra dependency xong"
}

check_config_file() {
    if [ ! -f "$CONFIG_FILE" ]; then
        err "Khong tim thay file cau hinh: $CONFIG_FILE"
        exit 1
    fi

    if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        err "File $CONFIG_FILE khong hop le"
        exit 1
    fi

    msg "File cau hinh hop le"
}

get_destination_wallet_name() {
    jq -r '.wallet.name // empty' "$CONFIG_FILE"
}

get_destination_address() {
    jq -r '.wallet.address // empty' "$CONFIG_FILE"
}

get_clone_wallets() {
    jq -r '
        (
            [(.validators // [])[] | (.delegators // [])[]] +
            (.wallet.transfer_keys // [])
        )
        | unique[]
        | select(test("^dele_"))
    ' "$CONFIG_FILE"
}

get_wallet_address() {
    local wallet_name=$1
    republicd keys show "$wallet_name" \
        -a \
        --keyring-backend "$KEYRING_BACKEND" \
        --home "$REPUBLIC_HOME" 2>/dev/null
}

get_balance_arai() {
    local addr=$1
    local bal_arai
    bal_arai=$(republicd query bank balances "$addr" \
        --home "$REPUBLIC_HOME" \
        --output json 2>/dev/null | \
        jq -r '[.balances[]? | select(.denom=="arai") | .amount][0] // "0"')

    if [ -z "$bal_arai" ] || [ "$bal_arai" = "null" ]; then
        echo "0"
        return 0
    fi

    echo "$bal_arai"
}

arai_to_rai() {
    local amount_arai=$1
    echo "scale=18; $amount_arai / 1000000000000000000" | bc
}

rai_to_arai() {
    local amount_rai=$1
    echo "$amount_rai * 1000000000000000000 / 1" | bc -l | xargs printf "%.0f"
}

send_tx() {
    local from_wallet=$1
    local to_address=$2
    local amount_arai=$3
    local output
    local tx_rc

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY-RUN] republicd tx bank send $from_wallet $to_address ${amount_arai}arai"
        return 0
    fi

    output=$(republicd tx bank send "$from_wallet" "$to_address" "${amount_arai}arai" \
        --from "$from_wallet" \
        --chain-id "$CHAIN_ID" \
        --gas "$GAS_LIMIT" \
        --fees "$FEES" \
        --keyring-backend "$KEYRING_BACKEND" \
        --home "$REPUBLIC_HOME" \
        -y 2>&1)
    tx_rc=$?

    if [ -n "$output" ]; then
        echo "$output" | grep -E "code|txhash|raw_log|error" || echo "$output"
    fi

    return $tx_rc
}

usage() {
    echo "Cach su dung:"
    echo "  $0 [--dry-run]"
    echo ""
    echo "Mo ta:"
    echo "  Script se doc config.json, lay toan bo key dele_* duoc cau hinh,"
    echo "  sau do chuyen so du kha dung ve wallet.address."
    echo ""
    echo "Tuy chon:"
    echo "  --dry-run    Chi in lenh, khong gui giao dich"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                err "Tham so khong hop le: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"

    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}COLLECT CLONE FUNDS - REPUBLIC AI${NC}"
    echo -e "${BLUE}========================================${NC}\n"

    check_dependencies
    check_config_file

    local destination_wallet_name destination_address clone_wallets clone_count
    destination_wallet_name=$(get_destination_wallet_name)
    destination_address=$(get_destination_address)

    if [ -z "$destination_address" ] || [ "$destination_address" = "null" ]; then
        err "Khong tim thay wallet.address trong $CONFIG_FILE"
        exit 1
    fi

    clone_wallets=$(get_clone_wallets)
    clone_count=$(echo "$clone_wallets" | sed '/^$/d' | wc -l)

    if [ "$clone_count" -eq 0 ]; then
        warn "Khong tim thay vi clone nao co tien to dele_ trong config"
        exit 0
    fi

    info "Vi dich: ${destination_wallet_name:-N/A} | $destination_address"
    info "Tong so vi clone trong config: $clone_count"
    info "MIN_BALANCE=$MIN_BALANCE RAI | RESERVE_AMOUNT=$RESERVE_AMOUNT RAI"

    local success_count=0
    local skip_count=0
    local fail_count=0
    local total_sent_arai=0

    while IFS= read -r clone_wallet; do
        [ -z "$clone_wallet" ] && continue

        local clone_address balance_arai balance_rai transferable_rai transferable_arai
        clone_address=$(get_wallet_address "$clone_wallet")

        if [ -z "$clone_address" ]; then
            warn "Khong tim thay key '$clone_wallet'. Bo qua."
            ((skip_count++))
            continue
        fi

        if [ "$clone_address" = "$destination_address" ]; then
            warn "Vi '$clone_wallet' trung voi vi dich. Bo qua."
            ((skip_count++))
            continue
        fi

        balance_arai=$(get_balance_arai "$clone_address")
        balance_rai=$(arai_to_rai "$balance_arai")
        info "Vi: $clone_wallet | Address: $clone_address | Balance: $balance_rai RAI"

        if (( $(echo "$balance_rai <= $MIN_BALANCE" | bc -l) )); then
            info "Bo qua do balance <= $MIN_BALANCE RAI"
            ((skip_count++))
            continue
        fi

        transferable_rai=$(echo "$balance_rai - $RESERVE_AMOUNT" | bc -l)
        if (( $(echo "$transferable_rai <= 0" | bc -l) )); then
            info "Bo qua do khong du so du sau khi tru reserve"
            ((skip_count++))
            continue
        fi

        transferable_arai=$(rai_to_arai "$transferable_rai")
        msg "Chuyen tu '$clone_wallet' ve '$destination_address': $transferable_rai RAI"

        if send_tx "$clone_wallet" "$destination_address" "$transferable_arai"; then
            ((success_count++))
            total_sent_arai=$((total_sent_arai + transferable_arai))
        else
            err "Gui giao dich that bai cho vi '$clone_wallet'"
            ((fail_count++))
        fi

        sleep "$SLEEP_SECONDS"
    done <<< "$clone_wallets"

    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}TONG KET${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "Thanh cong:       ${GREEN}$success_count${NC}"
    echo -e "Bo qua:           ${YELLOW}$skip_count${NC}"
    echo -e "That bai:         ${RED}$fail_count${NC}"
    echo -e "Tong da chuyen:   ${GREEN}$(arai_to_rai "$total_sent_arai")${NC} RAI"
    echo -e "${BLUE}========================================${NC}\n"
}

main "$@"

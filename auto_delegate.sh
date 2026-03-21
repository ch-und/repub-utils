#!/bin/bash

# ============================================
# AUTO DELEGATE SCRIPT - REPUBLIC AI
# Delegate các ví phụ có số dư > 0.3 RAI
# ============================================

# --- Cấu hình hệ thống (từ republic-mgr.sh) ---
REPUBLIC_HOME="${REPUBLIC_HOME:=$HOME/.republicd}"
BINARY_PATH="${BINARY_PATH:=/usr/local/bin/republicd}"
CHAIN_ID="${CHAIN_ID:=raitestnet_77701-1}"
KEYRING_BACKEND="${KEYRING_BACKEND:=test}"
RPC_PUBLIC="${RPC_PUBLIC:=https://rpc.republicai.io:443}"

# --- Cấu hình Delegate ---
CONFIG_FILE="config.json"                  # File cấu hình validator
MIN_BALANCE=0.3                            # Số dư tối thiểu để delegate (RAI)
RESERVE_AMOUNT=0.005                        # Giữ lại (RAI) - để tránh balance = 0
GAS_LIMIT=300000
FEES="5000000000000000arai"

# --- Màu sắc ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Hàm tiện ích ---
msg() { echo -e "${GREEN}[*] $(date '+%Y-%m-%d %H:%M:%S')${NC} $1"; }
err() { echo -e "${RED}[!] $(date '+%Y-%m-%d %H:%M:%S')${NC} $1"; }
warn() { echo -e "${YELLOW}[!] $(date '+%Y-%m-%d %H:%M:%S')${NC} $1"; }
info() { echo -e "${BLUE}[i] $(date '+%Y-%m-%d %H:%M:%S')${NC} $1"; }

# --- Kiểm tra Dependencies ---
check_dependencies() {
    local deps=("jq" "bc" "republicd")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            err "Thiếu dependency: $cmd"
            exit 1
        fi
    done
    msg "Các dependency đã được check ✓"
}

# --- Kiểm tra Config File ---
check_config_file() {
    if [ ! -f "$CONFIG_FILE" ]; then
        err "File cấu hình không tìm thấy: $CONFIG_FILE"
        exit 1
    fi
    
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        err "File $CONFIG_FILE không hợp lệ (JSON syntax error)"
        exit 1
    fi
    
    msg "File cấu hình hợp lệ ✓"
}

# --- Lấy Validator Address từ Config ---
get_validator_address() {
    local index=$1
    local val_addr=$(jq -r ".validators[$index].address" "$CONFIG_FILE" 2>/dev/null)
    
    if [ -z "$val_addr" ] || [ "$val_addr" == "null" ]; then
        err "Không thể lấy validator address từ index $index"
        return 1
    fi
    
    echo "$val_addr"
}

# --- Lấy tổng số validators ---
get_validator_count() {
    jq -r ".validators | length" "$CONFIG_FILE" 2>/dev/null
}

# --- Lấy tên validator ---
get_validator_name() {
    local index=$1
    jq -r ".validators[$index].name" "$CONFIG_FILE"
}

# --- Lấy danh sách Delegators từ Config ---
get_delegators() {
    local index=$1
    jq -r ".validators[$index].delegators[]" "$CONFIG_FILE" 2>/dev/null
}

# --- Lấy Balance của một địa chỉ ---
get_balance() {
    local addr=$1
    local bal_arai=$(republicd query bank balances "$addr" \
        --node "$RPC_PUBLIC" \
        --output json 2>/dev/null | \
        jq -r '.balances[] | select(.denom=="arai") | .amount')
    
    if [ -z "$bal_arai" ] || [ "$bal_arai" == "null" ]; then
        echo "0"
        return 0
    fi
    
    echo "scale=18; $bal_arai / 1000000000000000000" | bc
}

# --- Lấy Validator Address từ Wallet ---
get_validator_addr_from_wallet() {
    local wallet_name=$1
    republicd keys show "$wallet_name" \
        --bech val -a \
        --keyring-backend "$KEYRING_BACKEND" \
        --home "$REPUBLIC_HOME" 2>/dev/null
}

# --- Lấy Address từ Wallet ---
get_wallet_address() {
    local wallet_name=$1
    republicd keys show "$wallet_name" \
        -a \
        --keyring-backend "$KEYRING_BACKEND" \
        --home "$REPUBLIC_HOME" 2>/dev/null
}

# --- Thực hiện Delegate Giao dịch ---
delegate_tx() {
    local wallet_name=$1
    local validator_addr=$2
    local amount_arai=$3
    
    msg "Đang gửi giao dịch delegate từ ví '$wallet_name'..."
    info "Validator: $validator_addr | Amount: $amount_arai arai"
    
    republicd tx staking delegate "$validator_addr" "${amount_arai}arai" \
        --from "$wallet_name" \
        --chain-id "$CHAIN_ID" \
        --gas "$GAS_LIMIT" \
        --fees "$FEES" \
        --node "$RPC_PUBLIC" \
        --keyring-backend "$KEYRING_BACKEND" \
        --home "$REPUBLIC_HOME" \
        -y 2>&1 | grep -E "code|txhash|error" || msg "Giao dịch được gửi"
}

# --- Main Logic ---
main() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}AUTO DELEGATE - REPUBLIC AI${NC}"
    echo -e "${BLUE}(Tất cả Validators)${NC}"
    echo -e "${BLUE}========================================${NC}\n"
    
    # 1. Kiểm tra dependencies
    check_dependencies
    
    # 2. Kiểm tra config file
    check_config_file
    
    # 3. Lấy tổng số validators
    msg "Đang lấy thông tin validators từ config..."
    TOTAL_VALIDATORS=$(get_validator_count)
    info "Tổng số validators: $TOTAL_VALIDATORS\n"
    
    # 4. Biến tracking cho tất cả validators
    GRAND_TOTAL_DELEGATED=0
    GRAND_SUCCESS_COUNT=0
    GRAND_SKIP_COUNT=0
    
    # 5. Loop qua từng validator
    for ((val_idx=0; val_idx<TOTAL_VALIDATORS; val_idx++)); do
        # Lấy Validator Address từ Config
        VALIDATOR_ADDR=$(get_validator_address "$val_idx")
        if [ $? -ne 0 ]; then
            continue
        fi
        
        VALIDATOR_NAME=$(get_validator_name "$val_idx")
        
        echo -e "\n${BLUE}--- VALIDATOR $((val_idx+1))/$TOTAL_VALIDATORS ---${NC}"
        info "Name: $VALIDATOR_NAME"
        info "Address: $VALIDATOR_ADDR\n"
        
        # Lấy danh sách Delegators
        msg "Đang lấy danh sách delegators..."
        DELEGATORS=$(get_delegators "$val_idx")
        DELEGATOR_COUNT=$(echo "$DELEGATORS" | wc -l)
        info "Tổng số delegators: $DELEGATOR_COUNT\n"
        
        # Biến tracking cho validator này
        VALIDATOR_DELEGATED=0
        SUCCESS_COUNT=0
        SKIP_COUNT=0
        
        echo -e "${YELLOW}--- BẮT ĐẦU DELEGATE ---${NC}\n"
        
        # Duyệt qua từng delegator
        while IFS= read -r delegator_name; do
            # Lấy address của delegator
            delegator_addr=$(get_wallet_address "$delegator_name")
            if [ -z "$delegator_addr" ]; then
                warn "Ví '$delegator_name' không tìm thấy. Bỏ qua."
                ((SKIP_COUNT++))
                continue
            fi
            
            # Lấy balance
            balance=$(get_balance "$delegator_addr")
            info "Ví: $delegator_name | Balance: $balance RAI"
            
            # Kiểm tra nếu có đủ balance để delegate
            if (( $(echo "$balance > $MIN_BALANCE" | bc -l) )); then
                # Tính số RAI cần delegate (trừ đi reserve amount)
                stake_rai=$(echo "$balance - $RESERVE_AMOUNT" | bc -l)
                # Chuyển đổi sang arai
                stake_arai=$(echo "$stake_rai * 1000000000000000000 / 1" | bc -l | xargs printf "%.0f")
                
                # Gửi giao dịch
                delegate_tx "$delegator_name" "$VALIDATOR_ADDR" "$stake_arai"
                
                ((SUCCESS_COUNT++))
                VALIDATOR_DELEGATED=$(echo "$VALIDATOR_DELEGATED + $stake_rai" | bc -l)
                
                # Chờ một chút trước khi delegate ví tiếp theo
                sleep 3
            else
                info "Bỏ qua (balance <= $MIN_BALANCE RAI)\n"
                ((SKIP_COUNT++))
            fi
        done <<< "$DELEGATORS"
        
        # Tóm tắt cho validator này
        echo -e "\n${YELLOW}--- KẾT QUẢ VALIDATOR $VALIDATOR_NAME ---${NC}"
        echo -e "Tổng delegators:    $DELEGATOR_COUNT"
        echo -e "Thành công:         ${GREEN}$SUCCESS_COUNT${NC}"
        echo -e "Bỏ qua:             ${YELLOW}$SKIP_COUNT${NC}"
        echo -e "Tổng RAI delegate:  ${GREEN}$VALIDATOR_DELEGATED${NC} RAI\n"
        
        # Cộng vào tổng chung
        GRAND_SUCCESS_COUNT=$((GRAND_SUCCESS_COUNT + SUCCESS_COUNT))
        GRAND_SKIP_COUNT=$((GRAND_SKIP_COUNT + SKIP_COUNT))
        GRAND_TOTAL_DELEGATED=$(echo "$GRAND_TOTAL_DELEGATED + $VALIDATOR_DELEGATED" | bc -l)
    done
    
    # 6. Tóm tắt cuối cùng cho tất cả validators
    echo -e "\n${BLUE}===========================================${NC}"
    echo -e "${BLUE}--- TỔNG KẾT CUỐI CÙNG (TẤT CẢ VALIDATORS) ---${NC}"
    echo -e "${BLUE}===========================================${NC}"
    echo -e "Tổng validators:    $TOTAL_VALIDATORS"
    echo -e "Tổng giao dịch:     ${GREEN}$GRAND_SUCCESS_COUNT${NC}"
    echo -e "Tổng bỏ qua:        ${YELLOW}$GRAND_SKIP_COUNT${NC}"
    echo -e "Tổng RAI delegate:  ${GREEN}$GRAND_TOTAL_DELEGATED${NC} RAI"
    echo -e "${BLUE}==========================================\n${NC}"
    
    if [ $GRAND_SUCCESS_COUNT -gt 0 ]; then
        msg "Hoàn tất! $GRAND_SUCCESS_COUNT giao dịch đã được gửi cho tất cả validators."
    else
        warn "Không có ví nào đủ điều kiện để delegate."
    fi
}

# --- Usage Info ---
usage() {
    echo "Cách sử dụng:"
    echo "  $0"
    echo ""
    echo "Giải thích:"
    echo "  Script sẽ tự động delegate cho TẤT CẢ validators trong config.json"
    echo "  Không cần nhập tham số."
    echo ""
    echo "Yêu cầu:"
    echo "  - File config.json phải tồn tại trong thư mục hiện tại"
    echo "  - Các ví delegators phải được import vào REPUBLIC_HOME"
    echo "  - Có quyền chạy republicd commands"
}

# --- Entry Point ---
if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    usage
    exit 0
fi

main

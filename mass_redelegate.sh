#!/bin/bash

# Cấu hình môi trường
CHAIN_ID="raitestnet_77701-1"
REPUBLIC_HOME="$HOME/.republicd"
KEYRING_BACKEND="test"
GAS_LIMIT="300000"
FEES="5000000000000000arai"
CONFIG_FILE="config.json"
MIN_STAKE_THRESHOLD=1000000 # Ngưỡng tối thiểu (ví dụ 1 token) để thực hiện redelegate

# Kiểm tra file config
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: File $CONFIG_FILE không tồn tại."
    exit 1
fi

echo "--- Bắt đầu quá trình Redelegate ---"

# Duyệt qua từng validator đích trong file config
jq -c '.validators[]' "$CONFIG_FILE" | while read -r val_entry; do
    dst_val_addr=$(echo "$val_entry" | jq -r '.address')
    dst_val_name=$(echo "$val_entry" | jq -r '.name')
    
    echo ">>> Mục tiêu: $dst_val_name ($dst_val_addr)"

    # Duyệt qua danh sách các delegator của validator đó
    echo "$val_entry" | jq -r '.delegators[]' | while read -r dele_key; do
        
        # 1. Lấy địa chỉ ví từ key name
        wallet_addr=$(republicd keys show "$dele_key" -a --keyring-backend "$KEYRING_BACKEND" --home "$REPUBLIC_HOME" 2>/dev/null)
        
        if [ -z "$wallet_addr" ]; then
            echo "[Skip] Không tìm thấy địa chỉ cho key: $dele_key"
            continue
        fi

        # 2. Quét tất cả các nguồn đang delegate của ví này
        republicd query staking delegations "$wallet_addr" --home "$REPUBLIC_HOME" --output json 2>/dev/null | jq -c '.delegation_responses[]' | while read -r delegation; do
            src_val_addr=$(echo "$delegation" | jq -r '.delegation.validator_address')
            staked_amount=$(echo "$delegation" | jq -r '.balance.amount')

            # KIỂM TRA ĐIỀU KIỆN LỌC
            # - Lọc bỏ nếu validator nguồn chính là validator đích
            if [ "$src_val_addr" == "$dst_val_addr" ]; then
                continue
            fi

            # - Lọc bỏ nếu số lượng stake quá nhỏ (tránh rác giao dịch)
            if [ "$staked_amount" -lt "$MIN_STAKE_THRESHOLD" ]; then
                echo "[Skip] Ví $dele_key tại $src_val_addr có stake quá thấp ($staked_amount)."
                continue
            fi

            # 3. Thực hiện lệnh Redelegate
            echo "[Exec] Ví $dele_key: Redelegate $staked_amount arai từ $src_val_addr -> $dst_val_addr"
            
            republicd tx staking redelegate "$src_val_addr" "$dst_val_addr" "${staked_amount}arai" \
                --from "$dele_key" \
                --chain-id "$CHAIN_ID" \
                --gas "$GAS_LIMIT" \
                --fees "$FEES" \
                --keyring-backend "$KEYRING_BACKEND" \
                --home "$REPUBLIC_HOME" \
                -y | grep -E "txhash|code"
            
            # Nghỉ ngắn để tránh spam mempool quá nhanh
            sleep 5
        done
    done
done

echo "--- Hoàn thành ---"
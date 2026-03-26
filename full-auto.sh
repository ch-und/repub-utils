#!/bin/bash

VALOPER="raivaloper1rw4x7l8k0aec30wr2aqp6wn46c5ejtwx3xcky8"
WALLET="rai1rw4x7l8k0aec30wr2aqp6wn46c5ejtwxknct03"
NODE="http://95.111.254.170:26657"
CHAIN_ID="raitestnet_77701-1"
SERVER_IP="95.111.254.170"
JOBS_DIR="/var/lib/republic/jobs"
PASSWORD="YOUR_KEYRING_PASSWORD"
JOB_FEE="5000000000000000arai"

echo "🚀 Full Auto started..."

while true; do
  echo "📤 Submitting new job..."
  TX=$(republicd tx computevalidation submit-job \
    $VALOPER \
    republic-llm-inference:latest \
    http://$SERVER_IP:8080/upload \
    http://$SERVER_IP:8080/result \
    example-verification:latest \
    $JOB_FEE \
    --from wallet \
    --keyring-backend test \
    --home $HOME/.republicd \
    --chain-id $CHAIN_ID \
    --gas auto \
    --gas-adjustment 1.5 \
    --gas-prices 1000000000arai \
    --node $NODE \
    -y 2>/dev/null | grep txhash | awk '{print $2}')
  echo "✅ TX: $TX"
  sleep 15
  JOB_ID=$(republicd query tx $TX --node $NODE -o json 2>/dev/null | \
    jq -r '.events[] | select(.type=="job_submitted") | .attributes[] | select(.key=="job_id") | .value')
  echo "📋 Job ID: $JOB_ID"
  if [ -z "$JOB_ID" ]; then
    echo "❌ Job ID not found, skipping..."
    sleep 30
    continue
  fi
  RESULT_FILE="$JOBS_DIR/$JOB_ID/result.bin"
  echo "⚙️  Processing job $JOB_ID..."
  mkdir -p $JOBS_DIR/$JOB_ID
  timeout 60 docker run --rm --gpus all \
    -v $JOBS_DIR/$JOB_ID:/output \
    republic-llm-inference:latest 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "❌ Docker timeout or error for job $JOB_ID, skipping..."
    sleep 30
    continue
  fi
  echo "✅ Inference done for job $JOB_ID"
  if [ -f "$RESULT_FILE" ]; then
    echo "📤 Submitting result for job $JOB_ID..."
    SHA256=$(sha256sum $RESULT_FILE | awk '{print $1}')
    republicd tx computevalidation submit-job-result \
      $JOB_ID \
      http://$SERVER_IP:8080/$JOB_ID/result.bin \
      example-verification:latest \
      $SHA256 \
      --from wallet \
      --keyring-backend test \
      --home $HOME/.republicd \
      --chain-id $CHAIN_ID \
      --gas 300000 \
      --gas-prices 1000000000arai \
      --node $NODE \
      --generate-only 2>/dev/null > /tmp/tx_unsigned.json
    python3 -c "
import bech32, json
tx = json.load(open('/tmp/tx_unsigned.json'))
_, data = bech32.bech32_decode('$WALLET')
valoper = bech32.bech32_encode('raivaloper', data)
tx['body']['messages'][0]['validator'] = valoper
json.dump(tx, open('/tmp/tx_unsigned.json', 'w'))
"
    republicd tx sign /tmp/tx_unsigned.json \
      --from wallet \
      --keyring-backend test \
      --home $HOME/.republicd \
      --chain-id $CHAIN_ID \
      --node $NODE \
      --output-document /tmp/tx_signed.json 2>/dev/null
    republicd tx broadcast /tmp/tx_signed.json \
      --node $NODE \
      --chain-id $CHAIN_ID 2>/dev/null | grep txhash | \
      awk '{print "🎉 Job '$JOB_ID' result submitted! TX: "$2}'
    sleep 15
  fi
  echo "⏳ Waiting 30 seconds..."
  sleep 30
done

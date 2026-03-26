#!/bin/bash

echo "👀 Watchdog started..."

while true; do
  if ! pgrep -f "full-auto.sh" > /dev/null; then
    echo "⚠️  full-auto.sh stopped! Restarting..."
    nohup /root/full-auto.sh >> /root/full-auto.log 2>&1 &
    echo "✅ Restarted! PID: $!"
  fi
  sleep 30
done
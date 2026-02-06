#!/bin/bash
# Watch for epoch finalization in real-time

LOG_FILE="${LOG_FILE:-$HOME/oak-chain/logs/validator-0.log}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Watching Epoch Finalization (Ctrl+C to stop)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Expected timeline:"
echo "  - Proposals queued in epoch: $(grep -o "epoch: [0-9]*" $LOG_FILE | tail -1 | awk '{print $2}')"
echo "  - Will finalize after 2 Ethereum epochs (~12.8 minutes)"
echo ""
echo "Monitoring for:"
echo "  🔍 Epoch finalization checks"
echo "  ✅ Finalized epoch events"
echo "  📦 Batch creation"
echo "  ⚡ Messages sent to Aeron"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Start time
START_TIME=$(date +%s)

# Watch the log file for relevant events
tail -f "$LOG_FILE" | while read line; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    TIMESTAMP=$(date '+%H:%M:%S')
    
    # Epoch finalization check
    if echo "$line" | grep -q "Epoch finalization check"; then
        echo "[$TIMESTAMP +${ELAPSED}s] 🔍 $(echo "$line" | grep -o "Epoch finalization check.*")"
    fi
    
    # Finalized epoch events
    if echo "$line" | grep -q "Finalized epoch"; then
        echo "[$TIMESTAMP +${ELAPSED}s] ✅ $(echo "$line" | grep -o "Finalized epoch.*")"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
    
    # Batch queued
    if echo "$line" | grep -q "Batch from epoch"; then
        echo "[$TIMESTAMP +${ELAPSED}s] 📦 $(echo "$line" | grep -o "Batch from epoch.*")"
    fi
    
    # Messages replicated
    if echo "$line" | grep -q "onSessionMessage"; then
        echo "[$TIMESTAMP +${ELAPSED}s] ⚡ Message replicated to SegmentStore"
    fi
    
    # Backpressure events
    if echo "$line" | grep -q "Applying backpressure"; then
        echo "[$TIMESTAMP +${ELAPSED}s] ⚠️  $(echo "$line" | grep -o "Applying backpressure.*")"
    fi
    
    if echo "$line" | grep -q "Releasing backpressure"; then
        echo "[$TIMESTAMP +${ELAPSED}s] ✅ $(echo "$line" | grep -o "Releasing backpressure.*")"
    fi
done


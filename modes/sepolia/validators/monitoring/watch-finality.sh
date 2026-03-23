#!/bin/bash
# Simple finality event watcher

LOG_FILE="${LOG_FILE:-$HOME/oak-chain/logs/validator-0.log}"

echo ""
echo "👀 Watching for Epoch 408412 Finalization..."
echo "   Press Ctrl+C to stop"
echo ""

tail -f "$LOG_FILE" | while read line; do
    if echo "$line" | grep -q "Finalized epoch 408412"; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🎉 EPOCH 408412 FINALIZED!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "$line"
        echo ""
        echo "✅ Next: Watch for batches being sent to Aeron..."
        echo ""
    fi
    
    if echo "$line" | grep -q "Batch from epoch 408412"; then
        echo "📦 $(echo "$line" | grep -o 'Batch from epoch.*')"
    fi
    
    if echo "$line" | grep -q "onSessionMessage" && echo "$line" | grep -q "DEBUG"; then
        echo "⚡ Message replicated to SegmentStore"
    fi
done


#!/bin/bash
#
# Quick fix: Kill whatever is using port 3000
#

echo "🔍 Checking port 3000..."
PORT_PID=$(lsof -ti :3000 2>/dev/null)

if [ -z "$PORT_PID" ]; then
    echo "✅ Port 3000 is free"
    exit 0
fi

echo "🛑 Port 3000 is in use by PID: $PORT_PID"
ps -p $PORT_PID -o pid,ppid,comm,args

echo ""
echo "Killing process..."
kill -9 $PORT_PID 2>/dev/null || true

sleep 1

# Verify
PORT_PID=$(lsof -ti :3000 2>/dev/null)
if [ -z "$PORT_PID" ]; then
    echo "✅ Port 3000 is now free"
else
    echo "⚠️  Port 3000 still in use (PID: $PORT_PID)"
    echo "   Try: sudo kill -9 $PORT_PID"
fi

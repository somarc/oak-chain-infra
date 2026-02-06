#!/bin/bash
set -e

LOG_DIR="${LOG_DIR:-$HOME/oak-chain/logs}"
OUT_DIR="${OUT_DIR:-$LOG_DIR}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUT_FILE="${OUT_DIR}/validator-log-watch-${TIMESTAMP}.log"

# Default patterns: errors + consensus rejections
INCLUDE_REGEX="${INCLUDE_REGEX:-ERROR|WARN|Exception|Rejecting proposal|CRITICAL}"

mkdir -p "$OUT_DIR"

log() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$OUT_FILE"
}

log "Validator log watch"
log "Log dir: ${LOG_DIR}"
log "Output: ${OUT_FILE}"
log "Filter: ${INCLUDE_REGEX}"
log "Files: ${LOG_DIR}/validator-[0-9]*.log"

# Tail logs and flag interesting lines with timestamps.
tail -F -v "${LOG_DIR}"/validator-[0-9]*.log 2>/dev/null | \
  while IFS= read -r line; do
    if [[ "$line" == "==>"*"<=="* ]]; then
      file=$(echo "$line" | awk '{print $2}')
      continue
    fi
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$file] $line"
  done | \
  grep -E -u "${INCLUDE_REGEX}" | \
  tee -a "$OUT_FILE"

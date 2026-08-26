#!/bin/bash
# Detached in-pod orchestration: copy each new navhard scene's nuPlan db to local
# disk, then build its 10Hz NCore store via convert_nuplan10hz.py (/root/nuplan-conv).
# Log lands on the persistent PVC so it survives kubectl-exec disconnects.
set -u
DST=/tmp/nuplan_local/nuplan-v1.1/splits/test
SRC=/avl-west/nuplan/nuplan-v1.1/splits/test
mkdir -p "$DST"
LOG=/avl-west/r2s_work/_batch_convert10hz.log
: > "$LOG"

scenes=(
  "477045d84aa75534 2021.05.25.14.16.10_veh-35_00083_00485 1621966731500650 1621966751000721"
  "f2eae903542c56d3 2021.05.25.14.16.10_veh-35_01690_02183 1621968331500525 1621968351000267"
  "7c56367f5b9b55a0 2021.05.25.14.16.10_veh-35_02482_02649 1621969131501024 1621969151000144"
)

for s in "${scenes[@]}"; do
  set -- $s; TOK=$1; LOGN=$2; T0=$3; T1=$4
  echo "=== $(date -u +%H:%M:%S) copy db $LOGN ===" >> "$LOG"
  cp -n "$SRC/$LOGN.db" "$DST/" >> "$LOG" 2>&1
  echo "=== $(date -u +%H:%M:%S) convert $TOK ($LOGN) ===" >> "$LOG"
  PYTHONPATH=/hugsim-storage/NexusSim /root/nuplan-conv/bin/python \
    /tmp/convert_nuplan10hz.py "$TOK" "$LOGN" "$T0" "$T1" >> "$LOG" 2>&1
  echo "=== $(date -u +%H:%M:%S) done $TOK rc=$? ===" >> "$LOG"
done
echo "ALL_CONVERSIONS_DONE $(date -u +%H:%M:%S)" >> "$LOG"

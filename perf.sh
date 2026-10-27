#!/bin/bash
# Measures Tenfold for 60 s (every 5 s): CPU %, memory, threads, open files, helper processes.
# Usage: ./perf.sh [label]   → writes perf-<label>.log next to this script (e.g. idle, music, open).
cd "$(dirname "$0")"
PID=$(pgrep -x Tenfold | head -1)
[ -z "$PID" ] && { echo "Tenfold is not running"; exit 1; }
{
  echo "Tenfold PID $PID – $(date '+%Y-%m-%d %H:%M:%S') – $(sw_vers -productVersion) – $(sysctl -n machdep.cpu.brand_string)"
  printf "%-8s %6s %8s %8s %6s %10s\n" time cpu% mem_MB threads files osascript
  for i in $(seq 1 12); do
    CPU=$(ps -p "$PID" -o %cpu= | tr -d ' ')
    MEM=$(( $(ps -p "$PID" -o rss= | tr -d ' ') / 1024 ))
    THR=$(( $(ps -M -p "$PID" | wc -l) - 1 ))
    FILES=$(lsof -p "$PID" 2>/dev/null | wc -l | tr -d ' ')
    OSA=$(pgrep -x osascript | wc -l | tr -d ' ')
    printf "%-8s %6s %8s %8s %6s %10s\n" "$(date +%H:%M:%S)" "$CPU" "$MEM" "$THR" "$FILES" "$OSA"
    sleep 5
  done
  echo "--- top (1 sample) ---"
  top -l 2 -pid "$PID" -stats pid,command,cpu,threads,mem,idlew,power | tail -2
} | tee "perf-${1:-run}.log"

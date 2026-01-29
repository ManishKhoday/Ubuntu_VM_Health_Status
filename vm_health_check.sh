#!/usr/bin/env bash
# VM health check script for Ubuntu
# Health rules:
#  - HEALTHY if CPU, Memory, and Disk usage are all <= 60%
#  - NOT HEALTHY if any one metric > 60%
#
# Usage:
#  ./vm_health_check.sh [--explain]

set -u

THRESHOLD=60.0

usage() {
  cat <<EOF
Usage: $0 [--explain]

  --explain    Print each metric and which metric(s) (if any) caused NOT HEALTHY.
EOF
  exit 2
}

# Basic input validation
if [ $# -gt 1 ]; then
  usage
fi

EXPLAIN=0
if [ $# -eq 1 ]; then
  case "$1" in
    --explain) EXPLAIN=1 ;; 
    *) usage ;;
  esac
fi

# ---------- CPU usage (percent) using /proc/stat ----------
# Read aggregate CPU line twice, 1 second apart, and compute busy percentage
read_cpu_stats() {
  # Returns: total idle
  awk 'NR==1 {
    idle = $5 + $6;
    total = 0;
    for(i=2;i<=NF;i++) total += $i;
    printf "%d %d", total, idle;
    exit
  }' /proc/stat
}

cpu_stats1=$(read_cpu_stats)
sleep 1
cpu_stats2=$(read_cpu_stats)

set -- $cpu_stats1
total1=$1; idle1=$2
set -- $cpu_stats2
total2=$1; idle2=$2

totald=$((total2 - total1))
idled=$((idle2 - idle1))

if [ "$totald" -le 0 ]; then
  cpu_usage=0.0
else
  # compute floating point percentage using awk
  cpu_usage=$(awk -v td="$totald" -v id="$idled" 'BEGIN { printf "%.1f", (td - id) / td * 100 }')
fi

# ---------- Memory usage (percent) using /proc/meminfo ----------
# Prefer MemAvailable; fall back to MemFree+Buffers+Cached if necessary
mem_total_kb=0
mem_available_kb=0

while IFS=":" read -r key val; do
  case "$key" in
    "MemTotal") mem_total_kb=$(echo "$val" | awk '{print $1}');;
    "MemAvailable") mem_available_kb=$(echo "$val" | awk '{print $1}');;
    "MemFree") mem_free_kb=$(echo "$val" | awk '{print $1}');;
    "Buffers") mem_buffers_kb=$(echo "$val" | awk '{print $1}');;
    "Cached") mem_cached_kb=$(echo "$val" | awk '{print $1}');;
  esac
done < /proc/meminfo

if [ -z "${mem_total_kb:-}" ] || [ "$mem_total_kb" -le 0 ]; then
  echo "Error: Unable to determine total memory." >&2
  exit 2
fi

if [ -z "${mem_available_kb:-}" ] || [ "$mem_available_kb" -eq 0 ]; then
  # fallback
  mem_available_kb=$(( ${mem_free_kb:-0} + ${mem_buffers_kb:-0} + ${mem_cached_kb:-0} ))
fi

mem_used_kb=$(( mem_total_kb - mem_available_kb ))

mem_usage=$(awk -v used="$mem_used_kb" -v tot="$mem_total_kb" 'BEGIN { if (tot<=0) printf "0.0"; else printf "%.1f", used / tot * 100 }')

# ---------- Disk usage (percent) for root filesystem using df ----------
# Using df -P to get portable output. Strip trailing %.
disk_usage=$(df -P / 2>/dev/null | awk 'NR==2 { gsub("%","",$5); print $5 }')

if [ -z "${disk_usage}" ]; then
  echo "Error: Unable to determine disk usage for /" >&2
  exit 2
fi

# Ensure disk_usage has decimal format (e.g., "23" -> "23.0")
disk_usage=$(awk -v v="$disk_usage" 'BEGIN { printf "%.1f", v }')

# ---------- Determine health ----------
is_cpu_bad=$(awk -v v="$cpu_usage" -v t="$THRESHOLD" 'BEGIN{print (v > t) ? 1 : 0}')
is_mem_bad=$(awk -v v="$mem_usage" -v t="$THRESHOLD" 'BEGIN{print (v > t) ? 1 : 0}')
is_disk_bad=$(awk -v v="$disk_usage" -v t="$THRESHOLD" 'BEGIN{print (v > t) ? 1 : 0}')

overall_health="HEALTHY"
if [ "$is_cpu_bad" -eq 1 ] || [ "$is_mem_bad" -eq 1 ] || [ "$is_disk_bad" -eq 1 ]; then
  overall_health="NOT HEALTHY"
fi

# ---------- Output ----------
printf "Overall VM health: %s\n" "$overall_health"

if [ "$EXPLAIN" -eq 1 ]; then
  printf "\nMetric details (threshold = %.1f%%):\n" "$THRESHOLD"
  printf "  CPU usage:    %5s%%\n" "$cpu_usage"
  printf "  Memory usage: %5s%%\n" "$mem_usage"
  printf "  Disk usage:   %5s%%\n" "$disk_usage"

  if [ "$overall_health" = "NOT HEALTHY" ]; then
    printf "\nReason(s):\n"
    [ "$is_cpu_bad" -eq 1 ] && printf "  - CPU usage (%.1f%%) exceeds %.1f%%\n" "$cpu_usage" "$THRESHOLD"
    [ "$is_mem_bad" -eq 1 ] && printf "  - Memory usage (%.1f%%) exceeds %.1f%%\n" "$mem_usage" "$THRESHOLD"
    [ "$is_disk_bad" -eq 1 ] && printf "  - Disk usage (%.1f%%) exceeds %.1f%%\n" "$disk_usage" "$THRESHOLD"
  else
    printf "\nAll metrics are within the healthy threshold.\n"
  fi
fi

# Exit code: 0 = healthy, 1 = not healthy, 2 = usage / error
if [ "$overall_health" = "HEALTHY" ]; then
  exit 0
else
  exit 1
fi

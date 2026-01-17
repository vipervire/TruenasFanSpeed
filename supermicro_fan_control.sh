#!/bin/bash
#
# Supermicro X10 Fan Control Script for TrueNAS Scale
# Controls fan speed based on CPU and disk temperatures via IPMI
#

# =============================================================================
# CONFIGURATION
# =============================================================================

MIN_FAN_SPEED=50
MAX_FAN_SPEED=100

CPU_TEMP_MIN=40
CPU_TEMP_MAX=70

DISK_TEMP_MIN=35
DISK_TEMP_MAX=50

POLL_INTERVAL=30

LOG_FILE="/var/log/fan_control.log"
LOG_ENABLED=true

# =============================================================================
# GLOBALS
# =============================================================================

LAST_FAN_SPEED=0
LAST_CPU_TEMP=0
LAST_MAX_DISK_TEMP=0

# =============================================================================
# FUNCTIONS
# =============================================================================

log_msg() {
    local level="$1"
    local msg="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [[ "$LOG_ENABLED" == "true" ]]; then
        echo "[$ts] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
    
    # Always print errors and info to stdout
    if [[ "$level" != "DEBUG" ]]; then
        echo "[$ts] [$level] $msg"
    fi
}

# Set fan mode to manual/full
set_fan_mode_manual() {
    log_msg "INFO" "Setting fan mode to manual"
    ipmitool raw 0x30 0x45 0x01 0x01 >/dev/null 2>&1 || true
    return 0
}

# Set fan duty cycle for both zones
set_all_fans() {
    local percent="$1"
    local hex_val
    
    # Clamp
    [[ "$percent" -lt 0 ]] && percent=0
    [[ "$percent" -gt 100 ]] && percent=100
    
    hex_val=$(printf "0x%02x" "$percent")
    
    # Zone 0 (CPU fans typically)
    ipmitool raw 0x30 0x70 0x66 0x01 0x00 "$hex_val" >/dev/null 2>&1 || true
    # Zone 1 (Peripheral fans typically)
    ipmitool raw 0x30 0x70 0x66 0x01 0x01 "$hex_val" >/dev/null 2>&1 || true
    
    LAST_FAN_SPEED=$percent
    log_msg "INFO" "Set fans to ${percent}%"
}

# Get CPU temp - tries multiple methods
get_cpu_temp() {
    local temp=""
    
    # Method 1: IPMI sensor reading with common names
    for sensor in "CPU Temp" "CPU1 Temp" "CPU Temperature"; do
        temp=$(ipmitool sensor reading "$sensor" 2>/dev/null | awk -F'|' '{gsub(/ /,"",$2); print $2}' | cut -d'.' -f1)
        if [[ "$temp" =~ ^[0-9]+$ ]] && [[ "$temp" -gt 0 ]] && [[ "$temp" -lt 150 ]]; then
            echo "$temp"
            return 0
        fi
    done
    
    # Method 2: Parse SDR for temperature
    temp=$(ipmitool sdr type Temperature 2>/dev/null | grep -iE "cpu|processor" | head -1 | awk -F'|' '{print $5}' | grep -oE '[0-9]+' | head -1)
    if [[ "$temp" =~ ^[0-9]+$ ]] && [[ "$temp" -gt 0 ]] && [[ "$temp" -lt 150 ]]; then
        echo "$temp"
        return 0
    fi
    
    # Method 3: sysfs thermal zones
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        if [[ -r "$zone" ]]; then
            temp=$(cat "$zone" 2>/dev/null)
            if [[ "$temp" =~ ^[0-9]+$ ]]; then
                temp=$((temp / 1000))
                if [[ "$temp" -gt 0 ]] && [[ "$temp" -lt 150 ]]; then
                    echo "$temp"
                    return 0
                fi
            fi
        fi
    done
    
    # Method 4: coretemp hwmon
    for hwmon in /sys/class/hwmon/hwmon*/temp1_input; do
        if [[ -r "$hwmon" ]]; then
            temp=$(cat "$hwmon" 2>/dev/null)
            if [[ "$temp" =~ ^[0-9]+$ ]]; then
                temp=$((temp / 1000))
                if [[ "$temp" -gt 0 ]] && [[ "$temp" -lt 150 ]]; then
                    echo "$temp"
                    return 0
                fi
            fi
        fi
    done
    
    log_msg "WARN" "Could not read CPU temperature"
    echo "0"
    return 1
}

# Get max disk temp via smartctl
get_max_disk_temp() {
    local max_temp=0
    local temp
    local disk
    
    # Iterate over possible disks
    for disk in /dev/sd[a-z] /dev/sd[a-z][a-z] /dev/nvme[0-9]n1; do
        [[ -b "$disk" ]] || continue
        
        # SATA/SAS drives - attribute 194 or 190
        temp=$(smartctl -A "$disk" 2>/dev/null | awk '
            /^194/ && /[Tt]emp/ {print $10; exit}
            /^190/ && /[Tt]emp/ {print $10; exit}
        ')
        
        # NVMe drives
        if [[ -z "$temp" ]] || ! [[ "$temp" =~ ^[0-9]+$ ]]; then
            temp=$(smartctl -A "$disk" 2>/dev/null | awk '/^Temperature:/ {print $2; exit}')
        fi
        
        if [[ "$temp" =~ ^[0-9]+$ ]] && [[ "$temp" -gt 0 ]] && [[ "$temp" -lt 100 ]]; then
            [[ "$temp" -gt "$max_temp" ]] && max_temp=$temp
        fi
    done
    
    echo "$max_temp"
}

# Calculate fan speed with linear interpolation
calc_fan_speed() {
    local temp="$1"
    local t_min="$2"
    local t_max="$3"
    
    if [[ "$temp" -le "$t_min" ]]; then
        echo "$MIN_FAN_SPEED"
    elif [[ "$temp" -ge "$t_max" ]]; then
        echo "$MAX_FAN_SPEED"
    else
        local t_range=$((t_max - t_min))
        local f_range=$((MAX_FAN_SPEED - MIN_FAN_SPEED))
        local t_delta=$((temp - t_min))
        echo $((MIN_FAN_SPEED + (t_delta * f_range / t_range)))
    fi
}

# Main update cycle
update_fans() {
    local cpu_temp
    local disk_temp
    local cpu_speed
    local disk_speed
    local target_speed
    
    cpu_temp=$(get_cpu_temp)
    disk_temp=$(get_max_disk_temp)
    
    LAST_CPU_TEMP=$cpu_temp
    LAST_MAX_DISK_TEMP=$disk_temp
    
    cpu_speed=$(calc_fan_speed "$cpu_temp" "$CPU_TEMP_MIN" "$CPU_TEMP_MAX")
    disk_speed=$(calc_fan_speed "$disk_temp" "$DISK_TEMP_MIN" "$DISK_TEMP_MAX")
    
    # Use higher of the two
    if [[ "$cpu_speed" -gt "$disk_speed" ]]; then
        target_speed=$cpu_speed
    else
        target_speed=$disk_speed
    fi
    
    # Only update if changed by more than 2%
    local diff=$((target_speed - LAST_FAN_SPEED))
    [[ "$diff" -lt 0 ]] && diff=$((-diff))
    
    if [[ "$diff" -gt 2 ]] || [[ "$LAST_FAN_SPEED" -eq 0 ]]; then
        log_msg "INFO" "CPU=${cpu_temp}C Disk=${disk_temp}C -> Fan=${target_speed}%"
        set_all_fans "$target_speed"
    else
        log_msg "DEBUG" "No change needed: CPU=${cpu_temp}C Disk=${disk_temp}C Fan=${LAST_FAN_SPEED}%"
    fi
}

show_status() {
    echo "=== Fan Control Status ==="
    echo ""
    echo "IPMI Temperature Sensors:"
    ipmitool sdr type Temperature 2>/dev/null || echo "  Could not read"
    echo ""
    echo "IPMI Fan Sensors:"
    ipmitool sdr type Fan 2>/dev/null || echo "  Could not read"
    echo ""
    echo "Disk Temperatures (via smartctl):"
    for disk in /dev/sd[a-z] /dev/sd[a-z][a-z] /dev/nvme[0-9]n1; do
        [[ -b "$disk" ]] || continue
        temp=$(smartctl -A "$disk" 2>/dev/null | awk '/^194.*[Tt]emp/ {print $10} /^Temperature:/ {print $2}' | head -1)
        [[ -n "$temp" ]] && echo "  $disk: ${temp}C"
    done
    echo ""
    echo "Config: CPU ${CPU_TEMP_MIN}-${CPU_TEMP_MAX}C, Disk ${DISK_TEMP_MIN}-${DISK_TEMP_MAX}C, Fan ${MIN_FAN_SPEED}-${MAX_FAN_SPEED}%"
}

run_daemon() {
    log_msg "INFO" "Starting fan control daemon (poll every ${POLL_INTERVAL}s)"
    
    trap 'log_msg "INFO" "Shutting down"; exit 0' SIGTERM SIGINT
    
    set_fan_mode_manual
    set_all_fans "$MIN_FAN_SPEED"
    
    while true; do
        update_fans
        sleep "$POLL_INTERVAL"
    done
}

# =============================================================================
# MAIN
# =============================================================================

if [[ $EUID -ne 0 ]]; then
    echo "Error: Must run as root" >&2
    exit 1
fi

if ! command -v ipmitool &>/dev/null; then
    echo "Error: ipmitool not found" >&2
    exit 1
fi

case "${1:-}" in
    --daemon|-d)
        run_daemon
        ;;
    --status|-s)
        show_status
        ;;
    --help|-h)
        echo "Usage: $0 [--daemon|-d] [--status|-s] [--help|-h]"
        echo "  No args: single update"
        echo "  --daemon: run continuously"
        echo "  --status: show temps and fans"
        ;;
    *)
        set_fan_mode_manual
        update_fans
        echo "CPU: ${LAST_CPU_TEMP}C, Disk: ${LAST_MAX_DISK_TEMP}C, Fan: ${LAST_FAN_SPEED}%"
        ;;
esac

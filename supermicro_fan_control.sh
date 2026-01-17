#!/bin/bash
#
# Supermicro X10 Fan Control Script for TrueNAS Scale
# Controls fan speed based on CPU and disk temperatures via IPMI
#
# Requirements:
#   - ipmitool (installed by default on TrueNAS Scale)
#   - smartmontools (for disk temps)
#   - IPMI enabled on Supermicro X10 motherboard
#
# Usage:
#   ./supermicro_fan_control.sh              # Run once
#   ./supermicro_fan_control.sh --daemon     # Run continuously
#   ./supermicro_fan_control.sh --status     # Show current temps and fan speeds

set -euo pipefail

# =============================================================================
# CONFIGURATION - Adjust these values for your setup
# =============================================================================

# Fan speed limits (percentage)
MIN_FAN_SPEED=50
MAX_FAN_SPEED=100

# CPU temperature thresholds (Celsius)
CPU_TEMP_MIN=40      # Below this, fans run at MIN_FAN_SPEED
CPU_TEMP_MAX=70      # At or above this, fans run at MAX_FAN_SPEED

# Disk temperature thresholds (Celsius)
DISK_TEMP_MIN=35     # Below this, no additional fan speed needed
DISK_TEMP_MAX=50     # At or above this, fans run at MAX_FAN_SPEED

# Polling interval for daemon mode (seconds)
POLL_INTERVAL=30

# IPMI settings - use localhost for local BMC access
IPMI_HOST="localhost"
IPMI_USER=""         # Leave empty for local access
IPMI_PASS=""         # Leave empty for local access

# Logging
LOG_FILE="/var/log/fan_control.log"
LOG_ENABLED=true
LOG_MAX_SIZE=10485760  # 10MB - rotate when exceeded

# Hysteresis to prevent fan speed oscillation (degrees)
HYSTERESIS=2

# =============================================================================
# SUPERMICRO X10 IPMI RAW COMMANDS
# =============================================================================

# Fan mode commands
# 0x00 = Standard, 0x01 = Full (manual control), 0x02 = Optimal, 0x04 = Heavy IO
IPMI_SET_FAN_MODE="0x30 0x45 0x01"

# Fan duty cycle command (zone-based)
# Zone 0 = CPU zone, Zone 1 = Peripheral zone (varies by board)
IPMI_SET_FAN_DUTY="0x30 0x70 0x66 0x01"

# =============================================================================
# GLOBAL STATE
# =============================================================================

LAST_FAN_SPEED=0
LAST_CPU_TEMP=0
LAST_MAX_DISK_TEMP=0

# =============================================================================
# FUNCTIONS
# =============================================================================

log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [[ "$LOG_ENABLED" == true ]]; then
        # Rotate log if too large
        if [[ -f "$LOG_FILE" ]] && [[ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null) -gt $LOG_MAX_SIZE ]]; then
            mv "$LOG_FILE" "${LOG_FILE}.old"
        fi
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
    
    if [[ "$level" == "ERROR" ]] || [[ "${VERBOSE:-false}" == true ]]; then
        echo "[$timestamp] [$level] $message" >&2
    fi
}

# Build IPMI command with optional credentials
ipmi_cmd() {
    local cmd=("ipmitool")
    
    if [[ -n "$IPMI_HOST" ]] && [[ "$IPMI_HOST" != "localhost" ]]; then
        cmd+=("-H" "$IPMI_HOST")
        [[ -n "$IPMI_USER" ]] && cmd+=("-U" "$IPMI_USER")
        [[ -n "$IPMI_PASS" ]] && cmd+=("-P" "$IPMI_PASS")
    fi
    
    "${cmd[@]}" "$@"
}

# Set fan mode to Full/Manual for direct PWM control
set_fan_mode_manual() {
    log_message "INFO" "Setting fan mode to Full (manual control)"
    if ! ipmi_cmd raw $IPMI_SET_FAN_MODE 0x01 2>/dev/null; then
        log_message "ERROR" "Failed to set fan mode to manual"
        return 1
    fi
}

# Set fan duty cycle (0-100%)
# Args: zone (0 or 1), percentage (0-100)
set_fan_duty() {
    local zone="${1:-0}"
    local percent="$2"
    local hex_percent
    
    # Clamp to valid range
    ((percent < 0)) && percent=0
    ((percent > 100)) && percent=100
    
    # Convert to hex
    hex_percent=$(printf "0x%02x" "$percent")
    
    log_message "DEBUG" "Setting zone $zone fan duty to ${percent}% ($hex_percent)"
    
    if ! ipmi_cmd raw $IPMI_SET_FAN_DUTY "$zone" "$hex_percent" 2>/dev/null; then
        log_message "ERROR" "Failed to set fan duty for zone $zone"
        return 1
    fi
}

# Set all fan zones to the same duty cycle
set_all_fans() {
    local percent="$1"
    
    # Set both zones (adjust if your board has different zone configuration)
    set_fan_duty 0 "$percent"
    set_fan_duty 1 "$percent"
    
    LAST_FAN_SPEED=$percent
}

# Get CPU temperature from IPMI sensors
get_cpu_temp() {
    local temp
    
    # Try common Supermicro X10 CPU sensor names
    for sensor in "CPU Temp" "CPU1 Temp" "CPU Temperature" "Processor Temp"; do
        temp=$(ipmi_cmd sensor reading "$sensor" 2>/dev/null | awk -F'|' '{print $2}' | tr -d ' ' | cut -d'.' -f1)
        if [[ -n "$temp" ]] && [[ "$temp" =~ ^[0-9]+$ ]]; then
            echo "$temp"
            return 0
        fi
    done
    
    # Fallback: try to get from sysfs (coretemp)
    if [[ -d /sys/class/thermal ]]; then
        for zone in /sys/class/thermal/thermal_zone*/temp; do
            if [[ -f "$zone" ]]; then
                temp=$(cat "$zone" 2>/dev/null)
                if [[ -n "$temp" ]]; then
                    # Convert from millidegrees
                    echo $((temp / 1000))
                    return 0
                fi
            fi
        done
    fi
    
    # Another fallback: parse all IPMI sensors for temperature
    temp=$(ipmi_cmd sdr type Temperature 2>/dev/null | grep -i cpu | head -1 | awk -F'|' '{print $5}' | grep -oE '[0-9]+' | head -1)
    if [[ -n "$temp" ]]; then
        echo "$temp"
        return 0
    fi
    
    log_message "ERROR" "Could not read CPU temperature"
    return 1
}

# Get highest disk temperature using smartctl
get_max_disk_temp() {
    local max_temp=0
    local disk_temp
    local disk_count=0
    
    # Get list of disks (excluding nvme for now, handled separately)
    for disk in /dev/sd[a-z] /dev/sd[a-z][a-z]; do
        [[ -b "$disk" ]] || continue
        
        # Try to get temperature from SMART data
        # Attribute 194 is most common, 190 is used by some drives
        disk_temp=$(smartctl -A "$disk" 2>/dev/null | awk '
            /^194.*Temperature/ {print $10}
            /^190.*Airflow_Temp/ {print $10}
        ' | head -1)
        
        if [[ -n "$disk_temp" ]] && [[ "$disk_temp" =~ ^[0-9]+$ ]]; then
            ((disk_count++))
            ((disk_temp > max_temp)) && max_temp=$disk_temp
        fi
    done
    
    # Check NVMe drives
    for nvme in /dev/nvme[0-9]n1; do
        [[ -b "$nvme" ]] || continue
        
        disk_temp=$(smartctl -A "$nvme" 2>/dev/null | awk '/^Temperature:/ {print $2}')
        
        if [[ -n "$disk_temp" ]] && [[ "$disk_temp" =~ ^[0-9]+$ ]]; then
            ((disk_count++))
            ((disk_temp > max_temp)) && max_temp=$disk_temp
        fi
    done
    
    if ((disk_count == 0)); then
        log_message "WARN" "No disk temperatures could be read"
        echo "0"
        return 1
    fi
    
    log_message "DEBUG" "Read temperatures from $disk_count disks, max: ${max_temp}°C"
    echo "$max_temp"
}

# Calculate fan speed percentage based on temperature
# Uses linear interpolation between min and max thresholds
calc_fan_speed() {
    local current_temp="$1"
    local temp_min="$2"
    local temp_max="$3"
    local fan_min="$MIN_FAN_SPEED"
    local fan_max="$MAX_FAN_SPEED"
    local speed
    
    if ((current_temp <= temp_min)); then
        speed=$fan_min
    elif ((current_temp >= temp_max)); then
        speed=$fan_max
    else
        # Linear interpolation
        local temp_range=$((temp_max - temp_min))
        local fan_range=$((fan_max - fan_min))
        local temp_above_min=$((current_temp - temp_min))
        speed=$((fan_min + (temp_above_min * fan_range / temp_range)))
    fi
    
    echo "$speed"
}

# Apply hysteresis to prevent oscillation
apply_hysteresis() {
    local new_speed="$1"
    local current_speed="$LAST_FAN_SPEED"
    local diff=$((new_speed - current_speed))
    
    # Only change if difference exceeds threshold (mapped from temp hysteresis)
    # This prevents small fluctuations from constantly changing fan speed
    local speed_hysteresis=3  # ~3% change threshold
    
    if ((diff > speed_hysteresis)) || ((diff < -speed_hysteresis)); then
        echo "$new_speed"
    else
        echo "$current_speed"
    fi
}

# Main temperature check and fan adjustment
update_fans() {
    local cpu_temp
    local max_disk_temp
    local cpu_fan_speed
    local disk_fan_speed
    local target_speed
    
    # Get temperatures
    cpu_temp=$(get_cpu_temp) || cpu_temp=0
    max_disk_temp=$(get_max_disk_temp) || max_disk_temp=0
    
    LAST_CPU_TEMP=$cpu_temp
    LAST_MAX_DISK_TEMP=$max_disk_temp
    
    # Calculate required fan speeds for each thermal source
    cpu_fan_speed=$(calc_fan_speed "$cpu_temp" "$CPU_TEMP_MIN" "$CPU_TEMP_MAX")
    disk_fan_speed=$(calc_fan_speed "$max_disk_temp" "$DISK_TEMP_MIN" "$DISK_TEMP_MAX")
    
    # Use the higher of the two
    if ((cpu_fan_speed > disk_fan_speed)); then
        target_speed=$cpu_fan_speed
    else
        target_speed=$disk_fan_speed
    fi
    
    # Apply hysteresis
    target_speed=$(apply_hysteresis "$target_speed")
    
    # Only update if speed changed
    if ((target_speed != LAST_FAN_SPEED)); then
        log_message "INFO" "Adjusting fans: CPU=${cpu_temp}°C, Disk=${max_disk_temp}°C -> Fan=${target_speed}%"
        set_all_fans "$target_speed"
    else
        log_message "DEBUG" "No change: CPU=${cpu_temp}°C, Disk=${max_disk_temp}°C, Fan=${target_speed}%"
    fi
}

# Show current status
show_status() {
    echo "=== Supermicro X10 Fan Control Status ==="
    echo ""
    
    echo "CPU Temperature:"
    ipmi_cmd sdr type Temperature 2>/dev/null | grep -i cpu || echo "  (Could not read)"
    echo ""
    
    echo "Fan Speeds:"
    ipmi_cmd sdr type Fan 2>/dev/null || echo "  (Could not read)"
    echo ""
    
    echo "Disk Temperatures:"
    for disk in /dev/sd[a-z] /dev/sd[a-z][a-z] /dev/nvme[0-9]n1; do
        [[ -b "$disk" ]] || continue
        temp=$(smartctl -A "$disk" 2>/dev/null | awk '/^194.*Temperature/ {print $10} /^Temperature:/ {print $2}' | head -1)
        if [[ -n "$temp" ]]; then
            echo "  $disk: ${temp}°C"
        fi
    done
    echo ""
    
    echo "Configuration:"
    echo "  CPU temp range: ${CPU_TEMP_MIN}°C - ${CPU_TEMP_MAX}°C"
    echo "  Disk temp range: ${DISK_TEMP_MIN}°C - ${DISK_TEMP_MAX}°C"
    echo "  Fan speed range: ${MIN_FAN_SPEED}% - ${MAX_FAN_SPEED}%"
}

# Cleanup on exit
cleanup() {
    log_message "INFO" "Fan control script stopping"
    # Optionally reset to automatic fan control on exit
    # ipmi_cmd raw $IPMI_SET_FAN_MODE 0x02  # Set to Optimal
    exit 0
}

# Daemon mode - run continuously
run_daemon() {
    log_message "INFO" "Starting fan control daemon (interval: ${POLL_INTERVAL}s)"
    
    trap cleanup SIGTERM SIGINT
    
    # Set manual fan mode
    set_fan_mode_manual
    
    # Initial fan speed
    set_all_fans "$MIN_FAN_SPEED"
    
    while true; do
        update_fans
        sleep "$POLL_INTERVAL"
    done
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Check for root privileges (needed for IPMI and smartctl)
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root" >&2
        exit 1
    fi
    
    # Check dependencies
    if ! command -v ipmitool &>/dev/null; then
        echo "Error: ipmitool not found" >&2
        exit 1
    fi
    
    if ! command -v smartctl &>/dev/null; then
        echo "Warning: smartctl not found, disk temperature monitoring disabled" >&2
    fi
    
    case "${1:-}" in
        --daemon|-d)
            run_daemon
            ;;
        --status|-s)
            show_status
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --daemon, -d    Run continuously in daemon mode"
            echo "  --status, -s    Show current temperatures and fan speeds"
            echo "  --help, -h      Show this help message"
            echo ""
            echo "Without options, runs a single fan speed update."
            ;;
        "")
            # Single run mode
            set_fan_mode_manual
            update_fans
            echo "CPU: ${LAST_CPU_TEMP}°C, Max Disk: ${LAST_MAX_DISK_TEMP}°C, Fan: ${LAST_FAN_SPEED}%"
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
}

main "$@"

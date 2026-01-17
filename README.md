# Supermicro X10 Fan Control for TrueNAS Scale

## Overview

This script provides dynamic fan control for Supermicro X10 motherboards on TrueNAS Scale, using IPMI raw commands to adjust fan speeds based on CPU and disk temperatures.

**Features:**
- Linear fan curve from 50% (idle) to 100% (max temp)
- Monitors both CPU and disk temperatures
- Hysteresis to prevent fan speed oscillation
- Runs as a systemd service
- Logging with automatic rotation

## Temperature Curves

| Component | Min Temp | Max Temp | Fan Response |
|-----------|----------|----------|--------------|
| CPU       | 40°C     | 70°C     | 50% → 100%   |
| Disk      | 35°C     | 50°C     | 50% → 100%   |

The script uses whichever source requires higher fan speed.

## Installation on TrueNAS Scale

### Important: TrueNAS Scale Persistence

TrueNAS Scale is based on an immutable root filesystem. Changes to most system directories are lost on reboot. To persist custom scripts, use one of these approaches:

### Option 1: Init/Shutdown Scripts (Recommended)

1. Copy the script to a dataset that persists:
   ```bash
   # Create a scripts directory on your pool
   mkdir -p /mnt/your-pool/scripts
   cp supermicro_fan_control.sh /mnt/your-pool/scripts/
   chmod +x /mnt/your-pool/scripts/supermicro_fan_control.sh
   ```

2. In TrueNAS Web UI:
   - Go to **System → Advanced → Init/Shutdown Scripts**
   - Click **Add**
   - Set:
     - Description: `Fan Control`
     - Type: `Command`
     - Script: `setsid /usr/bin/bash /mnt/yourpool/scripts/supermicro_fan_control.sh --daemon >/dev/null 2>&1`
     - When: `Post Init`

### Option 2: Cron Job with Frequent Polling

If you prefer not to run a daemon, use cron to run the script periodically:

1. Copy script to persistent storage:
   ```bash
   mkdir -p /mnt/your-pool/scripts
   cp supermicro_fan_control.sh /mnt/your-pool/scripts/
   chmod +x /mnt/your-pool/scripts/supermicro_fan_control.sh
   ```

2. In TrueNAS Web UI:
   - Go to **System → Advanced → Cron Jobs**
   - Click **Add**
   - Set:
     - Description: `Fan Control`
     - Command: `/usr/bin/bash /mnt/your-pool/scripts/supermicro_fan_control.sh`
     - Run As User: `root`
     - Schedule: Every minute (`*/1` in the minute field)

### Option 3: Systemd Service (Requires Re-setup After Updates)

This method provides the cleanest daemon operation but requires re-running after TrueNAS updates:

```bash
# Copy files
cp supermicro_fan_control.sh /usr/local/bin/
chmod +x /usr/local/bin/supermicro_fan_control.sh
cp supermicro-fan-control.service /etc/systemd/system/

# Enable and start
systemctl daemon-reload
systemctl enable supermicro-fan-control.service
systemctl start supermicro-fan-control.service

# Check status
systemctl status supermicro-fan-control.service
journalctl -u supermicro-fan-control.service -f
```

## Configuration

Edit the script to adjust these variables at the top:

```bash
# Fan speed limits (percentage)
MIN_FAN_SPEED=50      # Minimum fan speed
MAX_FAN_SPEED=100     # Maximum fan speed

# CPU temperature thresholds (Celsius)
CPU_TEMP_MIN=40       # Below this = MIN_FAN_SPEED
CPU_TEMP_MAX=70       # At or above = MAX_FAN_SPEED

# Disk temperature thresholds (Celsius)
DISK_TEMP_MIN=35      # Below this = MIN_FAN_SPEED
DISK_TEMP_MAX=50      # At or above = MAX_FAN_SPEED

# Polling interval for daemon mode (seconds)
POLL_INTERVAL=30
```

## Usage

```bash
# Single run (test mode)
./supermicro_fan_control.sh

# Show current temperatures and fan speeds
./supermicro_fan_control.sh --status

# Run as daemon
./supermicro_fan_control.sh --daemon
```

## Verifying IPMI Access

Before running, verify IPMI is working:

```bash
# Check CPU temperature sensors
ipmitool sdr type Temperature

# Check current fan speeds
ipmitool sdr type Fan

# Test manual fan control (set to 60%)
ipmitool raw 0x30 0x45 0x01 0x01           # Set to Full/Manual mode
ipmitool raw 0x30 0x70 0x66 0x01 0x00 0x3c # Set zone 0 to 60%
ipmitool raw 0x30 0x70 0x66 0x01 0x01 0x3c # Set zone 1 to 60%
```

## Troubleshooting

### "Could not read CPU temperature"

The script tries multiple sensor names. Check what your board reports:
```bash
ipmitool sdr type Temperature
```

Then update the sensor names in the `get_cpu_temp()` function if needed.

### Fans not responding

1. Verify your board supports the raw commands:
   ```bash
   # Check if board is in manual mode
   ipmitool raw 0x30 0x45 0x00
   ```

2. Some X10 variants use different zone mappings. Check Supermicro documentation for your specific board model.

### Permission denied

Ensure the script runs as root:
```bash
sudo ./supermicro_fan_control.sh --status
```

## Tested Boards

- X10SL7-F
- X10SLM-F
- X10SLL-F
- X10DRL-i
- X10SRi-F

Other X10 boards should work but may need sensor name adjustments.

## Safety Notes

- The script enforces a 50% minimum fan speed to prevent thermal issues
- If the script crashes, fans will remain at their last set speed
- Consider setting BIOS fan control to "Optimal" as a fallback
- Monitor temperatures for the first few days after deployment

## Log Location

Logs are written to: `/var/log/fan_control.log`

View recent activity:
```bash
tail -f /var/log/fan_control.log
```

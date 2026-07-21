#!/usr/bin/env python3
"""
MiOS Dedicated Live SSOT-Driven Build & Flash Monitor (Cross-Platform FOSS TUI)
Powered by Python `rich` (Live, Layout, Panel, Table, Progress, Text) for Windows + Linux.
Sourced 100% LIVE from mios.toml SSOT and Real-Time Process/Log State.
"""

import sys
import os
import time
import glob
import psutil
import shutil
import re
from datetime import datetime

from rich.live import Live
from rich.layout import Layout
from rich.panel import Panel
from rich.table import Table
from rich.progress import Progress, BarColumn, TextColumn
from rich.text import Text
from rich.console import Console

# Initialize Rich Console
console = Console()

# -----------------------------------------------------------------------------
# 1. SSOT Config & Color Resolution
# -----------------------------------------------------------------------------
TOML_PATH = os.environ.get('MIOS_TOML', r'C:\mios-bootstrap\mios.toml')
if not os.path.exists(TOML_PATH):
    for candidate in [r'C:\MiOS\usr\share\mios\mios.toml', r'M:\etc\mios\mios.toml']:
        if os.path.exists(candidate):
            TOML_PATH = candidate
            break

def parse_toml_colors(path):
    colors = {
        'bg': '#282262',
        'fg': '#E7DFD3',
        'accent': '#1A407F',
        'warning': '#F35C15',
        'error': '#DC271B',
        'success': '#3E7765',
        'muted': '#948E8E',
        'subtle': '#B7C9D7',
        'cyan': '#06B6D4',
        'magenta': '#D946EF'
    }
    if os.path.exists(path):
        try:
            with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
            match = re.search(r'\[colors\]\s*(.*?)(?=\n\s*\[|\Z)', content, re.DOTALL)
            if match:
                for line in match.group(1).splitlines():
                    km = re.match(r'^\s*([a-zA-Z0-9_]+)\s*=\s*["\']?#?([0-9A-Fa-f]{6})["\']?', line)
                    if km:
                        k, v = km.group(1), km.group(2)
                        colors[k] = f"#{v}"
        except Exception:
            pass
    return colors

PAL = parse_toml_colors(TOML_PATH)

STAGES = [
    {"id": 1, "name": "Preflight Checks & SSOT Init",  "min": 0.0,  "max": 10.0},
    {"id": 2, "name": "Medicat & Core Downloads",      "min": 10.0, "max": 25.0},
    {"id": 3, "name": "Localhost WinPE WIM Servicing", "min": 25.0, "max": 40.0},
    {"id": 4, "name": "WinPE Unmount & Compression",  "min": 40.0, "max": 50.0},
    {"id": 5, "name": "MiOS-Xbox ISO Compilation",     "min": 50.0, "max": 65.0},
    {"id": 6, "name": "Dedicated Directory Staging",   "min": 65.0, "max": 75.0},
    {"id": 7, "name": "Fail-Fast Verification Gate",   "min": 75.0, "max": 85.0},
    {"id": 8, "name": "Ventoy Bootloader & Theme",     "min": 85.0, "max": 90.0},
    {"id": 9, "name": "32-Thread Robocopy USB Flash",  "min": 90.0, "max": 98.0},
    {"id": 10,"name": "Branding & Installation Complete","min": 98.0,"max": 100.0}
]

SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

# -----------------------------------------------------------------------------
# 2. Dynamic Telemetry & Log Resolver
# -----------------------------------------------------------------------------
def get_active_log():
    task_logs = glob.glob(r"C:\Users\Administrator\.gemini\antigravity-ide\brain\dba6616d-053d-43cd-b86d-a98f223952b8\.system_generated\tasks\task-*.log")
    valid_logs = []
    for path in task_logs:
        try:
            if os.path.getsize(path) > 500:
                valid_logs.append((os.path.getmtime(path), path))
        except Exception:
            pass
    if valid_logs:
        valid_logs.sort(reverse=True)
        return valid_logs[0][1]
    return r'C:\Windows\Temp\mios-cat-install.log'

def get_disk_mb(path):
    if os.path.exists(path):
        try:
            usage = shutil.disk_usage(path)
            return round((usage.total - usage.free) / (1024 * 1024), 1)
        except Exception:
            pass
    return 0.0

def get_active_processes():
    procs = []
    total_ram = 0.0
    is_dism = False
    target_names = {'7z.exe', '7za.exe', 'robocopy.exe', 'dism.exe', 'curl.exe', 'aria2c.exe', 'wimlib-imagex.exe'}
    
    for p in psutil.process_iter(['pid', 'name', 'memory_info']):
        try:
            pname = p.info['name'].lower()
            if pname in target_names or pname.replace('.exe','') in target_names:
                ram_mb = round(p.info['memory_info'].rss / (1024 * 1024), 1)
                total_ram += ram_mb
                clean_name = p.info['name'].replace('.exe','')
                procs.append(f"{clean_name}[PID:{p.info['pid']} {ram_mb}MB]")
                if 'dism' in pname:
                    is_dism = True
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    return procs, round(total_ram, 1), is_dism

# -----------------------------------------------------------------------------
# 3. Main Layout Generator
# -----------------------------------------------------------------------------
def make_layout():
    layout = Layout()
    layout.split(
        Layout(name="header", size=3),
        Layout(name="body", size=18),
        Layout(name="logs", ratio=1)
    )
    layout["body"].split_row(
        Layout(name="left", ratio=1),
        Layout(name="right", ratio=1)
    )
    return layout

def render_dashboard(step_counter):
    spin_char = SPINNER[step_counter % len(SPINNER)]
    
    # Measure Telemetry
    usb_mb = get_disk_mb("D:\\")
    ssd_mb = get_disk_mb("M:\\")
    proc_list, total_ram, is_dism = get_active_processes()
    proc_str = " ".join(proc_list) if proc_list else "Idle / Waiting for Subprocess Dispatch"
    
    # Read Active Log Stream
    active_log_path = get_active_log()
    log_lines = []
    if os.path.exists(active_log_path):
        try:
            with open(active_log_path, 'r', encoding='utf-8', errors='ignore') as f:
                log_lines = [line.strip() for line in f if line.strip()]
        except Exception:
            pass

    # Read DISM Log if modified recently
    dism_lines = []
    dism_path = r'C:\Windows\Logs\DISM\dism.log'
    if os.path.exists(dism_path):
        try:
            mtime = os.path.getmtime(dism_path)
            if (time.time() - mtime) < 600:
                with open(dism_path, 'r', encoding='utf-8', errors='ignore') as f:
                    dall = [l.strip() for l in f if any(k in l for k in ['DISM Package Manager', 'Processing', 'Image', 'Mounting', 'Unmounting'])]
                    dism_lines = [f"[DISM] {l}" for l in dall[-4:]]
        except Exception:
            pass

    # Slice lines after LAST run marker
    start_idx = -1
    for i in range(len(log_lines)-1, -1, -1):
        if re.search(r'\[START\]|RUNNING PREFLIGHT CHECKS|STARTING MiOS-Cat INSTALLATION', log_lines[i]):
            start_idx = i
            break
    if start_idx >= 0:
        log_lines = log_lines[start_idx:]

    # Determine Active Stage
    current_stage_id = 1
    sub_task_pct = 0.0
    sub_task_name = "Initializing preflight checks & environment..."
    alerts = []

    for line in log_lines:
        if re.search(r'RUNNING PREFLIGHT CHECKS', line): current_stage_id = max(current_stage_id, 1)
        if re.search(r'PHASE 1: ALL-IN-ONE|Core Medicat archive|Downloading|Pulling', line): current_stage_id = max(current_stage_id, 2)
        if re.search(r'Extracting Mini_Windows WIM|Servicing Mini_Windows|Mounting.*boot\.wim', line): current_stage_id = max(current_stage_id, 3)
        if re.search(r'Exporting and compressing Localhost|trim_path|Rebuilding boot\.wim', line): current_stage_id = max(current_stage_id, 4)
        if re.search(r'Compiling MiOS-Xbox|autounattend|New-MiOSISO|Removing.*capabilities|Disabling|Mounting.*26100|Stock ISO|oscdimg|Baking|wallpaper|SetupComplete|virtio|Dismount -Save', line): current_stage_id = max(current_stage_id, 5)
        if re.search(r'Writing MiOS-PE|Writing Documents|PortableApps', line): current_stage_id = max(current_stage_id, 6)
        if re.search(r'SINGLE FLASH PASS|Zero USB writes', line): current_stage_id = max(current_stage_id, 7)
        if re.search(r'Ventoy|autorun\.inf', line): current_stage_id = max(current_stage_id, 8)
        if re.search(r'Writing PortableApps suite|robocopy .* D:', line): current_stage_id = max(current_stage_id, 9)
        if re.search(r'MiOS-Cat DEDICATED USB INSTALLATION COMPLETED|AIO SUCCESS', line): current_stage_id = 10; sub_task_pct = 100.0

        pm = re.search(r'(\d+\.\d+)%', line)
        if pm:
            val = float(pm.group(1))
            if val <= 100.0: sub_task_pct = val

        if re.search(r'\[!\]|\[WARNING\]|\[FATAL ERROR\]|ERROR', line):
            alerts.append(line)

    if is_dism or any(re.search(r'virtio|Dismount -Save|Baking|wallpaper|SetupComplete', l) for l in log_lines):
        current_stage_id = max(current_stage_id, 5)

    if log_lines:
        clean_last = re.sub(r'\x1b\[[0-9;]*m', '', log_lines[-1])
        sub_task_name = f"{spin_char} {clean_last[:90]}"

    stg = next((s for s in STAGES if s['id'] == current_stage_id), STAGES[0])
    range_pct = stg['max'] - stg['min']
    overall_pct = stg['min'] + (range_pct * (sub_task_pct / 100.0))

    # Construct Layout
    layout = make_layout()

    # 1. Header Panel
    hdr_text = Text()
    hdr_text.append("M i O S   v2026.07   --   S S O T   L I V E   F L A S H   M O N I T O R", style=f"bold {PAL['warning']}")
    hdr_text.append("\nDedicated AIO Operating System -- Real-Time Cross-Platform Telemetry Stream", style=f"{PAL['muted']}")
    layout["header"].update(Panel(hdr_text, style=f"{PAL['accent']}"))

    # 2. Left Telemetry Panel
    left_table = Table(show_header=False, box=None, padding=(0, 1))
    left_table.add_column("Key", style=f"bold {PAL['subtle']}", width=14)
    left_table.add_column("Val", style=f"{PAL['fg']}")

    left_table.add_row("SSOT Config", TOML_PATH)
    left_table.add_row("Target USB", f"D:\\ (Used Space: {usb_mb} MB)")
    left_table.add_row("SSD Stage", f"M:\\ (SSD Volume Used: {ssd_mb} MB)")
    left_table.add_row("Subprocesses", f"[{PAL['cyan']}]{proc_str} (RAM: {total_ram} MB)[/{PAL['cyan']}]")
    left_table.add_row("", "")
    left_table.add_row("Active Stage", f"Stage {current_stage_id} of 10 : [{PAL['warning']}]{stg['name']}[/{PAL['warning']}]")
    left_table.add_row("Current Task", sub_task_name)
    left_table.add_row("", "")
    left_table.add_row("Overall Progress", f"[{PAL['success']}]{overall_pct:.1f}%[/{PAL['success']}]")
    left_table.add_row("Sub-Task Progress", f"[{PAL['warning']}]{sub_task_pct:.1f}%[/{PAL['warning']}]")

    layout["left"].update(Panel(left_table, title="[bold]SYSTEM TELEMETRY[/bold]", border_style=PAL['accent']))

    # 3. Right Pipeline Stages Panel
    right_table = Table(show_header=False, box=None, padding=(0, 1))
    right_table.add_column("S1", width=30)
    right_table.add_column("S2", width=30)

    for i in range(0, 10, 2):
        s1 = STAGES[i]
        s2 = STAGES[i+1]

        b1 = f"[{PAL['success']}][ DONE ][/{PAL['success']}]" if s1['id'] < current_stage_id else (f"[{PAL['warning']}][{spin_char} RUN ][/{PAL['warning']}]" if s1['id'] == current_stage_id else f"[{PAL['muted']}][QUEUED][/{PAL['muted']}]")
        b2 = f"[{PAL['success']}][ DONE ][/{PAL['success']}]" if s2['id'] < current_stage_id else (f"[{PAL['warning']}][{spin_char} RUN ][/{PAL['warning']}]" if s2['id'] == current_stage_id else f"[{PAL['muted']}][QUEUED][/{PAL['muted']}]")

        right_table.add_row(
            f"{b1} Stg {s1['id']:02d}: {s1['name'][:20]}",
            f"{b2} Stg {s2['id']:02d}: {s2['name'][:20]}"
        )

    layout["right"].update(Panel(right_table, title="[bold]PIPELINE STAGES STATUS[/bold]", border_style=PAL['accent']))

    # 4. Bottom Streaming Log Panel
    recent_tail = log_lines[-12:] + dism_lines[-4:]
    log_text = Text()
    if recent_tail:
        for l in recent_tail[-12:]:
            clean = re.sub(r'\x1b\[[0-9;]*m', '', l)
            if '100.0%' in clean or '[OK]' in clean:
                log_text.append(f"   ✔ {clean}\n", style=PAL['success'])
            elif '[!]' in clean or 'WARNING' in clean:
                log_text.append(f"   ⚠ {clean}\n", style=PAL['warning'])
            elif 'ERROR' in clean or 'FAILED' in clean:
                log_text.append(f"   ✖ {clean}\n", style=PAL['error'])
            elif any(k in clean for k in ['Extracting', 'Servicing', 'Compiling', 'Flashing', 'Removing', 'Disabling', 'virtio']):
                log_text.append(f"   ⚡ {clean}\n", style=PAL['magenta'])
            else:
                log_text.append(f"   > {clean}\n", style=PAL['fg'])
    else:
        log_text.append("   > Monitoring active build pipeline live...\n", style=PAL['muted'])

    layout["logs"].update(Panel(log_text, title="[bold]LIVE MULTI-SOURCE LOG STREAM[/bold]", border_style=PAL['accent']))

    return layout

# -----------------------------------------------------------------------------
# 4. Entrypoint Loop
# -----------------------------------------------------------------------------
def main():
    step = 0
    with Live(render_dashboard(step), console=console, refresh_per_second=4, screen=True) as live:
        while True:
            time.sleep(0.25)
            step += 1
            live.update(render_dashboard(step))

if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)

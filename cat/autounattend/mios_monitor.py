#!/usr/bin/env python3
"""
MiOS Dedicated Live SSOT-Driven Build & Flash Monitor (Cross-Platform FOSS TUI)
Powered by Python `rich` (Live, Layout, Panel, Table, Progress, Text) for Windows + Linux.
Sourced 100% LIVE from mios.toml SSOT and Real-Time Process/Log Telemetry.
"""

import sys
import os
import time
import glob
import shutil
import re
from datetime import datetime, timedelta

try:
    import psutil
except ImportError:
    psutil = None

from rich.live import Live
from rich.layout import Layout
from rich.panel import Panel
from rich.table import Table
from rich.progress import Progress, BarColumn, TextColumn, TaskProgressColumn
from rich.text import Text
from rich import box
from rich.console import Console

# Initialize Rich Console
console = Console()
START_TIME = datetime.now()

# -----------------------------------------------------------------------------
# 1. SSOT Config & Color Resolution
# -----------------------------------------------------------------------------
TOML_PATH = os.environ.get('MIOS_TOML', r'C:\mios-bootstrap\mios.toml')
if not os.path.exists(TOML_PATH):
    for candidate in [r'C:\MiOS\usr\share\mios\mios.toml', r'M:\etc\mios\mios.toml']:
        if os.path.exists(candidate):
            TOML_PATH = candidate
            break

def parse_ssot_version(path):
    if os.path.exists(path):
        try:
            with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
            match = re.search(r'mios_version\s*=\s*["\']([^"\']+)["\']', content)
            if match:
                return match.group(1)
        except Exception:
            pass
    return "0.3.0"

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
        'magenta': '#D946EF',
        'gold': '#EAB308'
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

MIOS_VERSION = parse_ssot_version(TOML_PATH)
PAL = parse_toml_colors(TOML_PATH)

STAGES = [
    {"id": 1,  "name": "Preflight Checks & SSOT Init",      "min": 0.0,  "max": 10.0},
    {"id": 2,  "name": "Medicat & Core ISO Downloads",       "min": 10.0, "max": 25.0},
    {"id": 3,  "name": "Localhost WinPE Servicing",         "min": 25.0, "max": 40.0},
    {"id": 4,  "name": "WinPE Unmount & ESD Compression",    "min": 40.0, "max": 50.0},
    {"id": 5,  "name": "MiOS-Xbox ISO Compilation",         "min": 50.0, "max": 65.0},
    {"id": 6,  "name": "Dedicated Directory Staging",       "min": 65.0, "max": 75.0},
    {"id": 7,  "name": "Fail-Fast Verification Gate",       "min": 75.0, "max": 85.0},
    {"id": 8,  "name": "Ventoy Bootloader & Theme",         "min": 85.0, "max": 90.0},
    {"id": 9,  "name": "32-Thread Robocopy USB Flash",      "min": 90.0, "max": 98.0},
    {"id": 10, "name": "Branding & Installation Complete",  "min": 98.0, "max": 100.0}
]

SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

# -----------------------------------------------------------------------------
# 2. Dynamic Telemetry & Log Resolver
# -----------------------------------------------------------------------------
def get_active_log():
    all_task_logs = glob.glob(r"C:\Users\Administrator\.gemini\antigravity-ide\brain\*\.system_generated\tasks\task-*.log")
    task_logs = []
    for tpath in all_task_logs:
        try:
            if os.path.getsize(tpath) > 1000:
                with open(tpath, 'r', encoding='utf-8', errors='ignore') as f:
                    head = f.read(4096)
                    if "STARTING MiOS-Cat" in head or "MiOS-Cat DEDICATED USB" in head or "SINGLE FLASH PASS" in head:
                        task_logs.append(tpath)
        except Exception:
            pass

    task_logs += glob.glob(r"C:\Windows\Temp\mios-cat-*.log")
    task_logs += glob.glob(r"M:\medicat_stage\isobuild_live\logs\*.log")
    valid_logs = []
    for path in task_logs:
        try:
            if os.path.getsize(path) > 200:
                valid_logs.append((os.path.getmtime(path), path))
        except Exception:
            pass
    if valid_logs:
        valid_logs.sort(reverse=True)
        return valid_logs[0][1]
    return r'C:\Windows\Temp\mios-cat-install.log'

def get_disk_info(drive_letter):
    if os.path.exists(drive_letter):
        try:
            usage = shutil.disk_usage(drive_letter)
            used_gb = round((usage.total - usage.free) / (1024 ** 3), 2)
            total_gb = round(usage.total / (1024 ** 3), 1)
            pct = round((usage.total - usage.free) / usage.total * 100, 1)
            return f"{used_gb} GB / {total_gb} GB ({pct}%)"
        except Exception:
            pass
    return "N/A"

def get_system_telemetry():
    cpu_pct = 0.0
    ram_pct = 0.0
    ram_used_gb = 0.0
    procs = []
    total_proc_ram = 0.0
    is_dism = False
    is_robocopy = False
    is_7z = False
    
    target_names = {'7z', '7za', 'robocopy', 'dism', 'curl', 'aria2c', 'wimlib-imagex', 'oscdimg'}
    
    if psutil is not None:
        try:
            cpu_pct = psutil.cpu_percent(interval=None)
            mem = psutil.virtual_memory()
            ram_pct = mem.percent
            ram_used_gb = round(mem.used / (1024 ** 3), 2)
            
            for p in psutil.process_iter(['pid', 'name', 'memory_info']):
                try:
                    if not p.info or not p.info.get('name'):
                        continue
                    pname = p.info['name'].lower().replace('.exe','')
                    if pname in target_names:
                        mem_info = p.info.get('memory_info')
                        ram_mb = round(mem_info.rss / (1024 * 1024), 1) if mem_info else 0.0
                        total_proc_ram += ram_mb
                        procs.append(f"{pname.upper()}[PID:{p.info['pid']} {ram_mb:.0f}MB]")
                        if 'dism' in pname: is_dism = True
                        if 'robocopy' in pname: is_robocopy = True
                        if '7z' in pname: is_7z = True
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    pass
        except Exception:
            pass
            
    return cpu_pct, ram_pct, ram_used_gb, procs, round(total_proc_ram, 1), is_dism, is_robocopy, is_7z

# -----------------------------------------------------------------------------
# 3. Main Layout Generator
# -----------------------------------------------------------------------------
def make_layout():
    layout = Layout()
    layout.split(
        Layout(name="header", size=4),
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
    elapsed = str(datetime.now() - START_TIME).split('.')[0]
    
    # Measure Telemetry
    usb_info = get_disk_info("D:\\")
    ssd_info = get_disk_info("M:\\")
    cpu_pct, ram_pct, ram_used_gb, proc_list, total_proc_ram, is_dism, is_robocopy, is_7z = get_system_telemetry()
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

    # Read DISM Log if modified recently (Filter out noisy provider lines)
    dism_lines = []
    dism_path = r'C:\Windows\Logs\DISM\dism.log'
    if os.path.exists(dism_path):
        try:
            mtime = os.path.getmtime(dism_path)
            if (time.time() - mtime) < 600:
                with open(dism_path, 'r', encoding='utf-8', errors='ignore') as f:
                    for l in f:
                        l_clean = l.strip()
                        # Exclude provider noise (FfuManager, VhdImage, VHDManager, etc.)
                        if any(noise in l_clean for noise in ['FfuManager', 'VhdImage', 'VHDManager', 'Initialize']):
                            continue
                        if any(k in l_clean for k in ['Processing', 'Image', 'Mounting', 'Unmounting', 'Exporting', 'Capability', 'Package']):
                            dism_lines.append(f"[DISM] {l_clean}")
                dism_lines = dism_lines[-4:]
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

    # Determine Active Stage accurately
    current_stage_id = 1
    sub_task_pct = 0.0
    sub_task_name = "Initializing preflight checks & environment..."
    alerts = []
    is_completed = False

    for line in log_lines:
        if re.search(r'RUNNING PREFLIGHT CHECKS', line): current_stage_id = max(current_stage_id, 1)
        if re.search(r'PHASE 1: ALL-IN-ONE|Core Medicat archive|Downloading|Pulling', line): current_stage_id = max(current_stage_id, 2)
        if re.search(r'Extracting Mini_Windows WIM|Servicing Mini_Windows|Mounting.*boot\.wim', line): current_stage_id = max(current_stage_id, 3)
        if re.search(r'Exporting and compressing|trim_path|Rebuilding boot\.wim', line): current_stage_id = max(current_stage_id, 4)
        if re.search(r'Compiling MiOS-Xbox|autounattend|New-MiOSISO|Removing.*capabilities|Disabling|Mounting.*26100|Stock ISO|oscdimg|Baking|wallpaper|SetupComplete|virtio|Dismount -Save', line): current_stage_id = max(current_stage_id, 5)
        if re.search(r'Writing MiOS-PE|Writing Documents|PortableApps', line): current_stage_id = max(current_stage_id, 6)
        if re.search(r'SINGLE FLASH PASS|Zero USB writes|\[AIO SUCCESS\] All images 100% compiled', line): current_stage_id = max(current_stage_id, 7)
        if re.search(r'Ventoy|Installing Ventoy|autorun\.inf|TARGET DRIVE FORMAT', line): current_stage_id = max(current_stage_id, 8)
        if re.search(r'Writing PortableApps suite|robocopy .* D:|Extracting payload to D:', line): current_stage_id = max(current_stage_id, 9)
        if re.search(r'MiOS-Cat.*COMPLETED|FLASH COMPLETE SUCCESS|is now ready to boot', line, re.IGNORECASE):
            is_completed = True

        pm = re.search(r'(\d+(\.\d+)?)%', line)
        if pm:
            val = float(pm.group(1))
            if val <= 100.0:
                sub_task_pct = val

        if re.search(r'\[!\]|\[WARNING\]|\[FATAL ERROR\]|ERROR', line):
            alerts.append(line)

    # Process Overrides
    if is_robocopy:
        current_stage_id = 9
    elif is_dism and current_stage_id < 5:
        current_stage_id = 5

    if is_completed and not proc_list:
        current_stage_id = 10
        sub_task_pct = 100.0
        overall_pct = 100.0
    else:
        stg = next((s for s in STAGES if s['id'] == current_stage_id), STAGES[0])
        range_pct = stg['max'] - stg['min']
        overall_pct = min(99.9, stg['min'] + (range_pct * (sub_task_pct / 100.0)))

    # Subtask name resolution
    for l in reversed(log_lines):
        clean_l = re.sub(r'\x1b\[[0-9;]*m', '', l).strip()
        if clean_l and not re.match(r'^\d+(\.\d+)?%$', clean_l) and not clean_l.startswith('[' + '=' * 10):
            sub_task_name = f"{spin_char} {clean_l[:85]}"
            break

    # Construct Layout
    layout = make_layout()

    # 1. Header Panel
    hdr_text = Text()
    hdr_text.append(f"✦ M i O S   v{MIOS_VERSION}   ::   S S O T   L I V E   F L A S H   M O N I T O R ✦\n", style=f"bold {PAL['warning']}")
    hdr_text.append(f"Dedicated AIO Operating System  •  Elapsed Time: {elapsed}  •  Status: ", style=f"{PAL['subtle']}")
    if is_completed:
        hdr_text.append("✔ FLASH COMPLETE & VERIFIED", style=f"bold {PAL['success']}")
    else:
        hdr_text.append(f"{spin_char} ACTIVE BUILD PIPELINE", style=f"bold {PAL['cyan']}")

    layout["header"].update(Panel(hdr_text, style=f"{PAL['accent']}", box=box.ROUNDED))

    # 2. Left Telemetry Panel
    left_table = Table(show_header=False, box=None, padding=(0, 1))
    left_table.add_column("Key", style=f"bold {PAL['subtle']}", width=15)
    left_table.add_column("Val", style=f"{PAL['fg']}")

    left_table.add_row("SSOT Config", f"[{PAL['fg']}]{TOML_PATH}[/{PAL['fg']}]")
    left_table.add_row("Target USB (D:)", f"[{PAL['gold']}]{usb_info}[/{PAL['gold']}]")
    left_table.add_row("SSD Stage (M:)", f"[{PAL['subtle']}]{ssd_info}[/{PAL['subtle']}]")
    left_table.add_row("Host CPU / RAM", f"[{PAL['cyan']}]CPU: {cpu_pct}% | RAM: {ram_pct}% ({ram_used_gb} GB)[/{PAL['cyan']}]")
    left_table.add_row("Active Tasks", f"[{PAL['magenta']}]{proc_str} ({total_proc_ram:.0f}MB)[/{PAL['magenta']}]")
    left_table.add_row("────────────────", "─────────────────────────────────────────")
    left_table.add_row("Current Phase", f"Stage {current_stage_id} of 10 : [{PAL['warning']}]{STAGES[current_stage_id-1]['name']}[/{PAL['warning']}]")
    left_table.add_row("Active Task", f"[{PAL['fg']}]{sub_task_name}[/{PAL['fg']}]")
    left_table.add_row("Overall Progress", f"[{PAL['success']}]{overall_pct:.1f}%[/{PAL['success']}]  [bold {PAL['success']}]{'█' * int(overall_pct // 5)}{'░' * (20 - int(overall_pct // 5))}[/bold {PAL['success']}]")
    left_table.add_row("Subtask Progress", f"[{PAL['warning']}]{sub_task_pct:.1f}%[/{PAL['warning']}]  [bold {PAL['warning']}]{'█' * int(sub_task_pct // 5)}{'░' * (20 - int(sub_task_pct // 5))}[/bold {PAL['warning']}]")

    layout["left"].update(Panel(left_table, title=f"[bold {PAL['warning']}]SYSTEM TELEMETRY & HARDWARE METRICS[/bold {PAL['warning']}]", border_style=PAL['accent'], box=box.ROUNDED))

    # 3. Right Pipeline Stages Panel
    right_table = Table(show_header=False, box=None, padding=(0, 1), expand=True)
    right_table.add_column("S1", ratio=1)
    right_table.add_column("S2", ratio=1)

    for i in range(0, 10, 2):
        s1 = STAGES[i]
        s2 = STAGES[i+1]

        b1 = f"[{PAL['success']}]✔ DONE[/{PAL['success']}]" if s1['id'] < current_stage_id else (f"[{PAL['warning']}]{spin_char} RUN [/{PAL['warning']}]" if s1['id'] == current_stage_id else f"[{PAL['muted']}]░ QUE [/{PAL['muted']}]")
        b2 = f"[{PAL['success']}]✔ DONE[/{PAL['success']}]" if s2['id'] < current_stage_id else (f"[{PAL['warning']}]{spin_char} RUN [/{PAL['warning']}]" if s2['id'] == current_stage_id else f"[{PAL['muted']}]░ QUE [/{PAL['muted']}]")

        right_table.add_row(
            f"{b1} Stg {s1['id']:02d}: {s1['name']}",
            f"{b2} Stg {s2['id']:02d}: {s2['name']}"
        )

    layout["right"].update(Panel(right_table, title=f"[bold {PAL['warning']}]PIPELINE STAGE MATRIX[/bold {PAL['warning']}]", border_style=PAL['accent'], box=box.ROUNDED))

    # 4. Bottom Streaming Log Panel (Filtered Buffer: Excludes Raw Progress Bars & DISM Noise)
    filtered_logs = []
    for l in log_lines:
        clean_l = re.sub(r'\x1b\[[0-9;]*m', '', l).strip()
        if not clean_l or re.match(r'^\d+(\.\d+)?%$', clean_l) or re.match(r'^\[?[\=\-\#]+\s*\d+(\.\d+)?%\s*[\=\-\#]*\]?$', clean_l):
            continue
        if re.search(r'var\\lib\\mios\\(artifacts|snapshots)\\', clean_l, re.IGNORECASE):
            continue
        if any(noise in clean_l for noise in ['FfuManager', 'VhdImage', 'VHDManager', 'Initialize']):
            continue
        filtered_logs.append(clean_l)

    recent_tail = filtered_logs[-14:] + dism_lines[-3:]
    log_text = Text()
    if recent_tail:
        for l in recent_tail[-14:]:
            clean = re.sub(r'\x1b\[[0-9;]*m', '', l)
            if '100.0%' in clean or '[OK]' in clean or 'PASS' in clean or 'SUCCESS' in clean:
                log_text.append(f"  ✔ {clean}\n", style=f"bold {PAL['success']}")
            elif '[!]' in clean or 'WARNING' in clean or 'WARN' in clean:
                log_text.append(f"  ⚠ {clean}\n", style=f"bold {PAL['warning']}")
            elif 'ERROR' in clean or 'FAILED' in clean or 'FATAL' in clean:
                log_text.append(f"  ✖ {clean}\n", style=f"bold {PAL['error']}")
            elif any(k in clean for k in ['Extracting', 'Servicing', 'Compiling', 'Flashing', 'Removing', 'Disabling', 'virtio', 'Baking', 'Mounting', 'Unmounting']):
                log_text.append(f"  ⚡ {clean}\n", style=f"bold {PAL['magenta']}")
            else:
                log_text.append(f"  › {clean}\n", style=PAL['fg'])
    else:
        log_text.append("  › Monitoring active build pipeline live...\n", style=PAL['muted'])

    layout["logs"].update(Panel(log_text, title=f"[bold {PAL['warning']}]LIVE MULTI-SOURCE LOG STREAM (FILTERED TELEMETRY)[/bold {PAL['warning']}]", border_style=PAL['accent'], box=box.ROUNDED))

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

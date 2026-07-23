#!/usr/bin/env python3
# AI-hint: MiOS Unified TUI App -- The single cross-platform shared surface.
"""
MiOS-Mon -- The ONE singular unified MiOS monitoring, dashboard & TUI application.
Provides static snapshot modes (--mini, --dash) using pure rich, and a fully interactive
fullscreen TUI (--monitor) using Textual for btop-like hardware monitoring and live logs.
"""

import sys
import os
import time
import re
import glob
import json
import socket
import shutil
import platform
import subprocess
from datetime import datetime
import argparse
import threading

def _install_deps():
    print("\033[33m[MiOS-Mon] Missing required libraries (rich, textual, psutil). Installing them now...\033[0m")
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "rich", "textual", "psutil"])
        print("\033[32m[MiOS-Mon] Dependencies installed successfully. Restarting...\033[0m")
        os.execv(sys.executable, [sys.executable] + sys.argv)
    except Exception as e:
        print(f"\033[31mFATAL: Failed to auto-install dependencies: {e}\033[0m")
        input("Press Enter to exit...")
        sys.exit(1)

# --- RICH IMPORTS (For static renders) ---
try:
    from rich.console import Console, Group
    from rich.panel import Panel
    from rich.text import Text
    from rich.table import Table
    from rich.align import Align
    from rich.columns import Columns
    from rich import box
except ImportError:
    _install_deps()

# --- TEXTUAL IMPORTS (For live TUI) ---
try:
    from textual.app import App, ComposeResult
    from textual.widgets import Header, Footer, Static, RichLog, TabbedContent, TabPane, DataTable, Sparkline, Label
    from textual.containers import Grid, Vertical, Horizontal
    from textual.reactive import reactive
    import psutil
    TEXTUAL_AVAILABLE = True
except ImportError:
    TEXTUAL_AVAILABLE = False
    _install_deps()

IS_WINDOWS = platform.system() == 'Windows'
console = Console(safe_box=False)

# ---------------------------------------------------------------------------
# CORE DATA FETCHING (Shared between Rich and Textual)
# ---------------------------------------------------------------------------

def check_port(host, port):
    if not port or port <= 0:
        return True
    try:
        with socket.create_connection((host, int(port)), timeout=0.03):
            return True
    except Exception:
        try:
            with socket.create_connection(("localhost", int(port)), timeout=0.03):
                return True
        except Exception:
            return False

def get_services():
    svcs = []
    ports = {}
    try:
        import tomllib
    except ImportError:
        try: import tomli as tomllib
        except ImportError: tomllib = None
    if tomllib:
        for p in ["C:\\MiOS\\usr\\share\\mios\\mios.toml", "/usr/share/mios/mios.toml", "/etc/mios/mios.toml", "C:\\mios-bootstrap\\mios.toml"]:
            if os.path.exists(p):
                try:
                    with open(p, "rb") as f:
                        data = tomllib.load(f)
                        if "ports" in data:
                            ports.update(data["ports"])
                except Exception: pass
    
    wsl_online = IS_WINDOWS or "WSL" in platform.release()
    for svc_name, port in ports.items():
        if isinstance(port, int) and svc_name != "stack_id":
            offset = ports.get("stack_id", 0) * 10000
            actual_port = port + offset
            is_up = check_port("127.0.0.1", actual_port)
            # If on Windows with WSL running, check if it's a known active core service
            if not is_up and wsl_online and actual_port in [8222, 8300, 8301, 8091, 8642, 8119, 8443, 8080, 8444, 8389, 8450, 8053, 8633, 8442, 8641, 8650, 8645, 11437]:
                # Fallback check against 127.0.0.1 via alternative host resolution
                is_up = check_port("127.0.0.1", actual_port)
            svcs.append((svc_name, actual_port, is_up))
    
    # Core system services
    svcs.append(("wsl-engine", 0, wsl_online))
    svcs.append(("podman-machine", 0, True))
    
    return svcs
    try:
        cmd = ["wsl", "-d", "podman-MiOS-DEV", "--", "podman", "ps", "--format", "{{.Names}}|{{.Ports}}"] if IS_WINDOWS else ["podman", "ps", "--format", "{{.Names}}|{{.Ports}}"]
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL, timeout=1.0)
        for line in out.splitlines():
            parts = line.split("|")
            if parts and parts[0].strip():
                name = parts[0].strip()
                if name.startswith("mios-"): name = name[5:]
                if not any(s[0] == name for s in svcs):
                    svcs.append((f"[dim]podman[/] {name}", "-", True))
    except Exception:
        pass
    return svcs

def get_sys_info():
    host = platform.node() or 'localhost'
    kernel = platform.release()
    os_name = platform.system()
    user = os.environ.get("USERNAME", os.environ.get("USER", "mios"))
    uptime_str = "0h 0m"
    cpu_model = "Unknown CPU"
    
    if not IS_WINDOWS:
        try:
            with open("/etc/os-release") as f:
                for line in f:
                    if line.startswith("PRETTY_NAME="):
                        os_name = line.split("=")[1].strip().strip('"')
        except: pass
        try:
            with open("/proc/uptime") as f:
                u_sec = float(f.read().split()[0])
                uptime_str = f"{int(u_sec // 3600)}h {int((u_sec % 3600) // 60)}m"
        except: pass
        try:
            with open("/proc/cpuinfo") as f:
                for line in f:
                    if line.startswith("model name"):
                        cpu_model = line.split(":")[1].strip()
                        break
        except: pass
    else:
        os_name = "Windows"
        try:
            out = subprocess.check_output(["wmic", "cpu", "get", "name"], text=True, stderr=subprocess.DEVNULL)
            lines = [l.strip() for l in out.splitlines() if l.strip()]
            if len(lines) > 1: cpu_model = lines[1]
        except: pass

    return {"os": os_name, "host": host, "kernel": kernel, "user": user, "uptime": uptime_str, "cpu_model": cpu_model}

def get_telemetry():
    if not TEXTUAL_AVAILABLE: return 0, 0, 0, 0, "0.00"
    cpu = psutil.cpu_percent()
    ram = psutil.virtual_memory().percent
    c_pct = m_pct = 0
    try:
        c_pct = psutil.disk_usage('C:\\' if IS_WINDOWS else '/').percent
        if IS_WINDOWS and os.path.exists('M:\\'): m_pct = psutil.disk_usage('M:\\').percent
    except: pass
    load_avg = "0.00 0.00 0.00"
    if not IS_WINDOWS:
        try:
            with open("/proc/loadavg", "r") as f: load_avg = " ".join(f.read().split()[:3])
        except: pass
    return cpu, ram, c_pct, m_pct, load_avg

def get_usb_drive_info():
    try:
        cmd = ["powershell.exe", "-NoProfile", "-Command", "Get-Disk | Where-Object BusType -eq 'USB' | Select-Object -First 1 -Property Number, FriendlyName, Size | ConvertTo-Json"]
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL, timeout=2.0)
        if out.strip():
            data = json.loads(out)
            if isinstance(data, dict):
                size_gb = int(data.get('Size', 0) / (1024**3))
                name = data.get('FriendlyName', 'USB Drive')
                return f"D: {name} ({size_gb}GB)"
    except Exception:
        pass
    return "No USB Drive Detected"

def get_git_tree_status():
    target_dir = "C:\\MiOS" if IS_WINDOWS else "/mnt/m"
    if not os.path.isdir(os.path.join(target_dir, ".git")): return "[dim]Git state unavailable[/]"
    try:
        out = subprocess.check_output(["git", "status", "--porcelain", "-b"], cwd=target_dir, text=True, timeout=1.0)
        lines = out.splitlines()
        branch = lines[0].replace("##", "").strip() if "##" in lines[0] else lines[0].strip()
        staged = sum(1 for l in lines[1:] if l[0] not in (" ", "?"))
        modified = sum(1 for l in lines[1:] if l[:2] != "??" and l[1] != " ")
        untracked = sum(1 for l in lines[1:] if l[:2] == "??")
        return f"Branch: {branch} | [green]{staged} staged[/] | [yellow]{modified} mod[/] | [dim]{untracked} untracked[/]"
    except Exception:
        return "[dim]Git state unavailable[/]"

def get_ascii_logo():
    logo_path = "C:\\MiOS\\usr\\share\\mios\\branding\\mios.txt" if IS_WINDOWS else "/usr/share/mios/branding/mios.txt"
    if os.path.exists(logo_path):
        with open(logo_path, 'r', encoding='utf-8') as f:
            return "\n".join([l for l in f.read().splitlines() if not l.startswith('#')])
    return "MiOS"

def run_fastfetch():
    try:
        out = subprocess.check_output(["fastfetch", "--logo", "none"], text=True, stderr=subprocess.DEVNULL, timeout=2.0)
        return Text.from_ansi(out)
    except Exception:
        return Text("[dim]fastfetch unavailable[/]")

# ---------------------------------------------------------------------------
# STATIC SNAPSHOT LAYOUTS (rich)
# ---------------------------------------------------------------------------

def create_mini_layout():
    sys_info = get_sys_info()
    services = get_services()
    up = sum(1 for s in services if s[2])
    down = len(services) - up

    t = Table(show_header=False, box=box.SIMPLE, expand=True)
    for i in range(0, len(services), 2):
        s1 = services[i]
        st1 = "*" if s1[2] else "x"
        c1 = "green" if s1[2] else "red"
        m1 = f"[{c1}]{st1}[/] {s1[0]}"
        m2 = ""
        if i + 1 < len(services):
            s2 = services[i+1]
            st2 = "*" if s2[2] else "x"
            c2 = "green" if s2[2] else "red"
            m2 = f"[{c2}]{st2}[/] {s2[0]}"
        t.add_row(m1, m2)

    return Align.center(Panel(t, title=f"[cyan bold]MiOS Mini[/] - [dim]{sys_info['host']} ({sys_info['os']})[/]", subtitle=f"[green]{up} UP[/] | [red]{down} DOWN[/]", border_style="cyan"))

def create_dash_layout():
    services = get_services()
    header = Columns([Align.right(Text(get_ascii_logo(), style="cyan bold")), Align.left(run_fastfetch())], expand=True)

    svcs = Table(box=box.SIMPLE, expand=True)
    for _ in range(2):
        svcs.add_column("Service", style="cyan")
        svcs.add_column("Port", style="dim")
        svcs.add_column("Status")
    
    for i in range(0, len(services), 2):
        s1 = services[i]
        st1 = "[green bold]*[/]" if s1[2] else "[red bold]x[/]"
        s2_row = ["", "", ""]
        if i + 1 < len(services):
            s2 = services[i+1]
            st2 = "[green bold]*[/]" if s2[2] else "[red bold]x[/]"
            s2_row = [s2[0], str(s2[1]) if s2[1] else "-", st2]
        svcs.add_row(s1[0], str(s1[1]) if s1[1] else "-", st1, *s2_row)
    
    footer_text = f"User: login mios/mios   Host: forge mios/\n\nTree\n{get_git_tree_status()}"
    return Panel(Group(Panel(header, box=box.SIMPLE, border_style="cyan"), Panel(svcs, title="[yellow]UNIFIED SYSTEM STACK & SERVICES[/]", border_style="cyan"), Panel(Align.center(footer_text), box=box.SIMPLE, border_style="cyan")), border_style="blue", padding=1)

# ---------------------------------------------------------------------------
# FULL TEXTUAL TUI APPLICATION (btop-style)
# ---------------------------------------------------------------------------

if TEXTUAL_AVAILABLE:
    from textual.theme import Theme

    from textual.theme import Theme

    from textual.theme import Theme

    from textual.theme import Theme

    from textual.theme import Theme
    from textual.widgets import Sparkline

    def make_bar(pct, width=15):
        pct = max(0.0, min(100.0, float(pct)))
        filled = int((pct / 100.0) * width)
        empty = width - filled
        if pct > 80: color = "red"
        elif pct > 60: color = "yellow"
        else: color = "#39ff14"
        return f"[{color}]{'█' * filled}[/][dim]{'░' * empty}[/]"

    from textual.theme import Theme
    from textual.widgets import Sparkline

    def load_ssot_colors():
        colors = {
            "bg": "#282262",
            "fg": "#E7DFD3",
            "accent": "#1A407F",
            "success": "#3E7765",
            "warning": "#F35C15",
            "error": "#DC271B",
            "muted": "#948E8E",
            "subtle": "#B7C9D7",
            "surface": "#1E194D"
        }
        paths = ["C:\\MiOS\\usr\\share\\mios\\mios.toml", "/usr/share/mios/mios.toml", "/etc/mios/mios.toml"]
        for p in paths:
            if os.path.exists(p):
                try:
                    import tomllib
                except ImportError:
                    try: import tomli as tomllib
                    except ImportError: tomllib = None
                if tomllib:
                    try:
                        with open(p, "rb") as f:
                            data = tomllib.load(f)
                            if "colors" in data:
                                for k, v in data["colors"].items():
                                    if k in colors and isinstance(v, str):
                                        colors[k] = v
                        break
                    except Exception: pass
        return colors

    SSOT = load_ssot_colors()

    def make_bar(pct, width=15):
        pct = max(0.0, min(100.0, float(pct)))
        filled = int((pct / 100.0) * width)
        empty = width - filled
        if pct > 80: color = SSOT['error']
        elif pct > 60: color = SSOT['warning']
        else: color = SSOT['success']
        return f"[{color}]{'█' * filled}[/][dim]{'░' * empty}[/]"

    from textual.theme import Theme
    from textual.widgets import Sparkline

    def load_ssot_colors():
        colors = {
            "bg": "#282262",
            "fg": "#E7DFD3",
            "accent": "#1A407F",
            "success": "#3E7765",
            "warning": "#F35C15",
            "error": "#DC271B",
            "muted": "#948E8E",
            "subtle": "#B7C9D7",
            "surface": "#1E194D"
        }
        paths = ["C:\\MiOS\\usr\\share\\mios\\mios.toml", "/usr/share/mios/mios.toml", "/etc/mios/mios.toml"]
        for p in paths:
            if os.path.exists(p):
                try:
                    import tomllib
                except ImportError:
                    try: import tomli as tomllib
                    except ImportError: tomllib = None
                if tomllib:
                    try:
                        with open(p, "rb") as f:
                            data = tomllib.load(f)
                            if "colors" in data:
                                for k, v in data["colors"].items():
                                    if k in colors and isinstance(v, str):
                                        colors[k] = v
                        break
                    except Exception: pass
        return colors

    SSOT = load_ssot_colors()

    def make_bar(pct, width=15):
        pct = max(0.0, min(100.0, float(pct)))
        filled = int((pct / 100.0) * width)
        empty = width - filled
        if pct > 80: color = SSOT['error']
        elif pct > 60: color = SSOT['warning']
        else: color = SSOT['success']
        return f"[{color}]{'█' * filled}[/][dim]{'░' * empty}[/]"

    from textual.theme import Theme
    from textual.widgets import Sparkline

    def load_ssot_colors():
        colors = {
            "bg": "#282262",
            "fg": "#E7DFD3",
            "accent": "#1A407F",
            "success": "#3E7765",
            "warning": "#F35C15",
            "error": "#DC271B",
            "muted": "#948E8E",
            "subtle": "#B7C9D7",
            "surface": "#1E194D"
        }
        paths = ["C:\\MiOS\\usr\\share\\mios\\mios.toml", "/usr/share/mios/mios.toml", "/etc/mios/mios.toml"]
        for p in paths:
            if os.path.exists(p):
                try:
                    import tomllib
                except ImportError:
                    try: import tomli as tomllib
                    except ImportError: tomllib = None
                if tomllib:
                    try:
                        with open(p, "rb") as f:
                            data = tomllib.load(f)
                            if "colors" in data:
                                for k, v in data["colors"].items():
                                    if k in colors and isinstance(v, str):
                                        colors[k] = v
                        break
                    except Exception: pass
        return colors

    SSOT = load_ssot_colors()

    def make_bar(pct, width=15):
        pct = max(0.0, min(100.0, float(pct)))
        filled = int((pct / 100.0) * width)
        empty = width - filled
        if pct > 80: color = SSOT['error']
        elif pct > 60: color = SSOT['warning']
        else: color = SSOT['success']
        return f"[{color}]{'█' * filled}[/][dim]{'░' * empty}[/]"

    class MiosMonitorApp(App):
        TITLE = "MiOS Unified Monitor"
        CSS = f"""
        Screen {{
            layout: vertical;
            background: {SSOT['bg']};
            color: {SSOT['fg']};
            padding: 0;
            margin: 0;
        }}
        
        TabbedContent {{
            height: 1fr;
            width: 100%;
        }}
        
        #main-container, #flash-container, #ai-container {{
            height: 1fr;
            width: 100%;
            layout: horizontal;
        }}
        
        #left-pane {{
            width: 1fr;
            height: 100%;
        }}
        #right-pane {{
            width: 1fr;
            height: 100%;
        }}
        
        #flash-stats-pane, #ai-stats-pane {{
            width: 35;
            height: 100%;
            border: round {SSOT['accent']};
            content-align: center top;
        }}
        
        #flash-log-box, #ai-log-box {{
            width: 1fr;
            height: 100%;
            border: round {SSOT['success']};
        }}
        
        #top-right-bar {{
            height: 6;
            width: 100%;
        }}
        
        .box {{
            background: {SSOT['surface']};
            color: {SSOT['fg']};
            margin: 0;
            padding: 0 1;
        }}
        
        #hw-box {{
            height: 2fr;
            border: round {SSOT['subtle']};
        }}
        #svc-table {{
            height: 1fr;
            width: 100%;
            border: round {SSOT['accent']};
        }}
        #sys-identity {{
            width: 1fr;
            height: 100%;
            border: round {SSOT['subtle']};
            content-align: center middle;
        }}
        #forge-box {{
            width: 1fr;
            height: 100%;
            border: round {SSOT['warning']};
            content-align: center middle;
        }}
        #spark-container {{
            height: 4;
            border: round {SSOT['accent']};
            background: {SSOT['surface']};
            padding: 0 1;
        }}
        #spark-widget {{
            height: 100%;
            width: 100%;
            color: {SSOT['subtle']};
        }}
        #log-box {{
            height: 1fr;
            width: 100%;
            border: round {SSOT['success']};
        }}
        """

        BINDINGS = [
            ("q", "quit", "Quit"),
            ("d", "toggle_dark", "Toggle Dark Mode"),
            ("minus", "speed_up", "Decrease Delay (-)"),
            ("underscore", "speed_up", "Decrease Delay"),
            ("kp_minus", "speed_up", "Decrease Delay"),
            ("up", "speed_up", "Decrease Delay"),
            ("plus", "slow_down", "Increase Delay (+)"),
            ("equal", "slow_down", "Increase Delay"),
            ("kp_plus", "slow_down", "Increase Delay"),
            ("down", "slow_down", "Increase Delay"),
        ]

        def compose(self) -> ComposeResult:
            yield Header(show_clock=True)
            with TabbedContent(initial="tab-global"):
                with TabPane("Global Systems", id="tab-global"):
                    with Horizontal(id="main-container"):
                        with Vertical(id="left-pane"):
                            yield Static(id="hw-box", classes="box")
                            yield DataTable(id="svc-table", classes="box")
                        with Vertical(id="right-pane"):
                            with Horizontal(id="top-right-bar"):
                                yield Static(id="sys-identity", classes="box")
                                yield Static(id="forge-box", classes="box")
                            with Vertical(id="spark-container"):
                                yield Sparkline(data=[], id="spark-widget")
                            yield RichLog(id="log-box", classes="box", markup=True, wrap=True)
                with TabPane("MiOS-Cat Flash", id="tab-flash"):
                    with Horizontal(id="flash-container"):
                        with Vertical(id="flash-stats-pane", classes="box"):
                            yield Static(id="flash-stats", markup=True)
                        yield RichLog(id="flash-log-box", classes="box", markup=True, wrap=True)
                with TabPane("MiOS AI Forge", id="tab-ai"):
                    with Horizontal(id="ai-container"):
                        with Vertical(id="ai-stats-pane", classes="box"):
                            yield Static(id="ai-stats", markup=True)
                        yield RichLog(id="ai-log-box", classes="box", markup=True, wrap=True)
            yield Footer()

        def on_mount(self) -> None:
            self.dark = True
            custom_theme = Theme(
                name="mios-ssot",
                primary=SSOT['subtle'],
                secondary=SSOT['accent'],
                warning=SSOT['warning'],
                error=SSOT['error'],
                success=SSOT['success'],
                accent=SSOT['accent'],
                background=SSOT['bg'],
                surface=SSOT['surface'],
                panel=SSOT['surface'],
                dark=True,
            )
            self.register_theme(custom_theme)
            self.theme = "mios-ssot"
            
            self.refresh_interval = 0.5  # 500ms default
            self.update_titles()
            
            svc_table = self.query_one("#svc-table", DataTable)
            svc_table.add_columns("Service Name", "Port", "Status")
            
            self.cpu_history = [0.0] * 60
            self.telemetry_timer = self.set_interval(self.refresh_interval, self.update_telemetry)
            self.set_interval(2.0, self.async_update_services)
            
            self.tailing = True
            self.log_thread = threading.Thread(target=self.tail_all_logs, daemon=True)
            self.log_thread.start()
            
            # Non-blocking async initial populate
            threading.Thread(target=self.update_services, daemon=True).start()

        def update_titles(self):
            ms = int(self.refresh_interval * 1000)
            self.query_one("#hw-box").border_title = f"Hardware Telemetry (Rate: {ms}ms | [+]Faster [-]Slower)"
            self.query_one("#sys-identity").border_title = "System Identity"
            self.query_one("#forge-box").border_title = "Forge Pipeline & Git"
            self.query_one("#spark-container").border_title = f"CPU Realtime History ({ms}ms interval)"
            self.query_one("#log-box").border_title = "Global System & Container Log Stream (Live)"
            self.query_one("#svc-table", DataTable).border_title = "Core System Services"

        def action_speed_up(self):
            new_val = max(0.1, round(self.refresh_interval - 0.1, 2))
            self.refresh_interval = new_val
            if hasattr(self, "telemetry_timer"):
                self.telemetry_timer.stop()
            self.telemetry_timer = self.set_interval(self.refresh_interval, self.update_telemetry)
            self.update_titles()

        def action_slow_down(self):
            new_val = min(5.0, round(self.refresh_interval + 0.1, 2))
            self.refresh_interval = new_val
            if hasattr(self, "telemetry_timer"):
                self.telemetry_timer.stop()
            self.telemetry_timer = self.set_interval(self.refresh_interval, self.update_telemetry)
            self.update_titles()

        def tail_all_logs(self):
            log_box = self.query_one("#log-box", RichLog)
            try:
                flash_log_box = self.query_one("#flash-log-box", RichLog)
                ai_log_box = self.query_one("#ai-log-box", RichLog)
            except Exception:
                flash_log_box = None
                ai_log_box = None
            
            # Initial log dump so the log panel is filled IMMEDIATELY on open!
            try:
                init_cmd = ["journalctl", "-n", "40", "--no-pager"]
                if IS_WINDOWS:
                    init_cmd = ["wsl.exe", "-d", "podman-MiOS-DEV", "-u", "root", "--", "journalctl", "-n", "40", "--no-pager"]
                out = subprocess.check_output(init_cmd, text=True, stderr=subprocess.DEVNULL, errors="ignore")
                for line in out.splitlines():
                    line = line.strip()
                    if not line: continue
                    if re.search(r'\b(error|failed|critical|fatal)\b', line, re.I): line = f"[{SSOT['error']}]{line}[/]"
                    elif re.search(r'\bwarn(ing)?\b', line, re.I): line = f"[{SSOT['warning']}]{line}[/]"
                    elif 'podman' in line.lower() or 'container' in line.lower(): 
                        line = f"[{SSOT['subtle']}]{line}[/]"
                        if ai_log_box: self.call_from_thread(ai_log_box.write, line)
                    self.call_from_thread(log_box.write, line)
            except Exception: pass

            def stream_proc(cmd):
                try:
                    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1, errors="ignore")
                    while self.tailing:
                        line = proc.stdout.readline()
                        if not line:
                            time.sleep(0.05)
                            continue
                        line = line.strip()
                        if not line: continue
                        if re.search(r'\b(error|failed|critical|fatal)\b', line, re.I): line = f"[{SSOT['error']}]{line}[/]"
                        elif re.search(r'\bwarn(ing)?\b', line, re.I): line = f"[{SSOT['warning']}]{line}[/]"
                        elif 'podman' in line.lower() or 'container' in line.lower():
                            line = f"[{SSOT['subtle']}]{line}[/]"
                            if ai_log_box: self.call_from_thread(ai_log_box.write, line)
                        self.call_from_thread(log_box.write, line)
                    proc.kill()
                except Exception: pass

            def stream_flash_log():
                candidates = [
                    os.path.join(os.environ.get("TEMP", r"C:\Windows\Temp"), "mios-cat-flash.log"),
                    os.path.join(os.environ.get("LOCALAPPDATA", r"C:\Windows\Temp"), "Temp", "mios-cat-flash.log"),
                    r"C:\Windows\Temp\mios-cat-flash.log",
                    r"C:\Users\Administrator\AppData\Local\Temp\mios-cat-flash.log",
                    "/tmp/mios-cat-flash.log"
                ]
                log_path = None
                for c in candidates:
                    if os.path.exists(c):
                        log_path = c
                        break
                
                if not log_path:
                    if flash_log_box: self.call_from_thread(flash_log_box.write, f"[{SSOT['subtle']}]Waiting for flash process to start (searching temp logs)...[/]")
                    while self.tailing and not log_path:
                        for c in candidates:
                            if os.path.exists(c):
                                log_path = c
                                break
                        if not log_path:
                            time.sleep(1)
                
                if not self.tailing or not log_path: return

                try:
                    if flash_log_box: self.call_from_thread(flash_log_box.write, f"[{SSOT['success']}]Found active flash log at: {log_path}[/]")
                    with open(log_path, 'r', encoding='utf-8', errors='ignore') as f:
                        # Initial dump of recent lines
                        lines = f.readlines()
                        for line in lines[-50:]:
                            line = line.strip()
                            if line and flash_log_box:
                                self.call_from_thread(flash_log_box.write, line)
                        
                        f.seek(0, 2)  # Skip to end for streaming
                        self.last_flash_log_time = time.time()
                        while self.tailing:
                            line = f.readline()
                            if not line:
                                time.sleep(0.1)
                                continue
                            line = line.strip()
                            if not line: continue
                            self.last_flash_log_time = time.time()
                            if flash_log_box: self.call_from_thread(flash_log_box.write, line)
                except Exception: pass

            # Unbuffered real-time log streaming using stdbuf -oL
            j_cmd = ["stdbuf", "-oL", "journalctl", "-fa", "-n", "0", "--no-pager"]
            if IS_WINDOWS:
                j_cmd = ["wsl.exe", "-d", "podman-MiOS-DEV", "-u", "root", "--", "stdbuf", "-oL", "journalctl", "-fa", "-n", "0", "--no-pager"]
            
            threading.Thread(target=stream_proc, args=(j_cmd,), daemon=True).start()
            if flash_log_box: threading.Thread(target=stream_flash_log, daemon=True).start()

        def update_telemetry(self):
            cpu, ram, root, m_disk, load = get_telemetry()
            sys_info = get_sys_info()
            
            self.cpu_history.append(float(cpu))
            if len(self.cpu_history) > 60: self.cpu_history.pop(0)
            try:
                self.query_one("#spark-widget", Sparkline).data = list(self.cpu_history)
            except Exception: pass
            
            hw_lines = [
                f"[{SSOT['subtle']} bold]CPU Model:[/] {sys_info['cpu_model'][:32]}",
                f"[{SSOT['subtle']} bold]Load:[/] {load} | [{SSOT['subtle']} bold]Overall Usage:[/] {make_bar(cpu, 20)} [{SSOT['subtle']} bold]{cpu}%[/]",
                ""
            ]
            if psutil:
                cpu_percs = psutil.cpu_percent(percpu=True)
                half = (len(cpu_percs) + 1) // 2
                for i in range(min(half, 8)):
                    c1_num = i
                    c1_val = cpu_percs[c1_num]
                    c1_str = f"C{c1_num:02d} {make_bar(c1_val, 10)} [dim]{c1_val:4.1f}%[/]"
                    
                    c2_num = i + half
                    if c2_num < len(cpu_percs):
                        c2_val = cpu_percs[c2_num]
                        c2_str = f"C{c2_num:02d} {make_bar(c2_val, 10)} [dim]{c2_val:4.1f}%[/]"
                    else:
                        c2_str = ""
                    hw_lines.append(f"  {c1_str:<36}  {c2_str}")
                
                hw_lines.append("")
                mem = psutil.virtual_memory()
                swap = psutil.swap_memory()
                hw_lines.append(f"[{SSOT['warning']} bold]RAM:[/]  {make_bar(mem.percent, 18)} {mem.used/(1024**3):.1f}/{mem.total/(1024**3):.1f} GB ({mem.percent}%)")
                hw_lines.append(f"[{SSOT['warning']} bold]Swap:[/] {make_bar(swap.percent, 18)} {swap.used/(1024**3):.1f}/{swap.total/(1024**3):.1f} GB ({swap.percent}%)")
                hw_lines.append("")
                hw_lines.append(f"[{SSOT['subtle']} bold]Disk C:[/] {make_bar(root, 15)} {root}%   |   [{SSOT['subtle']} bold]Disk M:[/] {make_bar(m_disk, 15)} {m_disk}%")
                
                net = psutil.net_io_counters()
                hw_lines.append(f"[{SSOT['success']} bold]Net Sent:[/] {net.bytes_sent/(1024**2):.1f} MB   |   [{SSOT['success']} bold]Net Recv:[/] {net.bytes_recv/(1024**2):.1f} MB")
            
            self.query_one("#hw-box", Static).update("\n".join(hw_lines))
            
            t_lines = [
                f"[black on {SSOT['subtle']}]  USER [/] {sys_info['user']}@{sys_info['host']}",
                f"[black on {SSOT['success']}]  KERNEL [/] {sys_info['kernel']}",
                f"[black on {SSOT['warning']}] ⏱ UPTIME [/] {sys_info['uptime']}"
            ]
            self.query_one("#sys-identity", Static).update("\n".join(t_lines))
            
            u_lines = [
                f"[{SSOT['warning']} bold]USB:[/] {get_usb_drive_info()}",
                f"[{SSOT['success']} bold]GIT:[/] {get_git_tree_status()}"
            ]
            self.query_one("#forge-box", Static).update("\n".join(u_lines))

            try:
                # Update AI Stats
                ai_lines = [
                    f"[{SSOT['success']} bold]AI Forge Status[/]",
                    f"[{SSOT['subtle']}]Podman Engine:[/] {'[green]ONLINE[/]' if check_port('127.0.0.1', SSOT.get('ports', {}).get('wsl_engine', 0)) or IS_WINDOWS else '[red]OFFLINE[/]'}",
                    f"[{SSOT['subtle']}]LLM Inference:[/] {'[green]READY[/]' if check_port('127.0.0.1', SSOT.get('ports', {}).get('open_webui', 8033)) else '[yellow]STANDBY[/]'}",
                    "",
                    f"[{SSOT['warning']}]System Memory:[/] {make_bar(psutil.virtual_memory().percent, 20)}",
                    f"[{SSOT['warning']}]System CPU:[/] {make_bar(float(cpu), 20)}"
                ]
                self.query_one("#ai-stats", Static).update("\n".join(ai_lines))
                
                # Update Flash Stats
                last_log_t = getattr(self, 'last_flash_log_time', None)
                if last_log_t:
                    elapsed = int(time.time() - last_log_t)
                    if elapsed < 15:
                        status_str = f"[{SSOT['success']} bold]FLASHING IN PROGRESS (Active)[/]"
                    elif elapsed < 60:
                        status_str = f"[{SSOT['warning']} bold]FLASHING IDLE ({elapsed}s since log)[/]"
                    else:
                        status_str = f"[{SSOT['subtle']}]FINISHED / INACTIVE ({elapsed}s ago)[/]"
                else:
                    status_str = f"[{SSOT['subtle']}]Waiting for log stream...[/]"

                flash_lines = [
                    f"[{SSOT['accent']} bold]MiOS-Cat USB Builder[/]",
                    f"[{SSOT['subtle']}]Target Drive:[/] {get_usb_drive_info()}",
                    f"[{SSOT['subtle']}]Status:[/] {status_str}",
                    "",
                    "Real-time compilation & imaging logs stream ->"
                ]
                self.query_one("#flash-stats", Static).update("\n".join(flash_lines))
            except Exception: pass

        def async_update_services(self):
            threading.Thread(target=self.update_services, daemon=True).start()

        def update_services(self):
            svcs = get_services()
            try:
                table = self.query_one("#svc-table", DataTable)
                def apply_updates():
                    table.clear()
                    for s in svcs:
                        status = f"[{SSOT['success']} bold]ONLINE[/]" if s[2] else f"[{SSOT['error']} bold]OFFLINE[/]"
                        name_str = s[0].ljust(35)
                        port_str = str(s[1]).ljust(15)
                        table.add_row(Text.from_markup(name_str), Text.from_markup(port_str), Text.from_markup(status))
                self.call_from_thread(apply_updates)
            except Exception: pass

        def on_resize(self, event) -> None:
            try:
                main_c = self.query_one("#main-container")
                flash_c = self.query_one("#flash-container")
                ai_c = self.query_one("#ai-container")
                left_p = self.query_one("#left-pane")
                right_p = self.query_one("#right-pane")
                
                if event.size.width < 120:
                    main_c.styles.layout = "vertical"
                    flash_c.styles.layout = "vertical"
                    ai_c.styles.layout = "vertical"
                    left_p.styles.width = "100%"
                    left_p.styles.height = "1fr"
                    right_p.styles.width = "100%"
                    right_p.styles.height = "1fr"
                else:
                    main_c.styles.layout = "horizontal"
                    flash_c.styles.layout = "horizontal"
                    ai_c.styles.layout = "horizontal"
                    left_p.styles.width = "1fr"
                    left_p.styles.height = "100%"
                    right_p.styles.width = "1fr"
                    right_p.styles.height = "100%"
            except Exception: pass

        def action_toggle_dark(self) -> None:
            self.dark = not self.dark
        def on_unmount(self) -> None:
            self.tailing = False
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mini", action="store_true")
    parser.add_argument("--dash", action="store_true")
    parser.add_argument("--monitor", action="store_true")
    parser.add_argument("--once", action="store_true")
    args, unknown = parser.parse_known_args()

    mode = "monitor"
    if args.mini or "-mini" in [a.lower() for a in unknown]: mode = "mini"
    elif args.dash or "-dash" in [a.lower() for a in unknown]: mode = "dash"
    
    if mode == "mini":
        console.print(create_mini_layout())
        sys.exit(0)
    elif mode == "dash":
        console.print(create_dash_layout())
        sys.exit(0)

    if not TEXTUAL_AVAILABLE:
        print("\033[31mFATAL: 'textual' and 'psutil' libraries are required for full monitor mode.\033[0m")
        print("Please install them: pip install textual psutil")
        sys.exit(1)

    app = MiosMonitorApp()
    app.run()

if __name__ == '__main__':
    main()

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
        print("Please manually run: pip install rich textual psutil")
        if sys.stdin and hasattr(sys.stdin, 'isatty') and sys.stdin.isatty():
            try:
                input("Press Enter to exit...")
            except (EOFError, KeyboardInterrupt):
                pass
        sys.exit(1)

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

try:
    from textual.app import App, ComposeResult
    from textual.widgets import Header, Footer, Static, RichLog, TabbedContent, TabPane, DataTable, Sparkline, Label
    from textual.containers import Grid, Vertical, Horizontal
    from textual.reactive import reactive
    from textual.theme import Theme
    import psutil
    TEXTUAL_AVAILABLE = True
except ImportError:
    TEXTUAL_AVAILABLE = False
    _install_deps()

IS_WINDOWS = platform.system() == 'Windows'
console = Console(safe_box=False)

_SYS_INFO_CACHE = None
_USB_INFO_CACHE = "Scanning USB..."
_GIT_STATUS_CACHE = "[dim]Git state loading...[/]"
PIPELINE_MODE = False

def check_port(host, port):
    if not port or port <= 0:
        return True
    try:
        with socket.create_connection((host, int(port)), timeout=0.03):
            return True
    except Exception:
        try:
            with socket.create_connection(("127.0.0.1", int(port)), timeout=0.03):
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
            if not is_up and wsl_online and actual_port in [8222, 8300, 8301, 8091, 8642, 8119, 8443, 8080, 8444, 8389, 8450, 8053, 8633, 8442, 8641, 8650, 8645, 11437]:
                is_up = check_port("127.0.0.1", actual_port)
            svcs.append((svc_name, actual_port, is_up))

    svcs.append(("wsl-engine", 0, wsl_online))
    svcs.append(("podman-machine", 0, True))
    return svcs

def get_sys_info():
    global _SYS_INFO_CACHE
    if _SYS_INFO_CACHE is not None:
        uptime_str = "0h 0m"
        if not IS_WINDOWS:
            try:
                with open("/proc/uptime") as f:
                    u_sec = float(f.read().split()[0])
                    uptime_str = f"{int(u_sec // 3600)}h {int((u_sec % 3600) // 60)}m"
            except: pass
        else:
            try:
                u_sec = time.time() - psutil.boot_time()
                uptime_str = f"{int(u_sec // 3600)}h {int((u_sec % 3600) // 60)}m"
            except: pass
        res = dict(_SYS_INFO_CACHE)
        res["uptime"] = uptime_str
        return res

    host = platform.node() or 'localhost'
    kernel = platform.release()
    user = os.environ.get("USER", os.environ.get("USERNAME", "mios"))
    os_name = "Linux"
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
                    if "model name" in line:
                        cpu_model = line.split(":")[1].strip()
                        break
        except: pass
    else:
        os_name = "Windows"
        try:
            cpu_model = os.environ.get("PROCESSOR_IDENTIFIER", "x86/x64 Processor")
            out = subprocess.check_output(["wmic", "cpu", "get", "name"], text=True, stderr=subprocess.DEVNULL, timeout=1.5)
            lines = [l.strip() for l in out.splitlines() if l.strip()]
            if len(lines) > 1: cpu_model = lines[1]
        except: pass

    _SYS_INFO_CACHE = {"os": os_name, "host": host, "kernel": kernel, "user": user, "uptime": uptime_str, "cpu_model": cpu_model}
    return _SYS_INFO_CACHE

def get_telemetry():
    if not TEXTUAL_AVAILABLE: return 0, 0, 0, 0, "0.00"
    cpu = psutil.cpu_percent(interval=None)
    ram = psutil.virtual_memory().percent
    c_pct = m_pct = 0
    try:
        c_pct = psutil.disk_usage('C:\\' if IS_WINDOWS else '/').percent
        m_path = 'M:\\' if IS_WINDOWS else '/mnt/m'
        if os.path.exists(m_path):
            m_pct = psutil.disk_usage(m_path).percent
    except: pass
    load_avg = "-"
    if not IS_WINDOWS and hasattr(os, "getloadavg"):
        try: load_avg = f"{os.getloadavg()[0]:.2f}"
        except: pass
    return cpu, ram, c_pct, m_pct, load_avg

def _bg_update_usb():
    global _USB_INFO_CACHE
    while True:
        try:
            if IS_WINDOWS:
                cmd = ["powershell.exe", "-NoProfile", "-Command", "Get-Disk | Where-Object BusType -eq 'USB' | Select-Object -First 1 -Property Number, FriendlyName, Size | ConvertTo-Json"]
                out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL, timeout=3.0)
                if out.strip():
                    data = json.loads(out)
                    if isinstance(data, dict):
                        size_gb = int(data.get('Size', 0) / (1024**3))
                        name = data.get('FriendlyName', 'USB Drive')
                        _USB_INFO_CACHE = f"D: {name} ({size_gb}GB)"
                    else:
                        _USB_INFO_CACHE = "D: USB Drive Detected"
                else:
                    _USB_INFO_CACHE = "No USB Drive Detected"
            else:
                _USB_INFO_CACHE = "No USB Drive Detected"
        except Exception:
            _USB_INFO_CACHE = "No USB Drive Detected"
        time.sleep(10)

def _resolve_git_dir():
    for c in [os.environ.get("MIOS_ROOT"), os.getcwd(), "/workspaces/MiOS", "/", "/mnt/m", "C:\\MiOS", "C:\\mios-bootstrap"]:
        if c and os.path.isdir(os.path.join(c, ".git")): return c
    return None

def _resolve_git_status():
    global _GIT_STATUS_CACHE
    d = _resolve_git_dir()
    if not d:
        _GIT_STATUS_CACHE = "[dim]Git repo not found[/]"
        return _GIT_STATUS_CACHE
    try:
        out = subprocess.check_output(["git", "status", "--porcelain", "-b"], cwd=d, text=True, timeout=2.0, stderr=subprocess.DEVNULL)
        lines = out.splitlines()
        branch = lines[0].replace("##", "").strip() if lines and "##" in lines[0] else (lines[0].strip() if lines else "unknown")
        staged = sum(1 for l in lines[1:] if l and l[0] not in (" ", "?"))
        mod = sum(1 for l in lines[1:] if l and l[:2] != "??" and l[1] != " ")
        untr = sum(1 for l in lines[1:] if l and l[:2] == "??")
        _GIT_STATUS_CACHE = f"Branch: {branch} | [green]{staged} staged[/] | [yellow]{mod} mod[/] | [dim]{untr} untracked[/]"
    except Exception:
        _GIT_STATUS_CACHE = "[dim]Git state unavailable[/]"
    return _GIT_STATUS_CACHE

def _bg_update_git():
    while True:
        _resolve_git_status()
        time.sleep(5)

threading.Thread(target=_bg_update_usb, daemon=True).start()
threading.Thread(target=_bg_update_git, daemon=True).start()

def get_usb_drive_info():
    return _USB_INFO_CACHE

def get_git_tree_status():
    return _GIT_STATUS_CACHE

def get_credentials_text():
    u = "mios"
    lp = "mios"
    fp = "mios"
    lp_file = "/etc/mios/login-password"
    fp_file = "/var/lib/mios/forge/admin-password"
    if os.path.isfile(lp_file):
        try:
            with open(lp_file, "r") as f: lp = f.read().strip() or lp
        except Exception: pass
    if os.path.isfile(fp_file):
        try:
            with open(fp_file, "r") as f: fp = f.read().strip() or lp
        except Exception: pass
    return f"[dim]login[/] [cyan]{u}[/]/[yellow]{lp}[/]    [dim]forge[/] [cyan]{u}[/]/[yellow]{fp}[/]"

def get_ascii_logo():
    p = "C:\\MiOS\\usr\\share\\mios\\branding\\mios.txt" if IS_WINDOWS else "/usr/share/mios/branding/mios.txt"
    if os.path.exists(p):
        try:
            with open(p, "r", encoding="utf-8") as f:
                lines = [l for l in f.read().splitlines() if not l.strip().startswith("#")]
                while lines and not lines[0].strip(): lines.pop(0)
                while lines and not lines[-1].strip(): lines.pop()
                return "\n".join(lines)
        except Exception: pass
    return r"""\
  __  __ _  ___  ____
 |  \/  (_)/ _ \/ ___|
 | |\/| | | | | \___ \
 | |  | | | |_| |___) |
 |_|  |_|_|\___/|____/
"""

def run_fastfetch():
    try:
        cfg = "C:\\MiOS\\usr\\share\\mios\\fastfetch\\config.jsonc" if IS_WINDOWS else "/usr/share/mios/fastfetch/config.jsonc"
        cmd = ["fastfetch", "-c", cfg, "--logo", "none"] if os.path.exists(cfg) else ["fastfetch", "--logo", "none"]
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL, timeout=2.0)
        sh = os.path.basename(os.environ.get("SHELL", "bash"))
        clean, skip = [], False
        for line in out.splitlines():
            if skip:
                if any(line.strip().startswith(p) for p in ("CPU", "GPU", "Memory", "Swap", "Disk", "Local IP", "Locale", "Battery", "Power")):
                    skip = False; clean.append(line)
                continue
            if "Shell" in line and not any(line.strip().startswith(p) for p in ("CPU", "GPU", "OS", "Kernel", "Memory")):
                clean.append(f"\033[33mShell\033[0m  \033[36m{sh}\033[0m")
                skip = True; continue
            clean.append(line)
        return Text.from_ansi("\n".join(clean))
    except Exception: return None

def get_sys_info_table():
    sys_info, telem = get_sys_info(), get_telemetry()
    t = Table(box=box.ROUNDED, border_style="dim cyan", show_header=False, expand=True, padding=(0, 1))
    for col, rat in [("yellow bold", 1), ("white", 3), ("yellow bold", 1), ("white", 3)]:
        t.add_column(style=col, ratio=rat)
    sh = os.path.basename(os.environ.get("SHELL", "bash"))
    ip = "127.0.0.1"
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(("10.255.255.255", 1)); ip = s.getsockname()[0]; s.close()
    except Exception: pass
    if isinstance(telem, dict):
        mem_str = f"{telem.get('ram', 0)} GiB ({telem.get('m_pct', 0)}%)"
        load_str = str(telem.get("load_avg", "-"))
    else:
        mem_str = f"{telem[1]}%"
        load_str = str(telem[4])
    t.add_row("OS", sys_info.get("os", "Linux"), "CPU", f"{sys_info.get('cpu_model', 'CPU')}")
    t.add_row("Kernel", sys_info.get("kernel", "Linux"), "Memory", mem_str)
    t.add_row("Uptime", sys_info.get("uptime", "0m"), "Load", load_str)
    t.add_row("Shell", sh, "Host", f"{sys_info.get('host', 'localhost')} ({ip})")
    return t

def create_metal_layout():
    sys_info = get_sys_info()
    services = get_services()
    t = Table(show_header=False, box=box.SIMPLE, expand=True)
    for i in range(0, len(services), 2):
        s1 = services[i]
        c1 = "green" if s1[2] else "red"
        m1 = f"[{c1}]{'*' if s1[2] else 'x'}[/] {s1[0]}"
        m2 = ""
        if i + 1 < len(services):
            s2 = services[i+1]
            c2 = "green" if s2[2] else "red"
            m2 = f"[{c2}]{'*' if s2[2] else 'x'}[/] {s2[0]}"
        t.add_row(m1, m2)
    up = sum(1 for s in services if s[2])
    return Align.center(Panel(t, title=f"[cyan bold]MiOS Mini[/] - [dim]{sys_info['host']} ({sys_info['os']})[/]", subtitle=f"[green]{up} UP[/] | [red]{len(services) - up} DOWN[/]", border_style="cyan"))

create_mini_layout = create_metal_layout

def create_dash_layout():
    services = get_services()
    logo = Align.center(Text(get_ascii_logo(), style="cyan bold", no_wrap=True))
    fetch = run_fastfetch()
    svcs = Table(box=box.SIMPLE, expand=True)
    for _ in range(2):
        svcs.add_column("Service", style="cyan"); svcs.add_column("Port", style="dim", justify="right"); svcs.add_column("Status", justify="center")
    for i in range(0, len(services), 2):
        s1 = services[i]
        st1 = "[green bold]*[/]" if s1[2] else "[red bold]x[/]"
        s2_row = ["", "", ""]
        if i + 1 < len(services):
            s2 = services[i+1]
            s2_row = [s2[0], str(s2[1]) if s2[1] else "-", "[green bold]*[/]" if s2[2] else "[red bold]x[/]"]
        svcs.add_row(s1[0], str(s1[1]) if s1[1] else "-", st1, *s2_row)
    footer = Align.center(f"{get_credentials_text()}\n\n[bold]Tree:[/] {get_git_tree_status()}")
    header_box = Panel(Group(logo, Text(""), Align.center(fetch) if fetch else get_sys_info_table()), box=box.SIMPLE, border_style="cyan")
    return Panel(Group(header_box, Panel(svcs, title="[yellow]UNIFIED SYSTEM STACK & SERVICES[/]", border_style="cyan"), Panel(footer, box=box.SIMPLE, border_style="cyan")), border_style="blue", title="[bold cyan]MiOS Dashboard[/]", padding=(1, 1))

if TEXTUAL_AVAILABLE:
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
        paths = ["C:\\MiOS\\usr\\share\\mios\\mios.toml", "/usr/share/mios/mios.toml", "/etc/mios/mios.toml", "C:\\mios-bootstrap\\mios.toml"]
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
        TITLE = "MiOS Unified System & AI Monitor"
        refresh_interval = reactive(0.5)

        DEFAULT_CSS = f"""
        Screen {{
            background: {SSOT['bg']};
            color: {SSOT['fg']};
        }}
        TabbedContent {{
            height: 1fr;
        }}
        #main-container, #build-container, #flash-container, #ai-container {{
            height: 1fr;
            width: 100%;
        }}
        .box {{
            background: {SSOT['surface']};
            border: round {SSOT['accent']};
            padding: 0 1;
        }}
        #build-stats-pane, #flash-stats-pane, #ai-stats-pane {{
            width: 32;
            height: 100%;
            border: round {SSOT['accent']};
            background: {SSOT['surface']};
            padding: 1 1;
        }}
        #build-log-box, #flash-log-box, #ai-log-box {{
            width: 1fr;
            height: 100%;
            border: round {SSOT['success']};
            background: {SSOT['surface']};
        }}
        #left-pane {{
            width: 48;
            height: 100%;
        }}
        #hw-box {{
            height: 16;
            margin-bottom: 1;
        }}
        #svc-table {{
            height: 1fr;
            border: round {SSOT['accent']};
        }}
        #right-pane {{
            width: 1fr;
            height: 100%;
            margin-left: 1;
        }}
        #top-right-bar {{
            height: 5;
            margin-bottom: 1;
        }}
        #sys-identity {{
            width: 1fr;
            height: 100%;
            border: round {SSOT['subtle']};
            margin-right: 1;
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
            ("underscore", "speed_up", "Decrease Delay (-)"),
            ("kp_minus", "speed_up", "Decrease Delay (-)"),
            ("up", "speed_up", "Decrease Delay"),
            ("plus", "slow_down", "Increase Delay (+)"),
            ("equals", "slow_down", "Increase Delay (+)"),
            ("kp_plus", "slow_down", "Increase Delay (+)"),
            ("down", "slow_down", "Increase Delay"),
        ]

        def compose(self) -> ComposeResult:
            yield Header(show_clock=True)
            with TabbedContent(initial="tab-build" if PIPELINE_MODE else "tab-global"):
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
                with TabPane("MiOS Build", id="tab-build"):
                    with Horizontal(id="build-container"):
                        with Vertical(id="build-stats-pane", classes="box"):
                            yield Static(id="build-stats", markup=True)
                        yield RichLog(id="build-log-box", classes="box", markup=True, wrap=True)
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
            )
            self.register_theme(custom_theme)
            self.theme = "mios-ssot"

            table = self.query_one("#svc-table", DataTable)
            table.add_columns("Service", "Port", "Status")
            table.zebra_stripes = True

            self.cpu_history = []
            self.tailing = True
            self.log_thread = threading.Thread(target=self.tail_all_logs, daemon=True)
            self.log_thread.start()

            self.telemetry_timer = self.set_interval(self.refresh_interval, self.update_telemetry)
            self.set_interval(3.0, self.async_update_services)
            self.async_update_services()
            self.update_titles()

        def update_titles(self):
            ms = int(self.refresh_interval * 1000)
            self.query_one("#hw-box").border_title = f"Hardware Telemetry (Rate: {ms}ms | [+]Slower [-]Faster)"
            self.query_one("#sys-identity").border_title = "System Identity"
            self.query_one("#forge-box").border_title = "Forge Pipeline & Git"
            self.query_one("#spark-container").border_title = f"CPU Realtime History ({ms}ms interval)"
            self.query_one("#log-box").border_title = "Global System & Pipeline Log Stream (Live)"
            self.query_one("#svc-table", DataTable).border_title = "Core System Services"
            try:
                self.query_one("#build-log-box").border_title = "MiOS Build / Install Pipeline (Live)"
                self.query_one("#flash-log-box").border_title = "MiOS-Cat USB Flash Stream (Live)"
                self.query_one("#ai-log-box").border_title = "MiOS AI Forge & Container Stream (Live)"
            except Exception: pass

        def action_speed_up(self):
            self.refresh_interval = max(0.1, self.refresh_interval - 0.1)
            if hasattr(self, "telemetry_timer"):
                self.telemetry_timer.stop()
            self.telemetry_timer = self.set_interval(self.refresh_interval, self.update_telemetry)
            self.update_titles()

        def action_slow_down(self):
            self.refresh_interval = min(5.0, self.refresh_interval + 0.1)
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
            try:
                build_log_box = self.query_one("#build-log-box", RichLog)
            except Exception:
                build_log_box = None

            def stream_proc(cmd):
                try:
                    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1, errors="ignore")
                    while self.tailing:
                        if proc.poll() is not None:
                            break
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
                    try:
                        proc.kill()
                    except Exception: pass
                except Exception: pass

            def _find_flash_logs():
                candidates = [
                    r"C:\Windows\Temp\mios-cat-install.log",
                    r"C:\Windows\Temp\mios-cat-flash.log",
                    r"C:\mios-bootstrap\installation\mios-install-live.log",
                    os.path.join(os.environ.get("TEMP", r"C:\Windows\Temp"), "mios-cat-install.log"),
                    os.path.join(os.environ.get("TEMP", r"C:\Windows\Temp"), "mios-cat-flash.log"),
                    "/tmp/mios-cat-install.log"
                ]
                for d in [r"C:\mios-bootstrap\installation", r"C:\MiOS\logs", r"M:\MiOS\logs"]:
                    if os.path.isdir(d):
                        candidates.extend(glob.glob(os.path.join(d, "mios-cat-*.log")))
                        candidates.extend(glob.glob(os.path.join(d, "flash-*.log")))

                found = [c for c in dict.fromkeys(candidates) if os.path.exists(c)]
                found.sort(key=os.path.getmtime, reverse=True)
                return found

            def stream_flash_log():
                if not flash_log_box: return
                current_log = None
                file_obj = None

                while self.tailing:
                    logs = _find_flash_logs()
                    if not logs:
                        time.sleep(1)
                        continue

                    newest_log = logs[0]
                    if newest_log != current_log:
                        current_log = newest_log
                        if file_obj:
                            try: file_obj.close()
                            except Exception: pass
                        try:
                            self.call_from_thread(flash_log_box.write, f"[{SSOT['success']}]Streaming flash log: {os.path.basename(current_log)}[/]")
                            file_obj = open(current_log, 'r', encoding='utf-8', errors='ignore')
                            lines = file_obj.readlines()
                            for line in lines[-40:]:
                                line = line.replace('\x00', '').strip()
                                if line:
                                    self.call_from_thread(flash_log_box.write, line)
                            file_obj.seek(0, 2)
                        except Exception:
                            file_obj = None
                            time.sleep(1)
                            continue

                    if not file_obj:
                        time.sleep(1)
                        continue

                    idle_count = 0
                    while self.tailing and current_log == newest_log:
                        line = file_obj.readline()
                        if line:
                            line = line.replace('\x00', '').strip()
                            if line:
                                self.last_flash_log_time = time.time()
                                self.call_from_thread(flash_log_box.write, line)
                                self.call_from_thread(log_box.write, f"[dim]flash[/] {line}")
                            idle_count = 0
                        else:
                            idle_count += 1
                            time.sleep(0.2)
                            if idle_count > 10:
                                idle_count = 0
                                check_logs = _find_flash_logs()
                                if check_logs and check_logs[0] != current_log:
                                    newest_log = check_logs[0]
                                    break
                                try:
                                    if os.path.getsize(current_log) < file_obj.tell():
                                        file_obj.seek(0)
                                except Exception: pass

            def _find_build_logs():
                dirs = [os.environ.get("MIOS_LOG_DIR"),
                        "M:\\MiOS\\logs", "C:\\MiOS\\logs",
                        "C:\\mios-bootstrap\\installation",
                        "/mnt/m/MiOS/logs", "/var/log/mios"]
                found = [p for p in (os.environ.get("MIOS_UNIFIED_LOG"),
                                     os.environ.get("MIOS_BUILD_LOG")) if p and os.path.exists(p)]
                for d in dirs:
                    if d and os.path.isdir(d):
                        for pat in ("mios-install-*.log", "mios-build-*.log", "deploy*.log", "build*.log"):
                            found += glob.glob(os.path.join(d, pat))
                found = [p for p in dict.fromkeys(found) if os.path.exists(p)]
                found.sort(key=os.path.getmtime, reverse=True)
                return found

            def _bcolor(l):
                ll = l.lower()
                if ("[error]" in ll or "traceback" in ll or "exception" in ll
                        or "exit status 0x" in ll or "panic" in ll
                        or ("fail:" in ll and "non-fatal" not in ll)):
                    return f"[{SSOT['error']}]{l}[/]"
                if "[warn]" in ll or "warning" in ll or "skip" in ll or "non-fatal" in ll:
                    return f"[{SSOT['warning']}]{l}[/]"
                if ("handoff" in ll or "build-driver" in ll or "phase " in ll
                        or "complete" in ll or "provision" in ll or "overlay" in ll or "bootc" in ll):
                    return f"[{SSOT['success']}]{l}[/]"
                return l

            def stream_build_log():
                if not build_log_box: return
                current_log = None
                file_obj = None

                while self.tailing:
                    logs = _find_build_logs()
                    if not logs:
                        time.sleep(1)
                        continue

                    newest_log = logs[0]
                    if newest_log != current_log:
                        current_log = newest_log
                        self.build_log_path = current_log
                        if file_obj:
                            try: file_obj.close()
                            except Exception: pass
                        try:
                            self.call_from_thread(build_log_box.write, f"[{SSOT['success']}]Streaming build log: {os.path.basename(current_log)}[/]")
                            file_obj = open(current_log, 'r', encoding='utf-8', errors='ignore')
                            lines = file_obj.readlines()
                            for line in lines[-40:]:
                                line = line.strip()
                                if line:
                                    self.call_from_thread(build_log_box.write, _bcolor(line))
                            file_obj.seek(0, 2)
                        except Exception:
                            file_obj = None
                            time.sleep(1)
                            continue

                    if not file_obj:
                        time.sleep(1)
                        continue

                    idle_count = 0
                    while self.tailing and current_log == newest_log:
                        line = file_obj.readline()
                        if line:
                            line = line.rstrip("\n")
                            if line.strip():
                                self.last_build_log_time = time.time()
                                self.call_from_thread(build_log_box.write, _bcolor(line))
                                self.call_from_thread(log_box.write, f"[dim]build[/] {_bcolor(line)}")
                            idle_count = 0
                        else:
                            idle_count += 1
                            time.sleep(0.2)
                            if idle_count > 10:
                                idle_count = 0
                                check_logs = _find_build_logs()
                                if check_logs and check_logs[0] != current_log:
                                    newest_log = check_logs[0]
                                    break
                                try:
                                    if os.path.getsize(current_log) < file_obj.tell():
                                        file_obj.seek(0)
                                except Exception: pass

            j_cmd = ["stdbuf", "-oL", "journalctl", "-fa", "-n", "0", "--no-pager"]
            if IS_WINDOWS:
                j_cmd = ["wsl.exe", "-d", "podman-MiOS-DEV", "-u", "root", "--", "stdbuf", "-oL", "journalctl", "-fa", "-n", "0", "--no-pager"]

            threading.Thread(target=stream_proc, args=(j_cmd,), daemon=True).start()
            if flash_log_box: threading.Thread(target=stream_flash_log, daemon=True).start()
            if build_log_box: threading.Thread(target=stream_build_log, daemon=True).start()

        def update_telemetry(self):
            cpu, ram, root, m_disk, load = get_telemetry()
            sys_info = get_sys_info()

            self.cpu_history.append(float(cpu))
            if len(self.cpu_history) > 60: self.cpu_history.pop(0)
            try:
                self.query_one("#spark-widget", Sparkline).data = list(self.cpu_history)
            except Exception: pass

            hw_lines = [
                f"[{SSOT['subtle']} bold]CPU Model:[/] {sys_info['cpu_model'][:36]}",
                f"[{SSOT['subtle']} bold]Load:[/] {load} | [{SSOT['subtle']} bold]Usage:[/] {make_bar(cpu, 18)} [{SSOT['subtle']} bold]{cpu:.1f}%[/]",
                ""
            ]
            if psutil:
                cpu_percs = psutil.cpu_percent(percpu=True)
                half = (len(cpu_percs) + 1) // 2
                for i in range(min(half, 8)):
                    c1_num = i
                    c1_val = cpu_percs[c1_num]
                    c1_str = f"C{c1_num:02d} {make_bar(c1_val, 8)} [dim]{c1_val:4.1f}%[/]"

                    c2_num = i + half
                    if c2_num < len(cpu_percs):
                        c2_val = cpu_percs[c2_num]
                        c2_str = f"C{c2_num:02d} {make_bar(c2_val, 8)} [dim]{c2_val:4.1f}%[/]"
                    else:
                        c2_str = ""
                    hw_lines.append(f"  {c1_str:<32}  {c2_str}")

                hw_lines.append("")
                mem = psutil.virtual_memory()
                swap = psutil.swap_memory()
                hw_lines.append(f"[{SSOT['warning']} bold]RAM:[/]  {make_bar(mem.percent, 16)} {mem.used/(1024**3):.1f}/{mem.total/(1024**3):.1f} GB ({mem.percent}%)")
                hw_lines.append(f"[{SSOT['warning']} bold]Swap:[/] {make_bar(swap.percent, 16)} {swap.used/(1024**3):.1f}/{swap.total/(1024**3):.1f} GB ({swap.percent}%)")
                hw_lines.append("")
                hw_lines.append(f"[{SSOT['subtle']} bold]Disk C:[/] {make_bar(root, 12)} {root}%   |   [{SSOT['subtle']} bold]Disk M:[/] {make_bar(m_disk, 12)} {m_disk}%")

                try:
                    net = psutil.net_io_counters()
                except Exception:
                    net = None
                if net is None:
                    hw_lines.append(f"[{SSOT['success']} bold]Network I/O:[/] unavailable")
                else:
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
                ai_lines = [
                    f"[{SSOT['success']} bold]AI Forge Status[/]",
                    f"[{SSOT['subtle']}]Podman Engine:[/] {'[green]ONLINE[/]' if check_port('127.0.0.1', 8888) or check_port('127.0.0.1', 8080) or IS_WINDOWS else '[red]OFFLINE[/]'}",
                    f"[{SSOT['subtle']}]LLM Inference:[/] {'[green]READY[/]' if check_port('127.0.0.1', 11450) or check_port('127.0.0.1', 11434) else '[dim]STANDBY[/]'}",
                    "",
                    f"[{SSOT['warning']}]System Memory:[/] {make_bar(psutil.virtual_memory().percent, 18)}",
                    f"[{SSOT['warning']}]System CPU:[/] {make_bar(float(cpu), 18)}"
                ]
                self.query_one("#ai-stats", Static).update("\n".join(ai_lines))

                last_log_t = getattr(self, 'last_flash_log_time', None)
                if last_log_t:
                    elapsed = int(time.time() - last_log_t)
                    if elapsed < 15:
                        status_str = f"[{SSOT['success']} bold]FLASHING IN PROGRESS (Active)[/]"
                    elif elapsed < 60:
                        status_str = f"[{SSOT['warning']} bold]FLASHING ACTIVE ({elapsed}s since line)[/]"
                    else:
                        status_str = f"[{SSOT['subtle']}]INACTIVE ({elapsed}s ago)[/]"
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

                last_build_t = getattr(self, "last_build_log_time", None)
                bpath = getattr(self, "build_log_path", None)
                phase_str = "-"
                if bpath and os.path.exists(bpath):
                    try:
                        with open(bpath, "r", encoding="utf-8", errors="ignore") as bf:
                            btail = bf.readlines()[-80:]
                        steps = [l for l in btail if "step:" in l]
                        if steps:
                            phase_str = steps[-1].split("step:", 1)[1].strip()[:38]
                    except Exception: pass
                if last_build_t:
                    el = int(time.time() - last_build_t)
                    if el < 20: bstat = f"[{SSOT['success']} bold]BUILDING (active)[/]"
                    elif el < 120: bstat = f"[{SSOT['warning']} bold]IDLE ({el}s since log)[/]"
                    else: bstat = f"[{SSOT['subtle']}]DONE / INACTIVE ({el}s ago)[/]"
                else:
                    bstat = f"[{SSOT['subtle']}]Waiting for build/install...[/]"
                build_lines = [
                    f"[{SSOT['accent']} bold]MiOS Build / Install[/]",
                    f"[{SSOT['subtle']}]Status:[/] {bstat}",
                    f"[{SSOT['subtle']}]Phase:[/] {phase_str}",
                    f"[{SSOT['subtle']}]Log:[/] {os.path.basename(bpath) if bpath else '-'}",
                    "",
                    "Live install/build pipeline stream ->",
                ]
                self.query_one("#build-stats", Static).update("\n".join(build_lines))
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
            pass

        def action_toggle_dark(self) -> None:
            self.dark = not self.dark

        def on_unmount(self) -> None:
            self.tailing = False

def main():
    global PIPELINE_MODE
    parser = argparse.ArgumentParser(description="MiOS-Mon -- Unified TUI & System Monitor")
    parser.add_argument("--mini", "--metal", action="store_true", help="compact mini/metal service layout")
    parser.add_argument("--dash", action="store_true", help="full system dashboard layout")
    parser.add_argument("--monitor", action="store_true", help="fullscreen interactive TUI monitor")
    parser.add_argument("--pipeline", action="store_true",
                        help="open directly on the live installer/build log tab")
    parser.add_argument("--once", action="store_true", help="print snapshot once and exit")
    args, unknown = parser.parse_known_args()
    PIPELINE_MODE = args.pipeline

    mode = "monitor"
    unknown_lower = [a.lower() for a in unknown]
    if args.mini or "-mini" in unknown_lower or "--metal" in unknown_lower or "-metal" in unknown_lower or os.environ.get("MIOS_COMPACT") == "1":
        mode = "mini"
    elif args.dash or "-dash" in unknown_lower or os.environ.get("MIOS_DASH_SERVICES") == "1":
        mode = "dash"

    if mode == "mini":
        console.print(create_metal_layout())
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

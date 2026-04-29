#!/bin/bash
# MiOS Fedora Server Ignition Script
# Fetches MiOS repository and merges onto Fedora Server root (FHS-compliant, NO deletions)
# Version: 1.0.0
# Usage: curl -fsSL https://raw.githubusercontent.com/Kabuki94/MiOS-bootstrap/main/build-mios.sh | sudo bash
#        OR: sudo bash build-mios.sh

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
MIOS_REPO_URL="${MIOS_REPO_URL:-https://github.com/Kabuki94/MiOS-bootstrap.git}"
MIOS_REPO_BRANCH="${MIOS_REPO_BRANCH:-main}"
MIOS_TMP_DIR="/tmp/mios-ignition-$$"
MIOS_INSTALL_LOG="/var/log/mios-ignition.log"
MIOS_CONFIG_DIR="/etc/mios"
MIOS_USER_CONFIG_DIR="" # Will be set after user is determined

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# Logging Functions
# ============================================================================
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "$MIOS_INSTALL_LOG"
}

log_warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN:${NC} $*" | tee -a "$MIOS_INSTALL_LOG"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" | tee -a "$MIOS_INSTALL_LOG"
}

log_info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $*" | tee -a "$MIOS_INSTALL_LOG"
}

# ============================================================================
# Banner
# ============================================================================
show_banner() {
    cat << 'EOF'
â•”â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•—
â•‘                   MiOS Fedora Server Ignition                            â•‘
â•‘                         Version 1.0.0                                    â•‘
â•šâ•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

This script will:
  1. Fetch MiOS repository from GitHub
  2. Prompt for user configuration (username, hostname, etc.)
  3. Queue environment files and dotfiles
  4. Merge MiOS structure onto Fedora Server (FHS-compliant)
  5. NO deletions - only additions and updates
  6. Build MiOS OCI image

EOF
}

# ============================================================================
# User Configuration Prompts
# ============================================================================
collect_user_config() {
    log_info "Collecting user configuration..."
    echo ""

    # Username
    read -p "Enter username (default: mios): " MIOS_USERNAME
    MIOS_USERNAME="${MIOS_USERNAME:-mios}"

    # Password
    while true; do
        read -sp "Enter password for ${MIOS_USERNAME}: " MIOS_PASSWORD
        echo ""
        read -sp "Confirm password: " MIOS_PASSWORD_CONFIRM
        echo ""

        if [[ "$MIOS_PASSWORD" == "$MIOS_PASSWORD_CONFIRM" ]]; then
            # Generate SHA-512 hash
            MIOS_PASSWORD_HASH=$(openssl passwd -6 "${MIOS_PASSWORD}")
            break
        else
            log_error "Passwords do not match. Please try again."
        fi
    done

    # Hostname
    read -p "Enter hostname (default: mios): " MIOS_HOSTNAME
    MIOS_HOSTNAME="${MIOS_HOSTNAME:-mios}"

    # Base image
    echo ""
    echo "Select base image:"
    echo "  1) ghcr.io/ublue-os/ucore-hci:stable-nvidia (NVIDIA GPU, recommended)"
    echo "  2) ghcr.io/ublue-os/ucore-hci:stable (No NVIDIA)"
    echo "  3) ghcr.io/ublue-os/ucore:stable (Minimal)"
    echo "  4) Custom (enter manually)"
    read -p "Choice [1-4] (default: 1): " BASE_IMAGE_CHOICE
    BASE_IMAGE_CHOICE="${BASE_IMAGE_CHOICE:-1}"

    case "$BASE_IMAGE_CHOICE" in
        1) MIOS_BASE_IMAGE="ghcr.io/ublue-os/ucore-hci:stable-nvidia" ;;
        2) MIOS_BASE_IMAGE="ghcr.io/ublue-os/ucore-hci:stable" ;;
        3) MIOS_BASE_IMAGE="ghcr.io/ublue-os/ucore:stable" ;;
        4)
            read -p "Enter custom base image: " MIOS_BASE_IMAGE
            ;;
        *) MIOS_BASE_IMAGE="ghcr.io/ublue-os/ucore-hci:stable-nvidia" ;;
    esac

    # Flatpak apps
    echo ""
    read -p "Enter Flatpak app IDs (comma-separated, optional): " MIOS_FLATPAKS_INPUT
    MIOS_FLATPAKS="${MIOS_FLATPAKS_INPUT}"

    # AI Configuration
    echo ""
    read -p "Configure AI settings? (y/N): " CONFIGURE_AI
    if [[ "$CONFIGURE_AI" =~ ^[Yy]$ ]]; then
        read -p "AI Model (default: llama3.1:8b): " MIOS_AI_MODEL
        MIOS_AI_MODEL="${MIOS_AI_MODEL:-llama3.1:8b}"

        read -p "AI Endpoint (default: http://localhost:8080/v1): " MIOS_AI_ENDPOINT
        MIOS_AI_ENDPOINT="${MIOS_AI_ENDPOINT:-http://localhost:8080/v1}"

        read -sp "AI API Key (optional, press Enter to skip): " MIOS_AI_KEY
        echo ""
    else
        MIOS_AI_MODEL="llama3.1:8b"
        MIOS_AI_ENDPOINT="http://localhost:8080/v1"
        MIOS_AI_KEY=""
    fi

    # Summary
    echo ""
    log_info "Configuration Summary:"
    echo "  Username:     $MIOS_USERNAME"
    echo "  Hostname:     $MIOS_HOSTNAME"
    echo "  Base Image:   $MIOS_BASE_IMAGE"
    echo "  Flatpaks:     ${MIOS_FLATPAKS:-none}"
    echo "  AI Model:     $MIOS_AI_MODEL"
    echo "  AI Endpoint:  $MIOS_AI_ENDPOINT"
    echo ""

    read -p "Proceed with this configuration? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_error "Installation cancelled by user."
        exit 1
    fi
}

# ============================================================================
# Prerequisites Check
# ============================================================================
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi

    # Check OS
    if [[ ! -f /etc/fedora-release ]]; then
        log_warn "This script is designed for Fedora Server. Detected OS: $(cat /etc/os-release | grep PRETTY_NAME || echo 'Unknown')"
        read -p "Continue anyway? (y/N): " CONTINUE
        if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    # Check internet connection
    if ! curl -fsSL --max-time 5 -o /dev/null https://github.com/; then
        log_error "No internet connection. Please check your network."
        exit 1
    fi

    log "Prerequisites check passed"
}

# ============================================================================
# Install Dependencies
# ============================================================================
install_dependencies() {
    log_info "Installing required dependencies..."

    dnf install -y \
        git \
        podman \
        buildah \
        rsync \
        python3 \
        systemd \
        coreutils \
        util-linux \
        || { log_error "Failed to install dependencies"; exit 1; }

    # Optional: Install just
    if ! command -v just &>/dev/null; then
        log_info "Installing 'just' command runner..."
        if command -v cargo &>/dev/null; then
            cargo install just || log_warn "'just' installation failed, continuing without it"
        else
            log_warn "'just' not installed (cargo not available). You can use podman directly."
        fi
    fi

    log "Dependencies installed successfully"
}

# ============================================================================
# Fetch MiOS Repository
# ============================================================================
fetch_mios_repo() {
    log_info "Fetching MiOS repository from ${MIOS_REPO_URL}..."

    # Create temporary directory
    mkdir -p "$MIOS_TMP_DIR"
    cd "$MIOS_TMP_DIR"

    # Clone repository
    git clone --depth 1 --branch "$MIOS_REPO_BRANCH" "$MIOS_REPO_URL" mios \
        || { log_error "Failed to clone MiOS repository"; exit 1; }

    cd mios

    log "MiOS repository fetched successfully"
}

# ============================================================================
# Queue Environment Files
# ============================================================================
queue_environment_files() {
    log_info "Queuing environment files and dotfiles..."

    # Determine user home directory
    if [[ "$MIOS_USERNAME" == "root" ]]; then
        MIOS_USER_HOME="/root"
    else
        MIOS_USER_HOME="/home/${MIOS_USERNAME}"
    fi

    MIOS_USER_CONFIG_DIR="${MIOS_USER_HOME}/.config/mios"

    # Create user configuration directory structure
    mkdir -p "$MIOS_USER_CONFIG_DIR"

    # Create env.toml
    cat > "$MIOS_USER_CONFIG_DIR/env.toml" <<EOF
# MiOS User Environment Configuration
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

[mios]
user = "${MIOS_USERNAME}"
hostname = "${MIOS_HOSTNAME}"

[ai]
model = "${MIOS_AI_MODEL}"
endpoint = "${MIOS_AI_ENDPOINT}"
temperature = 0.7
EOF

    # Create images.toml
    cat > "$MIOS_USER_CONFIG_DIR/images.toml" <<EOF
# MiOS Image Configuration

[base]
image = "${MIOS_BASE_IMAGE}"

[builder]
image = "quay.io/centos-bootc/bootc-image-builder:latest"

[output]
name = "localhost/mios"
tag = "latest"
EOF

    # Create build.toml
    cat > "$MIOS_USER_CONFIG_DIR/build.toml" <<EOF
# MiOS Build Configuration

[build]
no_cache = true
progress = "tty"

[flatpaks]
source_file = "${MIOS_USER_CONFIG_DIR}/flatpaks.list"
EOF

    # Create flatpaks.list
    if [[ -n "$MIOS_FLATPAKS" ]]; then
        echo "$MIOS_FLATPAKS" | tr ',' '\n' > "$MIOS_USER_CONFIG_DIR/flatpaks.list"
    else
        touch "$MIOS_USER_CONFIG_DIR/flatpaks.list"
    fi

    # Create ai.env (secrets - not committed)
    if [[ -n "$MIOS_AI_KEY" ]]; then
        cat > "$MIOS_USER_CONFIG_DIR/ai.env" <<EOF
# MiOS AI Configuration (SECRETS - DO NOT COMMIT)
MIOS_AI_KEY="${MIOS_AI_KEY}"
EOF
        chmod 600 "$MIOS_USER_CONFIG_DIR/ai.env"
    fi

    # Create system-wide runtime.env
    mkdir -p "$MIOS_CONFIG_DIR"
    cat > "$MIOS_CONFIG_DIR/runtime.env" <<EOF
# MiOS Runtime Environment
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

MIOS_AI_ENDPOINT="${MIOS_AI_ENDPOINT}"
MIOS_AI_MODEL="${MIOS_AI_MODEL}"
MIOS_HOSTNAME="${MIOS_HOSTNAME}"
EOF

    log "Environment files queued successfully"
}

# ============================================================================
# Merge MiOS Structure (FHS-Compliant, NO Deletions)
# ============================================================================
merge_mios_structure() {
    log_info "Merging MiOS structure onto Fedora Server root (FHS-compliant)..."

    cd "$MIOS_TMP_DIR/mios"

    # Merge directories with rsync (--ignore-existing = NO overwrites)
    # This ensures existing Fedora files are PRESERVED

    # 1. Merge /usr (system binaries, libraries, data)
    log_info "Merging /usr..."
    rsync -av --ignore-existing usr/ /usr/ \
        || log_warn "Some files in /usr were skipped (already exist)"

    # 2. Merge /etc (configuration templates)
    log_info "Merging /etc..."
    rsync -av --ignore-existing etc/ /etc/ \
        || log_warn "Some files in /etc were skipped (already exist)"

    # 3. Declare /var directories via tmpfiles.d (NO direct mkdir)
    log_info "Declaring /var directories via tmpfiles.d..."
    if [[ -f usr/lib/tmpfiles.d/mios.conf ]]; then
        cp -n usr/lib/tmpfiles.d/mios.conf /usr/lib/tmpfiles.d/ || true
        systemd-tmpfiles --create /usr/lib/tmpfiles.d/mios.conf || log_warn "tmpfiles creation had warnings"
    fi

    # 4. Merge /home skeleton
    log_info "Merging /home skeleton..."
    if [[ -d home/mios ]]; then
        mkdir -p /etc/skel/.config/mios
        rsync -av --ignore-existing home/mios/ /etc/skel/ || true
    fi

    # 5. Copy tools and automation (for building)
    log_info "Installing tools and automation..."
    rsync -av tools/ /usr/share/mios/tools/ || true
    rsync -av automation/ /usr/share/mios/automation/ || true

    # 6. Make all scripts executable
    log_info "Setting executable permissions..."
    chmod +x /usr/bin/mios* /usr/bin/iommu-groups 2>/dev/null || true
    chmod +x /usr/libexec/mios* 2>/dev/null || true
    chmod +x /usr/libexec/mios/* 2>/dev/null || true
    chmod +x /usr/share/mios/tools/*.sh 2>/dev/null || true
    chmod +x /usr/share/mios/automation/*.sh 2>/dev/null || true

    # 7. Copy Containerfile and Justfile to /usr/share/mios for building
    log_info "Installing build files..."
    cp -n Containerfile /usr/share/mios/ || true
    cp -n Justfile /usr/share/mios/ || true
    cp -n VERSION /usr/share/mios/ || true

    # 8. Create /usr/src/mios symlink (for mios rebuild command)
    log_info "Creating source symlink..."
    ln -sf /usr/share/mios /usr/src/mios || true

    log "MiOS structure merged successfully (NO deletions)"
}

# ============================================================================
# Create User Account & Initialize User-Space
# ============================================================================
create_user_account() {
    log_info "Creating user account: ${MIOS_USERNAME}..."

    if id "$MIOS_USERNAME" &>/dev/null; then
        log_warn "User ${MIOS_USERNAME} already exists, updating password..."
        echo "${MIOS_USERNAME}:${MIOS_PASSWORD}" | chpasswd
    else
        # Create user with password hash
        EXTRA_GROUPS="wheel,libvirt,kvm,video,render,input,dialout"
        if getent group docker >/dev/null 2>&1; then EXTRA_GROUPS="$EXTRA_GROUPS,docker"; fi
        useradd -m -G "$EXTRA_GROUPS" -s /bin/bash "$MIOS_USERNAME"
        echo "${MIOS_USERNAME}:${MIOS_PASSWORD}" | chpasswd

        # Set up sudo access
        echo "${MIOS_USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${MIOS_USERNAME}"
        chmod 0440 "/etc/sudoers.d/${MIOS_USERNAME}"
    fi

    log_info "Initializing user-space directories and configuration..."

    # XDG Base Directory variables
    MIOS_USER_DATA_DIR="${MIOS_USER_HOME}/.local/share/mios"
    MIOS_USER_CACHE_DIR="${MIOS_USER_HOME}/.cache/mios"
    MIOS_USER_STATE_DIR="${MIOS_USER_HOME}/.local/state/mios"

    # Create XDG directory structure
    mkdir -p "${MIOS_USER_CONFIG_DIR}/credentials/ssh-keys"
    mkdir -p "${MIOS_USER_DATA_DIR}/artifacts"
    mkdir -p "${MIOS_USER_DATA_DIR}/images"
    mkdir -p "${MIOS_USER_DATA_DIR}/templates"
    mkdir -p "${MIOS_USER_DATA_DIR}/plugins"
    mkdir -p "${MIOS_USER_CACHE_DIR}/podman"
    mkdir -p "${MIOS_USER_CACHE_DIR}/downloads"
    mkdir -p "${MIOS_USER_CACHE_DIR}/build-cache"
    mkdir -p "${MIOS_USER_STATE_DIR}/logs"

    # Setup dotfiles directory for build-time injection
    mkdir -p "${MIOS_USER_CONFIG_DIR}/dotfiles"
    if [[ ! -f "${MIOS_USER_CONFIG_DIR}/dotfiles/.bashrc.user" ]]; then
        cat > "${MIOS_USER_CONFIG_DIR}/dotfiles/.bashrc.user" <<'DOTFILE_EOF'
# MiOS User-Space .bashrc extension
# This file is injected into the image during build-time.
alias ll='ls -alF'
alias mios-status='mios assess'
export EDITOR=vim
DOTFILE_EOF
    fi

    # Create credentials .gitignore
    cat > "${MIOS_USER_CONFIG_DIR}/credentials/.gitignore" <<'GITIGNORE_EOF'
# MiOS Credentials - Ignore Everything
# This directory should NEVER be committed to version control

*
!.gitignore
!README.md
GITIGNORE_EOF

    # Initialize Python virtual environment
    if command -v python3 &>/dev/null; then
        if [[ ! -d "${MIOS_USER_DATA_DIR}/venv" ]]; then
            python3 -m venv "${MIOS_USER_DATA_DIR}/venv" 2>/dev/null || log_warn "Failed to create Python venv"
        fi
    fi

    # Copy environment files to user's home and fix ownership
    chown -R "${MIOS_USERNAME}:${MIOS_USERNAME}" "${MIOS_USER_HOME}/.config" 2>/dev/null || true
    chown -R "${MIOS_USERNAME}:${MIOS_USERNAME}" "${MIOS_USER_HOME}/.local" 2>/dev/null || true
    chown -R "${MIOS_USERNAME}:${MIOS_USERNAME}" "${MIOS_USER_HOME}/.cache" 2>/dev/null || true

    log "User account and user-space configured successfully"
}

# ============================================================================
# Set Hostname
# ============================================================================
set_hostname() {
    log_info "Setting hostname to: ${MIOS_HOSTNAME}..."

    hostnamectl set-hostname "$MIOS_HOSTNAME"

    log "Hostname set successfully"
}

# ============================================================================
# Build MiOS Image (Optional)
# ============================================================================
build_mios_image() {
    log_info "Would you like to build the MiOS OCI image now?"
    echo "  This will take 15-25 minutes on first build."
    echo "  You can also build later with: cd /usr/share/mios && just build"
    echo ""
    read -p "Build now? (y/N): " BUILD_NOW

    if [[ "$BUILD_NOW" =~ ^[Yy]$ ]]; then
        log_info "Building MiOS OCI image..."

        cd /usr/share/mios

        # Load user environment
        export MIOS_BASE_IMAGE
        export MIOS_FLATPAKS
        export MIOS_USER="${MIOS_USERNAME}"
        export MIOS_PASSWORD_HASH
        export MIOS_HOSTNAME

        if command -v just &>/dev/null; then
            just build || { log_error "Build failed"; return 1; }
        else
            # Fallback to direct podman build
            podman build --no-cache \
                --build-arg BASE_IMAGE="$MIOS_BASE_IMAGE" \
                --build-arg MIOS_USER="$MIOS_USERNAME" \
                --build-arg MIOS_PASSWORD_HASH="$MIOS_PASSWORD_HASH" \
                --build-arg MIOS_HOSTNAME="$MIOS_HOSTNAME" \
                --build-arg MIOS_FLATPAKS="$MIOS_FLATPAKS" \
                -t localhost/mios:latest . \
                || { log_error "Build failed"; return 1; }
        fi

        log "MiOS OCI image built successfully: localhost/mios:latest"

        # Ask about deployment
        echo ""
        read -p "Deploy to this system now? (y/N): " DEPLOY_NOW
        if [[ "$DEPLOY_NOW" =~ ^[Yy]$ ]]; then
            log_info "Deploying MiOS to this system..."
            bootc install to-existing-root --source-imgref localhost/mios:latest \
                || log_warn "Deployment failed or not supported on this system"
        fi
    else
        log_info "Skipping build. To build later, run:"
        echo "  cd /usr/share/mios && just build"
    fi
}

# ============================================================================
# Cleanup
# ============================================================================
cleanup() {
    log_info "Cleaning up temporary files..."

    if [[ -d "$MIOS_TMP_DIR" ]]; then
        rm -rf "$MIOS_TMP_DIR"
    fi

    log "Cleanup complete"
}

# ============================================================================
# Final Summary
# ============================================================================
show_summary() {
    cat << EOF

â•”â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•—
â•‘                   MiOS Installation Complete!                            â•‘
â•šâ•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

Configuration:
  Username:     ${MIOS_USERNAME}
  Hostname:     ${MIOS_HOSTNAME}
  Config Dir:   ${MIOS_USER_CONFIG_DIR}

Installation Details:
  âœ“ MiOS structure merged to system root (FHS-compliant)
  âœ“ User account created with full permissions
  âœ“ User-space initialized (XDG directories, configs, dotfiles)
  âœ“ Python virtual environment created
  âœ“ System configuration installed
  âœ“ Build files installed to /usr/share/mios

Next Steps:

  1. Switch to your user:
     su - ${MIOS_USERNAME}

  2. Build MiOS image (if not done):
     cd /usr/share/mios && just build

  3. Check system status:
     mios status

  4. View available commands:
     mios --help

  5. Customize your configuration:
     \$EDITOR ~/.config/mios/env.toml

Documentation:
  - Installation log: ${MIOS_INSTALL_LOG}
  - Configuration: ${MIOS_USER_CONFIG_DIR}
  - System config: ${MIOS_CONFIG_DIR}

For more information:
  https://github.com/Kabuki94/MiOS-bootstrap

EOF
}

# ============================================================================
# Main Execution
# ============================================================================
main() {
    # Initialize log
    mkdir -p "$(dirname "$MIOS_INSTALL_LOG")"
    touch "$MIOS_INSTALL_LOG"

    show_banner

    check_prerequisites
    collect_user_config
    install_dependencies
    fetch_mios_repo
    queue_environment_files
    merge_mios_structure
    create_user_account
    set_hostname
    build_mios_image
    cleanup
    show_summary

    log "MiOS Fedora Server ignition completed successfully!"
}

# Trap errors
trap 'log_error "Installation failed at line $LINENO. Check $MIOS_INSTALL_LOG for details."' ERR

# Run main
main "$@"

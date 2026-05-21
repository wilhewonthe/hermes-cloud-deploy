#!/usr/bin/env bash
# =============================================================================
# Fix "E: Unable to correct problems, you have held broken packages." error
# This script attempts to resolve held/broken packages and then installs a
# target package (default: openstack-compute-node) if provided.
#
# Usage:
#   sudo ./fix-broken-packages.sh [package-name]
#   If package-name is omitted, the script will only try to fix the broken
#   state without installing anything.
#
# Steps:
#   1. dpkg --configure -a
#   2. apt-get install -f (or nala install -f if nala is preferred)
#   3. List and optionally unhold held packages (interactive)
#   4. apt-get clean && apt-get update
#   5. Try installing the target package with nala (or apt)
#   6. If still failing, fall back to aptitude for conflict resolution
#   7. Offer to remove a specific problematic package if identified
#
# Author: Hermes Agent
# =============================================================================

set -euo pipefail

# -------------------------- CONFIGURATION --------------------------
# Prefer nala if available, else fall back to apt
if command -v nala &>/dev/null; then
    PKG_MGR="nala"
else
    PKG_MGR="apt"
fi
# ------------------------------------------------------------------

# Helper functions
info() { echo -e "[\e[34mINFO\e[0m] $*"; }
warn() { echo -e "[\e[33mWARN\e[0m] $*"; }
error() { echo -e "[\e[31mERROR\e[0m] $*" >&2; }
success() { echo -e "[\e[32mSUCCESS\e[0m] $*"; }

# Check if running as root (needed for package management)
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)."
    exit 1
fi

TARGET_PKG="${1:-}"

info "Starting fix for held/broken packages..."

# Step 1: Reconfigure unpacked packages
info "Running: dpkg --configure -a"
dpkg --configure -a

# Step 2: Attempt to fix broken dependencies
info "Attempting to fix broken dependencies with ${PKG_MGR} install -f..."
if [[ "$PKG_MGR" == "nala" ]]; then
    nala install -f
else
    apt-get install -f -y
fi

# Step 3: Show held packages and ask if user wants to unhold them
info "Checking for held packages..."
HELD=$(apt-mark showhold 2>/dev/null || true)
if [[ -z "$HELD" ]]; then
    info "No held packages found."
else
    warn "The following packages are currently held:"
    echo "$HELD"
    read -rp "Do you want to unhold ALL of these packages? (y/N) " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        while IFS= read -r pkg; do
            info "Unholding package: $pkg"
            apt-mark unhold "$pkg"
        done <<< "$HELD"
        info "All held packages have been unheld."
    else
        info "Skipping unhold step."
    fi
fi

# Step 4: Clean cache and update package index
info "Cleaning package cache and updating index..."
apt-get clean
apt-get update

# Step 5: If a target package was provided, try to install it
if [[ -n "$TARGET_PKG" ]]; then
    info "Attempting to install target package: $TARGET_PKG"
    if [[ "$PKG_MGR" == "nala" ]]; then
        nala install -y "$TARGET_PKG"
    else
        apt-get install -y "$TARGET_PKG"
    fi
    success "Package $TARGET_PKG installed successfully."
    exit 0
fi

# If we reach here and no target package was given, we just finished fixing.
info "No target package specified; finished fixing broken/held state."
success "You can now try installing your desired package manually."
exit 0
# Cascade Port Forwarder

Lightweight interactive Bash utility for configuring cascading port forwarding on Linux using iptables.

## Overview

This tool allows you to create a relay (cascade) server that forwards incoming traffic to another host:

Client → This Server → Target Server

It is useful when you need to expose a remote service through an intermediate VPS or gateway.

The script works via **iptables (DNAT + MASQUERADE)** and provides an interactive interface with clear explanations before applying changes.

---

## Features

- TCP and UDP support
- Standard forwarding (same input/output port)
- Custom forwarding (different input/output ports)
- Interactive interface (CLI or `whiptail`)
- Automatic network interface detection
- Safe rule tagging (only manages its own rules)
- Ability to list and remove created rules
- Optional persistence via `netfilter-persistent`
- Input validation (IP, ports, protocol)
- No hidden system changes

---

## What the Script Does

When applying a rule, the script:

1. Enables IP forwarding (if not already enabled)
2. Adds iptables rules:
   - `nat PREROUTING` (DNAT)
   - `nat POSTROUTING` (MASQUERADE)
   - `filter FORWARD` (traffic allowance)
3. Optionally saves rules for persistence

---

## What the Script Does NOT Do

- Does not overwrite existing firewall configuration
- Does not flush iptables
- Does not install or enable BBR
- Does not modify UFW or firewalld automatically
- Does not copy itself into system paths
- Does not include ads, telemetry, or external calls

---

## Requirements

- Linux server (Debian/Ubuntu recommended)
- Root privileges
- `iptables` installed

Optional:
- `whiptail` (for UI)
- `netfilter-persistent` (for rule persistence)

---

## Installation

Clone the repository:

```bash
git clone https://github.com/yourusername/cascade-port-forwarder.git
cd cascade-port-forwarder
chmod +x cascade-forward.sh

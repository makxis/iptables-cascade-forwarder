# iptables-cascade-forwarder

Interactive Bash utility for configuring cascading port forwarding on Linux using iptables.

---

## 🚀 Overview

This tool allows you to turn a Linux server into a traffic relay (cascade node):

Client → Relay Server → Target Server

It transparently forwards incoming connections to a remote destination using iptables (DNAT + MASQUERADE).

---

## ⚙️ How It Works

The script configures:

- `nat PREROUTING` — redirects incoming traffic (DNAT)
- `nat POSTROUTING` — rewrites source address (MASQUERADE)
- `filter FORWARD` — allows packet forwarding
- enables `net.ipv4.ip_forward`

This is the standard Linux packet flow for gateway/relay setups.

---

## ✨ Features

- TCP and UDP support
- Simple mode (same input/output port)
- Advanced mode (different ports)
- Interactive CLI (with optional `whiptail` UI)
- Safe rule tagging (does NOT touch unrelated rules)
- Rule listing and selective removal
- Optional persistence via `netfilter-persistent`
- Input validation (IP / port / protocol)

---

## 🧠 Design Principles

- ❌ No ads, QR codes, or hidden behavior  
- ❌ No auto-installing itself into system paths  
- ❌ No forced tuning (BBR, sysctl spam, etc.)  
- ❌ No firewall override (UFW / firewalld untouched)  
- ✅ Only minimal required system changes  
- ✅ Fully transparent actions before execution  

---

## 📦 Requirements

- Linux (Debian/Ubuntu recommended)
- root privileges
- iptables

Optional:
- `whiptail` — for UI
- `netfilter-persistent` — for saving rules

---

## Installation

Run:

```bash
wget -qO- https://raw.githubusercontent.com/makxis/iptables-cascade-forwarder/main/install.sh | sudo bash

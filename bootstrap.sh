#!/usr/bin/env bash

set -e

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

# Update and upgrade system packages
apt-get update && apt-get upgrade -y

# Install unattended-upgrades for security updates
apt-get install -y unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades

# Install required packages
apt-get install -y git curl ufw fail2ban openssh-server cockpit lxde-core xrdp docker.io

# Basic system hardening: firewall
ufw allow OpenSSH
ufw allow 9090/tcp
ufw --force enable

# Disable SSH password authentication for security
if grep -q "^#PasswordAuthentication" /etc/ssh/sshd_config; then
  sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
else
  sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
fi
systemctl reload sshd || true

# Start and enable Fail2Ban
systemctl enable fail2ban
systemctl start fail2ban

# Configure XRDP to launch LXDE
cat >/etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
exec startlxde
EOF
chmod +x /etc/xrdp/startwm.sh
systemctl enable --now xrdp

# Start Docker for Guacamole containers
systemctl enable --now docker

# Deploy Guacamole containers
docker run -d --name guacd --restart unless-stopped guacamole/guacd
docker run -d --name guacamole --restart unless-stopped \
  --link guacd:guacd -e GUACD_HOSTNAME=guacd -p 8080:8080 guacamole/guacamole

# Enable Cockpit for web-based management
systemctl enable --now cockpit.socket

# Configure git with Personal Access Token
read -r -p "Enter your GitHub Personal Access Token: " GH_PAT
echo "https://${GH_PAT}:x-oauth-basic@github.com" > ~/.git-credentials
git config --global credential.helper store
git config --global init.defaultBranch main

# Validate the token by hitting the GitHub API
curl -f -H "Authorization: token ${GH_PAT}" https://api.github.com/user >/dev/null 2>&1 || {
  echo "GitHub token validation failed" >&2
  exit 1
}

git config --global user.name "MOrtner71"
# Update with your preferred email
read -r -p "Enter your git email: " GH_EMAIL
git config --global user.email "$GH_EMAIL"

# Install Cloudflared
curl -fsSLo /tmp/cloudflared.deb \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
apt-get install -y /tmp/cloudflared.deb
rm /tmp/cloudflared.deb

# Configure Cloudflared
read -r -p "Enter your Cloudflare API token: " CF_TOKEN
cloudflared service install "$CF_TOKEN"

TUNNEL_NAME=$(hostname)
cloudflared tunnel create "$TUNNEL_NAME"
cloudflared tunnel route dns "$TUNNEL_NAME" "${TUNNEL_NAME}-ssl.mortnerlink.cloud"
cloudflared tunnel route dns "$TUNNEL_NAME" "${TUNNEL_NAME}-cockpit.mortnerlink.cloud"
cloudflared tunnel route dns "$TUNNEL_NAME" "${TUNNEL_NAME}-guacamole.mortnerlink.cloud"

cat <<CFG >/etc/cloudflared/config.yml
tunnel: $TUNNEL_NAME
credentials-file: /root/.cloudflared/${TUNNEL_NAME}.json
ingress:
  - hostname: ${TUNNEL_NAME}-ssl.mortnerlink.cloud
    service: ssh://localhost:22
  - hostname: ${TUNNEL_NAME}-cockpit.mortnerlink.cloud
    service: http://localhost:9090
  - hostname: ${TUNNEL_NAME}-guacamole.mortnerlink.cloud
    service: http://localhost:8080
  - service: http_status:404
CFG

systemctl enable cloudflared
systemctl restart cloudflared

echo "Setup complete. Access SSH at ${TUNNEL_NAME}-ssl.mortnerlink.cloud, Cockpit at ${TUNNEL_NAME}-cockpit.mortnerlink.cloud, and Guacamole at ${TUNNEL_NAME}-guacamole.mortnerlink.cloud"

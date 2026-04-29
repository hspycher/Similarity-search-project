#!/bin/bash
# user-data.sh - runs once on first EC2 boot via cloud-init.
# Installs Python + the similarity-search project and serves the Streamlit
# app on port 8501 as a systemd service.
#
# Logs: /var/log/cloud-init-output.log  (tail -f to watch first boot)

set -euxo pipefail

# --- Swap file (required on free-tier 1 GB instances) -----------------------
# CLIP + PyTorch need ~1.2 GB to load. t3.micro has 1 GB RAM, so without swap
# the model load OOMs. 4 GB swap is plenty and free tier includes 30 GB EBS.
if ! swapon --show | grep -q '/swapfile'; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    # Be willing to use swap (default vm.swappiness=60 is fine for our case)
fi

# --- Configurable values (overridden by deploy.sh via cloud-init templating) -
REPO_URL="${REPO_URL:-https://github.com/dongyansun/Similarity-search-project.git}"
APP_USER="ubuntu"
APP_HOME="/home/${APP_USER}"
APP_DIR="${APP_HOME}/Similarity-search-project"

# --- System packages ---------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv python3-dev \
    git build-essential curl ca-certificates

# --- Clone the project -------------------------------------------------------
sudo -u "${APP_USER}" git clone "${REPO_URL}" "${APP_DIR}"
cd "${APP_DIR}"

# --- Python virtualenv + deps ------------------------------------------------
sudo -u "${APP_USER}" python3 -m venv "${APP_DIR}/.venv"
sudo -u "${APP_USER}" bash -c "
    source ${APP_DIR}/.venv/bin/activate
    pip install --upgrade pip wheel
    # CPU-only torch (much smaller, t3.medium has no GPU)
    pip install --index-url https://download.pytorch.org/whl/cpu torch torchvision
    pip install -r ${APP_DIR}/requirements.txt
    pip install streamlit
"

# --- Stub catalog so the Streamlit sidebar can load --------------------------
# The Streamlit app calls load_catalog() at startup to populate the filter
# dropdowns. That reads 'archive (1)/styles.csv' locally. We're querying the
# remote Qdrant 'deepfashion_items' collection, so we don't need real images
# locally - but we do need the CSV header + at least one row that has a
# matching image file, otherwise load_catalog() raises.
#
# Image-upload search and text search both work; they hit Qdrant directly.
STUB_DIR="${APP_DIR}/archive (1)"
sudo -u "${APP_USER}" mkdir -p "${STUB_DIR}/images"
sudo -u "${APP_USER}" tee "${STUB_DIR}/styles.csv" >/dev/null <<'CSV'
id,gender,masterCategory,subCategory,articleType,baseColour,season,year,usage,productDisplayName
1,Men,Apparel,Topwear,Shirts,Blue,Summer,2020,Casual,Stub Item
CSV

# Tiny 1x1 black JPEG (base64 - pure ASCII, no shell-escape gymnastics)
sudo -u "${APP_USER}" bash -c "base64 -d > '${STUB_DIR}/images/1.jpg'" <<'B64'
/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a
HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIy
MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIA
AhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAr/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFAEB
AAAAAAAAAAAAAAAAAAAAAP/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/AL+P/9k=
B64

# --- systemd service ---------------------------------------------------------
cat >/etc/systemd/system/fashion-search.service <<EOF
[Unit]
Description=Fashion Similarity Search (Streamlit)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment=PATH=${APP_DIR}/.venv/bin:/usr/bin:/bin
ExecStart=${APP_DIR}/.venv/bin/streamlit run ${APP_DIR}/app.py \\
    --server.port=8501 \\
    --server.address=0.0.0.0 \\
    --server.headless=true \\
    --browser.gatherUsageStats=false
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now fashion-search.service

# --- Final note in cloud-init log --------------------------------------------
echo
echo "============================================================"
echo "  Fashion Search is starting on port 8501"
echo "  Qdrant target: http://16.144.140.219:6333"
echo "  systemd unit:  fashion-search.service"
echo "  Logs:          journalctl -u fashion-search -f"
echo "============================================================"

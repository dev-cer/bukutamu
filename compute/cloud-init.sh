#!/bin/bash
# Dijalankan otomatis oleh Civo di akhir cloud-init (flag --script pada civo instance create).
# Memasang Docker Engine + Docker Compose plugin, lalu menandai VM siap dipakai.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
usermod -aG docker civo || true
echo "siap $(date -Is)" > /var/log/civo-onboarding-ready

#!/usr/bin/env bash
# Dry-run fasilitator: menjalankan alur lab onboarding Buku Tamu di akun Civo Anda,
# mengecek setiap hasil, mencatat durasi, lalu membersihkan semua resource.
#
# Pemakaian (dari root repo):
#   ./scripts/dry-run.sh              # lab Kubernetes (sesi 30 menit)       ± 8–12 menit
#   ./scripts/dry-run.sh --with-vm    # + lab Civo Compute (sesi 60 menit)   ± 15–20 menit
#   ./scripts/dry-run.sh --keep       # jangan hapus resource di akhir (cek manual dulu)
#
# Prasyarat: civo CLI (API key & region sudah di-set), kubectl, curl, ssh, ssh-keygen.
# Catatan: --save --switch akan menambah context cluster ke ~/.kube/config Anda.
set -uo pipefail

CLUSTER="civo-onboarding"
VM="buku-tamu-vm"
FW="buku-tamu-fw"
SSHKEY="onboarding-key"
NS="buku-tamu"
WITH_VM=0
KEEP=0
MADE_K8S=0; MADE_VM=0; MADE_FW=0; MADE_KEY=0   # hanya resource buatan skrip ini yang dihapus
for a in "$@"; do
  case "$a" in
    --with-vm) WITH_VM=1 ;;
    --keep) KEEP=1 ;;
    -h|--help) sed -n 2,12p "$0"; exit 0 ;;
    *) echo "Opsi tidak dikenal: $a"; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
REPORT="$ROOT/dry-run-report-$(date +%Y%m%d-%H%M).txt"
RESULTS=()
FAILED=0
T0=$(date +%s)

c_ok=$'\e[32m'; c_bad=$'\e[31m'; c_dim=$'\e[2m'; c_off=$'\e[0m'
log()  { printf '%s[%s]%s %s\n' "$c_dim" "$(date +%H:%M:%S)" "$c_off" "$*"; }
pass() { RESULTS+=("PASS  $1  ($2 dtk)"); printf '%s✔ PASS%s %s %s(%s dtk)%s\n' "$c_ok" "$c_off" "$1" "$c_dim" "$2" "$c_off"; }
fail() { RESULTS+=("FAIL  $1  — $2"); FAILED=$((FAILED+1)); printf '%s✘ FAIL%s %s — %s\n' "$c_bad" "$c_off" "$1" "$2"; }
since() { echo $(( $(date +%s) - $1 )); }
# retry <detik-maks> <perintah...>: ulangi tiap 5 detik sampai berhasil
retry() { local max=$1; shift; local t; t=$(date +%s); until "$@" >/dev/null 2>&1; do [ "$(since "$t")" -ge "$max" ] && return 1; sleep 5; done; }

cleanup() {
  [ "$KEEP" = 1 ] && { log "--keep: resource TIDAK dihapus. Hapus manual sesuai slide Cleanup."; return; }
  log "Cleanup dimulai…"
  local t; t=$(date +%s)
  if [ "$MADE_K8S" = 1 ]; then
    [ -d "$WORK/k8s" ] && kubectl delete -f "$WORK/k8s/" --ignore-not-found --wait=true >/dev/null 2>&1
    civo kubernetes remove "$CLUSTER" -y >/dev/null 2>&1
  fi
  [ "$MADE_VM" = 1 ] && civo instance remove "$VM" -y >/dev/null 2>&1
  [ "$MADE_FW" = 1 ] && retry 120 civo firewall remove "$FW" -y
  [ "$MADE_KEY" = 1 ] && civo sshkey remove "$SSHKEY" -y >/dev/null 2>&1
  [ $((MADE_K8S+MADE_VM+MADE_FW+MADE_KEY)) = 0 ] && { log "Tidak ada resource yang dibuat skrip; tidak ada yang dihapus."; return; }
  sleep 20
  log "Sisa resource setelah cleanup (seharusnya tidak ada resource lab):"
  { echo "--- civo kubernetes ls"; civo kubernetes ls; echo "--- civo instance ls"; civo instance ls
    echo "--- civo volume ls"; civo volume ls; echo "--- civo loadbalancer ls"; civo loadbalancer ls
    echo "--- civo firewall ls"; civo firewall ls; } 2>&1 | tee -a "$REPORT.leftover"
  RESULTS+=("INFO  Cleanup selesai  ($(since "$t") dtk) — cek daftar sisa di $REPORT.leftover")
}

report() {
  local total; total=$(since "$T0")
  {
    echo "Dry-run onboarding Buku Tamu — $(date '+%Y-%m-%d %H:%M')"
    echo "Region aktif: ${REGION:-?}   Civo CLI: $(civo version 2>/dev/null | head -1)"
    echo "Mode: $([ "$WITH_VM" = 1 ] && echo 'Kubernetes + Compute' || echo 'Kubernetes saja')"
    echo
    printf '%s\n' ${RESULTS[@]+"${RESULTS[@]}"}
    echo
    echo "Total waktu: $((total/60)) menit $((total%60)) detik — FAIL: $FAILED"
  } | tee "$REPORT"
  rm -rf "$WORK"
}
trap 'cleanup; report' EXIT
trap 'echo; log "Dibatalkan."; exit 130' INT

# ------------------------------------------------------------------ 0. Prasyarat
log "0. Cek prasyarat"
t=$(date +%s)
for bin in civo kubectl curl ssh ssh-keygen; do
  command -v "$bin" >/dev/null || { fail "Tool $bin terpasang" "tidak ditemukan di PATH"; exit 1; }
done
civo kubernetes ls >/dev/null 2>&1 || { fail "API key Civo aktif" "civo kubernetes ls gagal; jalankan civo apikey use <nama>"; exit 1; }
REGION=$(civo region ls 2>/dev/null | grep -E '<=|true' | head -1 | tr -s ' |' ' ' | sed 's/^ //')
log "Region aktif terdeteksi: ${REGION:-tidak terbaca, cek manual dengan civo region ls}"
if civo kubernetes show "$CLUSTER" >/dev/null 2>&1; then fail "Nama cluster bebas" "cluster $CLUSTER sudah ada; hapus dulu"; exit 1; fi
if [ "$WITH_VM" = 1 ]; then
  civo instance show "$VM" >/dev/null 2>&1 && { fail "Nama VM bebas" "instance $VM sudah ada; hapus dulu"; exit 1; }
  civo firewall ls 2>/dev/null | grep -qw "$FW" && { fail "Nama firewall bebas" "firewall $FW sudah ada; hapus dulu"; exit 1; }
  civo sshkey ls 2>/dev/null | grep -qw "$SSHKEY" && { fail "Nama SSH key bebas" "SSH key $SSHKEY sudah ada; hapus dulu"; exit 1; }
fi
pass "0. Prasyarat (tool, API key, nama resource bebas)" "$(since "$t")"

# ------------------------------------------------------------------ 1. Compute (opsional)
if [ "$WITH_VM" = 1 ]; then
  log "1.1 Firewall VM"
  t=$(date +%s)
  if civo firewall create "$FW" --no-default-rules >/dev/null && MADE_FW=1 \
    && civo firewall rule create "$FW" -s 22 -e 22 -l ssh >/dev/null \
    && civo firewall rule create "$FW" -s 8080 -e 8080 -l app >/dev/null \
    && civo firewall rule create "$FW" -d egress -s 1 -e 65535 -p TCP -l out-tcp >/dev/null \
    && civo firewall rule create "$FW" -d egress -s 1 -e 65535 -p UDP -l out-udp >/dev/null; then
    pass "1.1 Firewall + 4 rule" "$(since "$t")"
  else fail "1.1 Firewall + 4 rule" "perintah civo firewall gagal"; fi

  log "1.2 SSH key + VM (ubuntu-noble, g4s.small, cloud-init)"
  t=$(date +%s)
  ssh-keygen -q -t ed25519 -N "" -f "$WORK/key" >/dev/null
  civo sshkey create "$SSHKEY" --key "$WORK/key.pub" >/dev/null && MADE_KEY=1 || fail "1.2 SSH key" "civo sshkey create gagal"
  if civo instance create "$VM" --size g4s.small --diskimage ubuntu-noble --initialuser civo \
      --sshkey "$SSHKEY" --firewall "$FW" --script "$ROOT/compute/cloud-init.sh" --wait >/dev/null; then
    MADE_VM=1; pass "1.2 VM ACTIVE" "$(since "$t")"
  else fail "1.2 VM ACTIVE" "civo instance create gagal"; fi
  VM_IP=$(civo instance show "$VM" -o custom -f public_ip 2>/dev/null | tr -d '[:space:]')
  log "IP VM: ${VM_IP:-tidak terbaca}"

  SSH=(ssh -i "$WORK/key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR "civo@$VM_IP")
  log "1.3 Tunggu SSH + cloud-init (git & Docker)"
  t=$(date +%s)
  if retry 480 "${SSH[@]}" test -f /var/log/civo-onboarding-ready; then
    pass "1.3 cloud-init selesai (git + Docker terpasang)" "$(since "$t")"
  else fail "1.3 cloud-init selesai" "file /var/log/civo-onboarding-ready belum ada setelah 8 menit; cek sudo tail /var/log/cloud-init-output.log"; fi

  log "1.4 Lab 1: git clone + docker compose (monolith)"
  t=$(date +%s)
  if "${SSH[@]}" "git clone -q https://github.com/dev-cer/bukutamu.git && cd bukutamu/compute/monolith && sudo docker compose up -d" >/dev/null 2>&1 \
     && retry 120 curl -fsS "http://$VM_IP:8080/healthz"; then
    curl -fsS -X POST -H 'Content-Type: application/json' -d '{"name":"Dry-run","city":"Jakarta","message":"tes VM"}' "http://$VM_IP:8080/api/entries" >/dev/null \
      && pass "1.4 Lab 1 monolith di http://$VM_IP:8080 (healthz + POST entri)" "$(since "$t")" \
      || fail "1.4 Lab 1 monolith" "healthz OK tapi POST /api/entries gagal"
  else fail "1.4 Lab 1 monolith" "http://$VM_IP:8080/healthz tidak merespons"; fi
fi

# ------------------------------------------------------------------ 2.1 Cluster
log "2.1 Buat cluster $CLUSTER (2 × g4s.kube.medium, cilium)"
t=$(date +%s)
if civo kubernetes create "$CLUSTER" --size g4s.kube.medium --nodes 2 --cni-plugin cilium \
    --create-firewall --firewall-rules "80;443;6443" --wait --save --switch >/dev/null; then
  MADE_K8S=1; pass "2.1 Cluster ACTIVE + kubeconfig tersimpan" "$(since "$t")"
else
  civo kubernetes show "$CLUSTER" >/dev/null 2>&1 && MADE_K8S=1   # terbuat sebagian → tetap dibersihkan
  fail "2.1 Cluster ACTIVE" "civo kubernetes create gagal"; exit 1
fi
t=$(date +%s)
if retry 240 kubectl wait --for=condition=Ready nodes --all --timeout=10s; then
  pass "2.1 kubectl get nodes: $(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ') node Ready" "$(since "$t")"
else fail "2.1 Node Ready" "node belum Ready setelah 4 menit"; fi

# ------------------------------------------------------------------ 2.2 Lab 2 microservice
log "2.2 Lab 2: deploy microservice + Ingress"
t=$(date +%s)
CLUSTER_DNS=$(civo kubernetes show "$CLUSTER" -o custom -f DNSEntry 2>/dev/null | tr -d '[:space:]')
MASTER_IP=$(civo kubernetes show "$CLUSTER" -o custom -f MasterIP 2>/dev/null | tr -d '[:space:]')
HOST="buku-tamu.$CLUSTER_DNS"
log "DNS cluster: ${CLUSTER_DNS:-tidak terbaca}  ·  Master IP: ${MASTER_IP:-?}"
mkdir -p "$WORK/k8s" && cp "$ROOT"/k8s/microservices/*.yaml "$WORK/k8s/"
sed -i.bak "s/GANTI_DENGAN_DNS_CLUSTER/$CLUSTER_DNS/" "$WORK/k8s/40-ingress.yaml" && rm -f "$WORK/k8s/"*.bak
if kubectl apply -f "$WORK/k8s/" >/dev/null \
   && kubectl rollout status deploy/api -n "$NS" --timeout=300s >/dev/null \
   && kubectl rollout status deploy/web -n "$NS" --timeout=300s >/dev/null; then
  pass "2.2 Pod api (1) dan web (2) Running" "$(since "$t")"
else fail "2.2 Pod Running" "rollout belum selesai; cek kubectl get pods,pvc -n $NS dan kubectl describe pod"; fi

t=$(date +%s)
if retry 180 curl -fsS "http://$HOST/healthz"; then
  pass "2.2 Ingress dapat diakses: http://$HOST" "$(since "$t")"
else
  if [ -n "$MASTER_IP" ] && curl -fsS -m 10 -H "Host: $HOST" "http://$MASTER_IP/healthz" >/dev/null 2>&1; then
    fail "2.2 Akses lewat DNS" "Ingress jalan via IP $MASTER_IP tapi nama $HOST tidak resolve → masalah DNS wildcard; ubah materi ke alternatif LoadBalancer/nip.io"
  else
    fail "2.2 Akses Ingress" "http://$HOST tidak merespons (juga via IP); cek kubectl get ingress,svc -n $NS dan Traefik di kube-system"
  fi
fi
t=$(date +%s)
MODE=$(curl -fsS "http://$HOST/api/info" 2>/dev/null | grep -o '"mode": *"[a-z]*"' | grep -o '[a-z]*"$' | tr -d '"')
if [ "$MODE" = "api" ] && curl -fsS -X POST -H 'Content-Type: application/json' \
     -d '{"name":"Dry-run","city":"Jakarta","message":"tes Kubernetes"}' "http://$HOST/api/entries" >/dev/null 2>&1; then
  pass "2.2 Mode microservices (/api/info) + POST entri lewat Ingress" "$(since "$t")"
else fail "2.2 API lewat Ingress" "mode='$MODE' atau POST /api/entries gagal"; fi

# ------------------------------------------------------------------ 2.3 Scale & self-healing
log "2.3 Scale web 2 → 4 dan uji self-healing"
t=$(date +%s)
kubectl scale deploy/web --replicas=4 -n "$NS" >/dev/null
if kubectl rollout status deploy/web -n "$NS" --timeout=180s >/dev/null; then
  PODS=$(for _ in $(seq 1 30); do curl -fsS -D - -o /dev/null "http://$HOST/api/info" 2>/dev/null | awk -F': ' 'tolower($1)=="x-web-pod"{print $2}' | tr -d '\r'; done | sort -u | grep -c .)
  if [ "${PODS:-0}" -ge 2 ]; then pass "2.3 Scale ke 4 pod; header X-Web-Pod berganti ($PODS pod berbeda dari 30 request)" "$(since "$t")"
  else fail "2.3 Load balancing antar pod" "hanya $PODS pod terlihat dari 30 request (bisa karena keep-alive Traefik; cek manual dengan refresh browser)"; fi
else fail "2.3 Scale web ke 4" "rollout tidak selesai"; fi

t=$(date +%s)
BEFORE=$(curl -fsS "http://$HOST/api/entries" 2>/dev/null | grep -o '"name"' | wc -l | tr -d ' ')
kubectl delete pod -l app=web -n "$NS" --wait=false >/dev/null
sleep 3
if kubectl rollout status deploy/web -n "$NS" --timeout=180s >/dev/null && retry 60 curl -fsS "http://$HOST/healthz"; then
  AFTER=$(curl -fsS "http://$HOST/api/entries" 2>/dev/null | grep -o '"name"' | wc -l | tr -d ' ')
  if [ "$AFTER" -ge "$BEFORE" ] && [ "$AFTER" -ge 1 ]; then
    pass "2.3 Self-healing: pod web dibuat ulang, data tetap ($AFTER entri)" "$(since "$t")"
  else fail "2.3 Data tetap ada" "entri sebelum=$BEFORE sesudah=$AFTER"; fi
else fail "2.3 Self-healing" "pod web tidak kembali Ready dalam 3 menit"; fi

log "Selesai. Buka http://$HOST di browser sekarang bila ingin melihat tampilannya (cleanup otomatis dimulai 20 detik lagi)."
[ "$KEEP" = 1 ] || sleep 20

# Buku Tamu Civo — contoh aplikasi onboarding

Aplikasi guestbook sederhana untuk latihan deploy ke **Civo Compute** dan **Civo Kubernetes**,
dalam dua arsitektur: **monolitik** dan **microservice**.

- Hanya memakai image resmi (`python:3.12-alpine`, `nginxinc/nginx-unprivileged`), jadi **tidak perlu build/push image**.
- Halaman web menampilkan nama container/pod yang melayani request, supaya efek scaling di Kubernetes terlihat.

## Mulai

```bash
git clone https://github.com/dev-cer/bukutamu.git
cd bukutamu
```

Tanpa git: unduh [ZIP](https://github.com/dev-cer/bukutamu/archive/refs/heads/main.zip), ekstrak,
lalu masuk ke folder `bukutamu-main`.

## Jalur lab

| Lab | Platform | Arsitektur | Folder |
|---|---|---|---|
| Utama (sesi 30 menit) | Civo Kubernetes | Microservice + Ingress | `k8s/microservices/` |
| Lab 1 (sesi 60 menit) | Civo Compute | Monolitik | `compute/monolith/` |
| Bonus 1 | Civo Compute | Microservice | `compute/microservices/` |
| Bonus 2 | Civo Kubernetes | Monolitik + Load Balancer | `k8s/monolith/` |

### Kubernetes (ringkas)

```bash
civo kubernetes create civo-onboarding --size g4s.kube.medium --nodes 2 \
  --cni-plugin cilium --create-firewall --firewall-rules "80;443;6443" --wait --save --switch

export CLUSTER_DNS=$(civo kubernetes show civo-onboarding -o custom -f DNSEntry)
sed -i.bak "s/GANTI_DENGAN_DNS_CLUSTER/$CLUSTER_DNS/" k8s/microservices/40-ingress.yaml
kubectl apply -f k8s/microservices/
echo http://buku-tamu.$CLUSTER_DNS

# bersihkan
kubectl delete -f k8s/microservices/
civo kubernetes remove civo-onboarding -y
```

## Struktur

```
app/
  app.py               # Python stdlib: halaman web + REST API, data di SQLite
  static/index.html    # tampilan web
  nginx/default.conf   # frontend nginx untuk versi microservices
compute/
  cloud-init.sh        # dipakai di --script saat membuat VM: memasang Docker
  monolith/docker-compose.yml       # 1 container   -> http://<IP_VM>:8080
  microservices/docker-compose.yml  # web + api     -> http://<IP_VM>
k8s/
  monolith/        # 1 Deployment + PVC + Service LoadBalancer
  microservices/   # api (PVC) + web (2 replika) + Ingress Traefik
scripts/gen_k8s.py # generate ulang ConfigMap bila kode di app/ diubah
```

## Arsitektur

| | Monolitik | Microservice |
|---|---|---|
| Komponen | `app` (web + API dalam 1 proses) | `web` (nginx) → `api` (Python) |
| Data | SQLite di volume | SQLite di volume milik `api` |
| Compute | port 8080 | port 80 |
| Kubernetes | Service **LoadBalancer** (Civo LB) | **Ingress** Traefik `buku-tamu.<DNS cluster>` |
| Scale | 1 replika (state di SQLite) | `web` bebas di-scale, `api` 1 replika |

## API

| Method | Path | Keterangan |
|---|---|---|
| GET | `/healthz` | health check |
| GET | `/api/info` | mode, versi, hostname |
| GET | `/api/entries` | 50 entri terakhir |
| POST | `/api/entries` | body JSON `{"name","city","message"}` |

## Jalankan di laptop (opsional)

```bash
MODE=monolith DATA_DIR=./data python3 app/app.py   # buka http://localhost:8080
```

## Catatan produksi

Contoh ini sengaja sederhana. Untuk produksi: build image sendiri ke registry, simpan data di
database terkelola (mis. Civo Database) agar API bisa >1 replika, dan pakai HTTPS (cert-manager).

Langkah lengkap ada di slide deck dan manual how-to onboarding.

---
Civo Indonesia · PT Arupa Cloud Nusantara · sales.id@civo.com


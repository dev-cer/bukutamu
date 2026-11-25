#!/usr/bin/env python3
"""Generate manifest Kubernetes (monolith & microservices) dari kode di folder app/.

Jalankan ulang setiap kali app/app.py, app/static/index.html, atau app/nginx/default.conf berubah:
    python3 scripts/gen_k8s.py
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(p):
    with open(os.path.join(ROOT, p), encoding="utf-8") as f:
        return f.read()


def block(text, indent):
    pad = " " * indent
    return "\n".join((pad + line) if line else "" for line in text.rstrip("\n").split("\n"))


def configmap(name, ns, files):
    out = [
        "apiVersion: v1",
        "kind: ConfigMap",
        "metadata:",
        f"  name: {name}",
        f"  namespace: {ns}",
        "  labels:",
        "    app.kubernetes.io/part-of: buku-tamu-civo",
        "data:",
    ]
    for key, path in files:
        out.append(f"  {key}: |")
        out.append(block(read(path), 4))
    return "# File ini di-generate oleh scripts/gen_k8s.py dari folder app/. Jangan edit manual.\n" + "\n".join(out) + "\n"


POD_SEC = """      securityContext:
        runAsNonRoot: true
        runAsUser: {uid}
        runAsGroup: {uid}
        fsGroup: {uid}
        seccompProfile:
          type: RuntimeDefault"""

CTR_SEC = """          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]"""

PROBES = """          readinessProbe:
            httpGet: {{ path: /healthz, port: 8080 }}
            initialDelaySeconds: 3
            periodSeconds: 5
          livenessProbe:
            httpGet: {{ path: /healthz, port: 8080 }}
            initialDelaySeconds: 10
            periodSeconds: 10"""


def ns_yaml(ns):
    return f"""apiVersion: v1
kind: Namespace
metadata:
  name: {ns}
  labels:
    app.kubernetes.io/part-of: buku-tamu-civo
"""


def pvc_yaml(name, ns):
    return f"""# Persistent volume di Civo (StorageClass default: civo-volume).
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {name}
  namespace: {ns}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: civo-volume
  resources:
    requests:
      storage: 1Gi
"""


def python_deploy(name, ns, mode, cm, pvc, static):
    items = "            - key: app.py\n              path: app.py"
    if static:
        items += "\n            - key: index.html\n              path: static/index.html"
    return f"""# {name}: Python (image resmi python:3.12-alpine) menjalankan app.py dari ConfigMap.
# 1 replika + strategi Recreate karena data disimpan di SQLite pada satu volume (ReadWriteOnce).
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {name}
  namespace: {ns}
  labels: {{ app: {name} }}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels: {{ app: {name} }}
  template:
    metadata:
      labels: {{ app: {name} }}
    spec:
{POD_SEC.format(uid=10001)}
      containers:
        - name: {name}
          image: python:3.12-alpine
          command: ["python", "/app/app.py"]
          env:
            - {{ name: MODE, value: "{mode}" }}
            - {{ name: DATA_DIR, value: /data }}
            - {{ name: PYTHONDONTWRITEBYTECODE, value: "1" }}
          ports:
            - containerPort: 8080
{PROBES.format()}
          resources:
            requests: {{ cpu: 50m, memory: 64Mi }}
            limits: {{ cpu: 250m, memory: 128Mi }}
{CTR_SEC}
          volumeMounts:
            - {{ name: code, mountPath: /app, readOnly: true }}
            - {{ name: data, mountPath: /data }}
            - {{ name: tmp, mountPath: /tmp }}
      volumes:
        - name: code
          configMap:
            name: {cm}
            items:
{items}
        - name: data
          persistentVolumeClaim:
            claimName: {pvc}
        - name: tmp
          emptyDir: {{}}
"""


def service(name, ns, selector, typ, port=80):
    return f"""apiVersion: v1
kind: Service
metadata:
  name: {name}
  namespace: {ns}
spec:
  type: {typ}
  selector: {{ app: {selector} }}
  ports:
    - name: http
      port: {port}
      targetPort: 8080
"""


WEB_DEPLOY = """# web: nginx (image resmi nginxinc/nginx-unprivileged) menyajikan halaman dan meneruskan /api ke service api.
# Stateless, jadi bisa di-scale bebas (kubectl scale deploy/web --replicas=3).
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: buku-tamu
  labels: { app: web }
spec:
  replicas: 2
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
%s
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: { app: web }
      containers:
        - name: web
          image: nginxinc/nginx-unprivileged:1.27-alpine
          ports:
            - containerPort: 8080
%s
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits: { cpu: 200m, memory: 64Mi }
%s
          volumeMounts:
            - { name: html, mountPath: /usr/share/nginx/html, readOnly: true }
            - { name: conf, mountPath: /etc/nginx/conf.d, readOnly: true }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: html
          configMap:
            name: web-files
            items:
            - key: index.html
              path: index.html
        - name: conf
          configMap:
            name: web-files
            items:
            - key: default.conf
              path: default.conf
        - name: tmp
          emptyDir: {}
""" % (POD_SEC.format(uid=101), PROBES.format(), CTR_SEC)

INGRESS = """# Ingress lewat Traefik (terpasang default di Civo Kubernetes).
# Ganti GANTI_DENGAN_DNS_CLUSTER dengan DNS cluster Anda:
#   civo kubernetes show civo-onboarding -o custom -f DNSEntry
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: buku-tamu
  namespace: buku-tamu
spec:
  ingressClassName: traefik
  rules:
    - host: buku-tamu.GANTI_DENGAN_DNS_CLUSTER
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 80
"""


def write(rel, text):
    p = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(text)
    print("tulis", rel)


if __name__ == "__main__":
    m, ns = "k8s/monolith/", "buku-tamu-mono"
    write(m + "00-namespace.yaml", ns_yaml(ns))
    write(m + "10-configmap.yaml", configmap("app-code", ns, [("app.py", "app/app.py"), ("index.html", "app/static/index.html")]))
    write(m + "20-pvc.yaml", pvc_yaml("app-data", ns))
    write(m + "30-deployment.yaml", python_deploy("app", ns, "monolith", "app-code", "app-data", True))
    write(m + "40-service-lb.yaml", "# Service tipe LoadBalancer -> Civo membuat Load Balancer dengan IP publik.\n" + service("app", ns, "app", "LoadBalancer"))

    s, ns = "k8s/microservices/", "buku-tamu"
    write(s + "00-namespace.yaml", ns_yaml(ns))
    write(s + "10-configmap-api.yaml", configmap("api-code", ns, [("app.py", "app/app.py")]))
    write(s + "11-configmap-web.yaml", configmap("web-files", ns, [("index.html", "app/static/index.html"), ("default.conf", "app/nginx/default.conf")]))
    write(s + "20-api-pvc.yaml", pvc_yaml("api-data", ns))
    write(s + "21-api-deployment.yaml", python_deploy("api", ns, "api", "api-code", "api-data", False))
    write(s + "22-api-service.yaml", "# Service internal (ClusterIP): hanya bisa diakses dari dalam cluster, mis. oleh nginx.\n" + service("api", ns, "api", "ClusterIP", 8080))
    write(s + "30-web-deployment.yaml", WEB_DEPLOY)
    write(s + "31-web-service.yaml", service("web", ns, "web", "ClusterIP"))
    write(s + "40-ingress.yaml", INGRESS)

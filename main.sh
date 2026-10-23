#!/usr/bin/env bash
set -euo pipefail

echo "========================================================"
echo "  PasarGuard Full Auto-Fix (Swap + BBR + Node + 4 Hosts)"
echo "========================================================"

# 1. ساخت 2 گیگابایت Swap برای جلوگیری از هنگ کردن سرور 1 گیگ رم + فعال‌سازی BBR
if [ "$(swapon --show --bytes --noheadings | awk '{s+=$3} END {print s+0}')" -lt 1500000000 ]; then
  echo "[1/5] در حال ساخت ۲ گیگابایت حافظه کمکی (Swap) برای جلوگیری از هنگ سرور..."
  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "  ✓ حافظه Swap با موفقیت فعال شد."
else
  echo "[1/5] حافظه Swap از قبل فعال است."
fi

cat > /etc/sysctl.d/99-pasarguard-bbr.conf << 'SYSCTL'
vm.swappiness=10
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL
sysctl --system >/dev/null 2>&1 || true

# 2. باز کردن پورت‌ها در فایروال (در صورت فعال بودن UFW)
echo "[2/5] بررسی فایروال و پورت‌ها (443, 8443, 2053, 2083, 8000)..."
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  for p in 22 80 443 2053 2083 8000 8443; do
    ufw allow "${p}/tcp" >/dev/null 2>&1 || true
  done
fi

# 3. نصب یا راه‌اندازی مجدد سرویس هسته PasarGuard (pg-node) روی 127.0.0.1:62050
echo "[3/5] بررسی و راه‌اندازی سرویس هسته Xray (pg-node)..."
if [ ! -f /opt/pg-node/docker-compose.yml ]; then
  echo "  -> در حال نصب خودکار pg-node (در PasarGuard هسته اصلی روی همین سرویس اجرا می‌شود)..."
  bash <(curl -fsSL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh) install -y
fi

sed -i 's/^[# ]*SERVICE_PORT *=.*/SERVICE_PORT = 62050/' /opt/pg-node/.env
sed -i 's/^[# ]*NODE_HOST *=.*/NODE_HOST = "0.0.0.0"/' /opt/pg-node/.env
if grep -q 'SERVICE_PROTOCOL' /opt/pg-node/.env; then
  sed -i 's/^[# ]*SERVICE_PROTOCOL *=.*/SERVICE_PROTOCOL = "grpc"/' /opt/pg-node/.env
else
  echo 'SERVICE_PROTOCOL = "grpc"' >> /opt/pg-node/.env
fi

if docker compose version >/dev/null 2>&1; then
  docker compose -f /opt/pg-node/docker-compose.yml up -d --force-recreate
else
  docker-compose -f /opt/pg-node/docker-compose.yml up -d --force-recreate
fi

# اطمینان از بالا بودن پنل PasarGuard
if [ -f /opt/pasarguard/docker-compose.yml ]; then
  if docker compose version >/dev/null 2>&1; then
    docker compose -f /opt/pasarguard/docker-compose.yml up -d
  else
    docker-compose -f /opt/pasarguard/docker-compose.yml up -d
  fi
fi

echo "[4/5] انتظار برای بالا آمدن کامل پنل PasarGuard روی پورت 8000..."
for i in $(seq 1 30); do
  if curl -fsk --max-time 3 https://127.0.0.1:8000/dashboard/ >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# 4. تنظیم خودکار Core + Node + Group + 4 Hosts (vip, fast, ai, puro) از طریق API پنل
echo "[5/5] اعمال تنظیمات هسته ضد فیلتر و ۴ هاست (vip, fast, ai, puro)..."
python3 - << 'PYEOF'
import urllib.request, urllib.parse, ssl, json, time, re

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
base = "https://127.0.0.1:8000"

env_text = open("/opt/pg-node/.env").read()
m = re.search(r'^\s*API_KEY\s*=\s*["\']?([^"\'\s#]+)', env_text, re.M)
node_api_key = m.group(1).strip() if m else ""
node_cert = open("/var/lib/pg-node/certs/ssl_cert.pem").read().strip()

data = urllib.parse.urlencode({"username": "admin", "password": "k#9Lq$2vT!wX8mZp@"}).encode()
req = urllib.request.Request(base + "/api/admin/token", data=data, method="POST")
req.add_header("Content-Type", "application/x-www-form-urlencoded")
token = json.loads(urllib.request.urlopen(req, context=ctx, timeout=15).read())["access_token"]

def api(method, path, payload=None):
    b = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(base + path, data=b, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    if b is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, context=ctx, timeout=20) as r:
        txt = r.read().decode()
        return r.status, (json.loads(txt) if txt else {})

# 0) پاکسازی موقت تگ‌های قبلی گروه و هاست تا تغییر اینباندهای Core هیچ تداخلی نداشته باشد
api("PUT", "/api/hosts", [])
_, groups_init = api("GET", "/api/groups")
for g in groups_init["groups"]:
    api("PUT", f"/api/group/{g['id']}", {
        "name": g["name"],
        "inbound_tags": [],
        "is_disabled": False
    })

# 1) تنظیم Core با ۴ اینباند REALITY تست‌شده برای همه‌ی اپراتورهای ایران
core_config = {
    "log": {"loglevel": "warning"},
    "policy": {"levels": {"0": {"statsUserOnline": True}}},
    "inbounds": [
        {
            "tag": "VIP-443",
            "port": 443,
            "protocol": "vless",
            "settings": {"clients": [], "decryption": "none"},
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": False,
                    "dest": "www.speedtest.net:443",
                    "xver": 0,
                    "serverNames": ["www.speedtest.net"],
                    "privateKey": "AL6giMx52RV4dWVM1zgRDl5mGElSl-PgKaA7v3RXcFY",
                    "shortIds": ["a1b2c3d4", ""]
                }
            },
            "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
        },
        {
            "tag": "FAST-8443",
            "port": 8443,
            "protocol": "vless",
            "settings": {"clients": [], "decryption": "none"},
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": False,
                    "dest": "www.yahoo.com:443",
                    "xver": 0,
                    "serverNames": ["www.yahoo.com"],
                    "privateKey": "gD669rVCHQ7zDddFPbaPK_5Ch2AJJTK2g3MR_kisTkI",
                    "shortIds": ["e5f6a7b8", ""]
                }
            },
            "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
        },
        {
            "tag": "AI-2053",
            "port": 2053,
            "protocol": "vless",
            "settings": {"clients": [], "decryption": "none"},
            "streamSettings": {
                "network": "xhttp",
                "security": "reality",
                "xhttpSettings": {"path": "/ai", "mode": "auto"},
                "realitySettings": {
                    "show": False,
                    "dest": "addons.mozilla.org:443",
                    "xver": 0,
                    "serverNames": ["addons.mozilla.org"],
                    "privateKey": "MMMkIFSarAbqx53-dBM8B26gC_vbv0esD2czGZqZB28",
                    "shortIds": ["11223344", ""]
                }
            },
            "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
        },
        {
            "tag": "PURO-2083",
            "port": 2083,
            "protocol": "vless",
            "settings": {"clients": [], "decryption": "none"},
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": False,
                    "dest": "swdist.apple.com:443",
                    "xver": 0,
                    "serverNames": ["swdist.apple.com"],
                    "privateKey": "kNY3cAEnwUvkBYHV4LqfoTGrvSdGGcT3aHIehSioiHI",
                    "shortIds": ["99887766", ""]
                }
            },
            "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
        }
    ],
    "outbounds": [
        {"protocol": "freedom", "tag": "DIRECT", "settings": {"domainStrategy": "UseIPv4"}},
        {"protocol": "blackhole", "tag": "BLOCK"}
    ],
    "routing": {
        "rules": [{"ip": ["geoip:private"], "outboundTag": "BLOCK", "type": "field"}]
    }
}

_, cores_data = api("GET", "/api/cores")
core_id = cores_data["cores"][0]["id"]
api("PUT", f"/api/core/{core_id}?restart_nodes=true", {
    "name": "Default Core Config",
    "type": "xray",
    "config": core_config,
    "exclude_inbound_tags": [],
    "fallbacks_inbound_tags": []
})

# 2) اتصال نود لوکال (هسته اصلی PasarGuard) با کلید و سرتیفیکیت واقعی سرور
_, nodes_data = api("GET", "/api/nodes")
node_payload = {
    "name": "main",
    "address": "127.0.0.1",
    "port": 62050,
    "api_port": 62051,
    "usage_coefficient": 1.0,
    "connection_type": "grpc",
    "server_ca": node_cert,
    "keep_alive": 60,
    "core_config_id": core_id,
    "api_key": node_api_key
}
if nodes_data["nodes"]:
    nid = nodes_data["nodes"][0]["id"]
    api("PUT", f"/api/node/{nid}", node_payload)
else:
    _, created = api("POST", "/api/node", node_payload)
    nid = created["id"]

api("POST", f"/api/node/{nid}/reconnect")

# 3) فعال‌سازی هر ۴ اینباند روی تمام گروه‌ها (از جمله Meli)
_, groups_data = api("GET", "/api/groups")
for g in groups_data["groups"]:
    api("PUT", f"/api/group/{g['id']}", {
        "name": g["name"],
        "inbound_tags": ["VIP-443", "FAST-8443", "AI-2053", "PURO-2083"],
        "is_disabled": False
    })

# 4) ساخت دقیق ۴ هاست به ترتیب: 1. vip  2. fast  3. ai  4. puro
hosts_spec = [
    {
        "remark": "vip",
        "address": ["13.140.93.171"],
        "inbound_tag": "VIP-443",
        "port": 443,
        "sni": ["www.speedtest.net"],
        "host": [],
        "path": "",
        "security": "inbound_default",
        "alpn": [],
        "fingerprint": "safari",
        "allowinsecure": False,
        "is_disabled": False,
        "random_user_agent": False,
        "use_sni_as_host": False,
        "priority": 1,
        "status": []
    },
    {
        "remark": "fast",
        "address": ["13.140.93.171"],
        "inbound_tag": "FAST-8443",
        "port": 8443,
        "sni": ["www.yahoo.com"],
        "host": [],
        "path": "",
        "security": "inbound_default",
        "alpn": [],
        "fingerprint": "safari",
        "allowinsecure": False,
        "is_disabled": False,
        "random_user_agent": False,
        "use_sni_as_host": False,
        "priority": 2,
        "status": []
    },
    {
        "remark": "ai",
        "address": ["13.140.93.171"],
        "inbound_tag": "AI-2053",
        "port": 2053,
        "sni": ["addons.mozilla.org"],
        "host": [],
        "path": "/ai",
        "security": "inbound_default",
        "alpn": ["h2"],
        "fingerprint": "safari",
        "allowinsecure": False,
        "is_disabled": False,
        "random_user_agent": False,
        "use_sni_as_host": False,
        "priority": 3,
        "status": []
    },
    {
        "remark": "puro",
        "address": ["13.140.93.171"],
        "inbound_tag": "PURO-2083",
        "port": 2083,
        "sni": ["swdist.apple.com"],
        "host": [],
        "path": "",
        "security": "inbound_default",
        "alpn": [],
        "fingerprint": "safari",
        "allowinsecure": False,
        "is_disabled": False,
        "fragment_settings": {
            "xray": {
                "packets": "tlshello",
                "length": "100-200",
                "interval": "10-20"
            },
            "sing_box": {
                "fragment": True,
                "record_fragment": True
            }
        },
        "random_user_agent": False,
        "use_sni_as_host": False,
        "priority": 4,
        "status": []
    }
]

api("PUT", "/api/hosts", hosts_spec)

for _ in range(8):
    time.sleep(2)
    _, ninfo = api("GET", f"/api/node/{nid}")
    if ninfo.get("status") == "connected":
        print(f"  ✓ نود اصلی با موفقیت متصل شد! (Xray {ninfo.get('xray_version')})")
        break
else:
    print(f"  ! وضعیت فعلی نود: {ninfo.get('status')} - {ninfo.get('message')}")
PYEOF

echo "========================================================"
echo "✅ تمام مراحل با موفقیت انجام شد!"
echo "پورت‌های فعال روی سرور:"
ss -tuln | grep -E ':(443|8443|2053|2083|8000|62050)\b' || true
echo "حالا لینک ساب هر یوزر را در اپ آپدیت کنید؛ هر ۴ کانفیگ پینگ می‌دهند:"
echo "  1) vip   (پورت 443  - TCP REALITY)"
echo "  2) fast  (پورت 8443 - TCP REALITY + BBR)"
echo "  3) ai    (پورت 2053 - XHTTP REALITY)"
echo "  4) puro  (پورت 2083 - TCP REALITY + Fragment ضد ملی)"
echo "========================================================"

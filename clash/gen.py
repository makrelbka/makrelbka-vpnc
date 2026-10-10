#!/usr/bin/env python3
"""Build ONE self-contained mihomo (Clash.Meta) config.yaml.

- fetches the subscription URL (base64 list of vless:// links) and converts nodes to `proxies:`
  (falls back to clash/sub.cache if the download fails)
- inlines rules from vpnc-rules.local.json
Re-run to refresh (clash/vpnc-clash.plist does it on JSON change + every 10 min).

Usage: gen.py [--url URL] [--rules FILE] [--out DIR]
URL defaults to $VPNC_SUB_URL or clash/subscription.url.
"""
import argparse, base64, gzip, json, os, re, subprocess, sys
import urllib.parse as up
from pathlib import Path

HERE = Path(__file__).resolve().parent
q = json.dumps  # JSON string == valid YAML double-quoted scalar
SKIP = re.compile(r"Торрент|Белые списки")   # torrent-only / whitelist-CDN nodes


def fetch(url):
    cache = HERE / "sub.cache"
    try:
        # curl instead of urllib: macOS system python has no CA bundle
        raw = subprocess.run(["curl", "-fsSL", "-m", "20", "-A", "clash.meta", url],
                             check=True, capture_output=True).stdout
        if raw[:2] == b"\x1f\x8b":
            raw = gzip.decompress(raw)
        cache.write_bytes(raw)
    except Exception as e:
        if not cache.exists():
            sys.exit(f"subscription fetch failed and no cache: {e}")
        print(f"warn: fetch failed ({e}), using cache", file=sys.stderr)
        raw = cache.read_bytes()
    txt = raw.decode().strip()
    if "://" not in txt:
        txt = base64.b64decode(txt + "=" * (-len(txt) % 4)).decode()
    return [l.strip() for l in txt.splitlines() if l.strip()]


def vless_to_proxy(link, name):
    p = up.urlparse(link)
    a = {k: v[0] for k, v in up.parse_qs(p.query).items()}
    net = a.get("type", "tcp")
    px = {"name": name, "type": "vless", "server": p.hostname, "port": p.port,
          "uuid": p.username, "udp": True, "network": net,
          "tls": a.get("security") in ("tls", "reality"),
          "client-fingerprint": a.get("fp", "chrome")}
    if a.get("sni"): px["servername"] = a["sni"]
    if a.get("flow"): px["flow"] = a["flow"]
    if a.get("alpn"): px["alpn"] = a["alpn"].split(",")
    if a.get("security") == "reality":
        px["reality-opts"] = {"public-key": a.get("pbk", ""), "short-id": a.get("sid", "")}
    if net == "ws":
        px["ws-opts"] = {"path": a.get("path", "/"), "headers": {"Host": a.get("host") or a.get("sni", "")}}
    elif net == "xhttp":
        o = {"path": a.get("path", "/"), "mode": a.get("mode", "auto")}
        if a.get("host"): o["host"] = a["host"]
        px["xhttp-opts"] = o
    return px


def proxies_from(url):
    out, names = [], {}
    for l in fetch(url):
        if not l.startswith("vless://"):
            continue
        name = up.unquote(up.urlparse(l).fragment) or "node"
        if SKIP.search(name):
            continue
        names[name] = names.get(name, 0) + 1
        if names[name] > 1:
            name += f" #{names[name]}"
        out.append(vless_to_proxy(l, name))
    return out


def rule_lines(r):
    """One vpnc rule -> list of mihomo rule strings, sans target."""
    parts = []
    for s in r.get("domain_suffix", []): parts.append(f"DOMAIN-SUFFIX,{s}")
    for s in r.get("domain", []): parts.append(f"DOMAIN,{s}")
    for s in r.get("domain_keyword", []): parts.append(f"DOMAIN-KEYWORD,{s}")
    for s in r.get("process_name", []): parts.append(f"PROCESS-NAME,{s}")
    for s in r.get("ip_cidr", []):
        parts.append(f"IP-CIDR6,{s},no-resolve" if ":" in s else f"IP-CIDR,{s},no-resolve")
    for s in r.get("port", []): parts.append(f"DST-PORT,{s}")
    for s in r.get("network", []): parts.append(f"NETWORK,{s}")
    return parts


def with_target(rule, tgt):
    """mihomo wants `TYPE,value,TARGET[,no-resolve]`."""
    if rule.endswith(",no-resolve"):
        return f"{rule[:-len(',no-resolve')]},{tgt},no-resolve"
    return f"{rule},{tgt}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url")
    ap.add_argument("--rules", default=str(HERE.parent / "vpnc-rules.local.json"))
    ap.add_argument("--out", default=str(HERE))
    a = ap.parse_args()

    url = a.url or os.environ.get("VPNC_SUB_URL")
    if not url and (HERE / "subscription.url").exists():
        url = (HERE / "subscription.url").read_text().strip()
    if not url:
        sys.exit("no subscription URL (--url / $VPNC_SUB_URL / clash/subscription.url)")

    proxies = proxies_from(url)
    if not proxies:
        sys.exit("no vless nodes found in subscription")

    rules = []
    for r in json.load(open(a.rules))["rules"]:
        if not r.get("switch", True):
            continue
        tgt = "DIRECT" if r.get("outbound", "direct") == "direct" else "GLOBAL"
        parts = rule_lines(r)
        if len({p.split(",")[0] for p in parts}) > 1 and not r.get("or", False):
            rules.append(f"AND,(({'),('.join(parts)})),{tgt}")  # all fields must match
        else:
            rules += [with_target(p, tgt) for p in parts]

    names = [p["name"] for p in proxies]
    y = ["# generated by clash/gen.py — do not edit (contains node secrets, gitignored)",
         "mixed-port: 7890", "allow-lan: false", "mode: rule", "log-level: info",
         "unified-delay: true", "",
         "dns:", "  enable: true", "  ipv6: false", "  enhanced-mode: fake-ip",
         "  default-nameserver: [1.1.1.1, 8.8.8.8]",
         '  nameserver: ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]',
         '  proxy-server-nameserver: ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]', "",
         "proxies:"]
    y += [f"  - {json.dumps(p, ensure_ascii=False)}" for p in proxies]  # JSON flow map = valid YAML
    y += ["", "proxy-groups:",
          "  - name: GLOBAL", "    type: select",
          f"    proxies: {json.dumps(['AUTO'] + names, ensure_ascii=False)}",
          "  - name: AUTO", "    type: url-test",
          f"    proxies: {json.dumps(names, ensure_ascii=False)}",
          "    url: \"https://www.gstatic.com/generate_204\"", "    interval: 300", "    tolerance: 50",
          "", "rules:"]
    y += [f"  - {q(r, ensure_ascii=False)}" for r in rules] + ["  - MATCH,GLOBAL", ""]

    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    (out / "config.yaml").write_text("\n".join(y))
    print(f"ok: {len(proxies)} proxies, {len(rules)} rules -> {out / 'config.yaml'}")


if __name__ == "__main__":
    main()

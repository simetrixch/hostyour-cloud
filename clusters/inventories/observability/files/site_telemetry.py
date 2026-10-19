"""The read API of the site statistics: what a website's admin shows as Visitors and Security.

Counted here, on the observability plane, from the ingress log and from the sign-in failures the
identity provider logs, so the engines of a tenant do no work per request and store nothing. One
caller reads one website of one tenant: the gate below is the only thing between a caller and the
visitors of every other tenant, so every refusal is a 403 with the same body and every path to a
figure goes through `authorize`.

  GET /api/v1/site-telemetry/visitors?tenant=<guid>-<stage>&site=<name>&range=24h|7d|30d[&filters]
  GET /api/v1/site-telemetry/security?tenant=<guid>-<stage>&site=<name>&range=24h|7d|30d[&filters]

Standard library only, so the pod runs on the stock python image and installs nothing at boot.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOKI_URL = os.environ["LOKI_URL"]
NAMESPACE = os.environ["POD_NAMESPACE"]
KUBERNETES_API = os.environ.get("KUBERNETES_API_URL", "https://kubernetes.default.svc")
TOKEN_FILE = os.environ.get("KUBERNETES_TOKEN_FILE", "/var/run/secrets/kubernetes.io/serviceaccount/token")
CA_FILE = os.environ.get("KUBERNETES_CA_FILE", "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
JWKS_URL = os.environ.get("JWKS_URL_TEMPLATE", "https://{host}/auth/.well-known/jwks.json")
PORT = int(os.environ.get("LISTEN_PORT", "8080"))
MAX_LINES = int(os.environ.get("MAX_LINES", "200000"))
CACHE_SECONDS = int(os.environ.get("CACHE_SECONDS", "60"))
SESSION_GAP = timedelta(minutes=30)
RANGES = {"24h": timedelta(hours=24), "7d": timedelta(days=7), "30d": timedelta(days=30)}
PAGE = 5000

TENANT = re.compile(r"^[a-z0-9]+-(?:dev|test|prod)$")
SITE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
HOST = re.compile(r"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$")
STATIC = re.compile(r"\.(?:js|css|map|png|jpe?g|gif|svg|ico|webp|avif|woff2?|ttf|otf|eot|txt|xml|json|webmanifest|mp4|webm|pdf)$", re.I)
PROBE_AGENT = re.compile(r"Digita-Smoke|kube-probe|Uptime", re.I)
SCANNER_PATH = re.compile(r"(?:^|/)(?:\.env|\.git|wp-login\.php|wp-admin|xmlrpc\.php|phpmyadmin|cgi-bin)", re.I)
AUTH_FAILURES = {"login_failed", "login_locked", "2fa_failed"}
SHA256_DIGEST_INFO = bytes.fromhex("3031300d060960864801650304020105000420")

# Hashes of one process lifetime: a restart changes every ipHash, so a hash is never a durable
# identifier of a visitor, which is what a visitor's privacy needs.
PROCESS_SECRET = secrets.token_bytes(32)
LOKI_SLOTS = threading.BoundedSemaphore(4)
_cache = {}
_cache_lock = threading.Lock()


class Refused(Exception):
    """Every refusal of the gate: the caller learns nothing of the reason."""


def b64decode(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def fetch_json(url, headers=None, context=None, timeout=15):
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers or {}), timeout=timeout, context=context) as answer:
        return json.loads(answer.read())


_registrations = (0.0, {})


def registrations():
    """The facts of every tenant, by `<guid>-<stage>`, from the ConfigMaps the registrations render."""
    global _registrations
    fetched, known = _registrations
    if time.monotonic() - fetched < CACHE_SECONDS:
        return known
    with open(TOKEN_FILE) as handle:
        token = handle.read().strip()
    context = ssl.create_default_context(cafile=CA_FILE) if KUBERNETES_API.startswith("https") else None
    selector = urllib.parse.quote("platform/site-telemetry-registration=true", safe="")
    listing = fetch_json(f"{KUBERNETES_API}/api/v1/namespaces/{NAMESPACE}/configmaps?labelSelector={selector}",
                         {"Authorization": f"Bearer {token}"}, context)
    known = {}
    for item in listing.get("items", []):
        try:
            facts = json.loads(item["data"]["registration.json"])
            if TENANT.match(facts["tenant"]) and all(HOST.match(host) for host in facts["hosts"] + facts["issuers"]):
                known[facts["tenant"]] = facts
        except (KeyError, TypeError, ValueError):
            log("a registration ConfigMap is unreadable and is ignored")
    _registrations = (time.monotonic(), known)
    return known


_jwks = {}


def signing_keys(host, kid):
    """The keys the tenant's identity provider publishes, fetched from a host its registration names."""
    fetched, keys = _jwks.get(host, (0.0, {}))
    age = time.monotonic() - fetched
    if age > 300 or (kid not in keys and age > 30):
        keys = {key["kid"]: key for key in fetch_json(JWKS_URL.format(host=host)).get("keys", []) if "kid" in key}
        _jwks[host] = (time.monotonic(), keys)
    return keys


def verify_rs256(signing_input, signature, jwk):
    modulus = int.from_bytes(b64decode(jwk["n"]), "big")
    size = (modulus.bit_length() + 7) // 8
    if jwk.get("kty") != "RSA" or size < 256 or len(signature) != size:
        return False
    padded = pow(int.from_bytes(signature, "big"), int.from_bytes(b64decode(jwk["e"]), "big"), modulus).to_bytes(size, "big")
    expected = b"\x00\x01" + b"\xff" * (size - len(SHA256_DIGEST_INFO) - 35) + b"\x00" + SHA256_DIGEST_INFO + hashlib.sha256(signing_input).digest()
    return hmac.compare_digest(padded, expected)


def authorize(headers, query):
    """The tenant's facts, once the bearer token is the tenant's and its roles reach `site`."""
    tenant, site = query.get("tenant", ""), query.get("site", "")
    if not (TENANT.match(tenant) and SITE.match(site)):
        raise Refused
    facts = registrations().get(tenant)
    scheme, _, token = headers.get("Authorization", "").partition(" ")
    parts = token.split(".")
    if facts is None or scheme != "Bearer" or len(parts) != 3:
        raise Refused
    try:
        header, claims = (json.loads(b64decode(part)) for part in parts[:2])
        issuer = claims["iss"]
        host = issuer.removeprefix("https://").removesuffix("/auth")
        # The key set is fetched from a host the registration names, never from one the token names.
        if header["alg"] != "RS256" or claims["typ"] != "access" or f"https://{host}/auth" != issuer or host not in facts["issuers"]:
            raise Refused
        if not isinstance(claims["exp"], (int, float)) or claims["exp"] < time.time() - 30:
            raise Refused
        key = signing_keys(host, header["kid"]).get(header["kid"])
        roles = claims["roles"]
        if key is None or not isinstance(roles, list) or not verify_rs256(f"{parts[0]}.{parts[1]}".encode(), b64decode(parts[2]), key):
            raise Refused
    except (KeyError, TypeError, ValueError, AttributeError, urllib.error.URLError, OSError):
        raise Refused from None
    if "Administrator" not in roles and f"{site}:Administrator" not in roles:
        raise Refused
    return facts


def website_of(facts, site):
    return next((entry for entry in facts["sites"] if entry["name"] == site), None)


def site_of_path(facts, path):
    """The website a path belongs to: the longest registered sitePath it stands under."""
    best, owner = -1, None
    for entry in facts["sites"]:
        prefixes = [entry["sitePath"].rstrip("/") or "/"] + (["/"] if entry.get("main") else [])
        for prefix in prefixes:
            if (prefix == "/" or path == prefix or path.startswith(prefix + "/")) and len(prefix) > best:
                best, owner = len(prefix), entry["name"]
    return owner


def loki_lines(selector, start, end, counted):
    """Log lines of one selector, oldest first, at most MAX_LINES in all."""
    with LOKI_SLOTS:
        while counted["lines"] < MAX_LINES:
            query = urllib.parse.urlencode({"query": selector, "start": start, "end": end, "limit": PAGE, "direction": "forward"})
            result = fetch_json(f"{LOKI_URL}/loki/api/v1/query_range?{query}", timeout=60)["data"]["result"]
            entries = sorted((int(stamp), line) for stream in result for stamp, line in stream["values"])
            for entry in entries:
                yield entry
            counted["lines"] += len(entries)
            if len(entries) < PAGE:
                return
            start = entries[-1][0] + 1
        counted["truncated"] = True


def client_hash(address, moment):
    """The visitor's address as 12 hex characters that change with the day, or None for an edge."""
    host = address.rsplit(":", 1)[0].strip("[]")
    day = moment.strftime("%Y-%m-%d").encode()
    salt = hmac.new(PROCESS_SECRET, day, hashlib.sha256).digest()
    return hashlib.sha256(salt + host.encode()).hexdigest()[:12]


def classify_agent(agent):
    text = agent.lower()
    device = ("bot" if re.search(r"bot|crawl|spider|slurp|headless", text)
              else "tablet" if re.search(r"ipad|tablet", text)
              else "mobile" if re.search(r"mobi|iphone|android", text) else "desktop")
    browser = ("Edge" if re.search(r"edg(?:e|a|ios)?/", text) else "Opera" if re.search(r"opr/|opera", text)
               else "Firefox" if re.search(r"firefox/|fxios", text) else "Chrome" if re.search(r"chrome/|crios", text)
               else "Safari" if "safari/" in text else "other")
    system = ("iOS" if re.search(r"iphone|ipad|ipod", text) else "Android" if "android" in text
              else "Windows" if "windows" in text else "macOS" if re.search(r"mac os x|macintosh", text)
              else "Linux" if re.search(r"linux|x11", text) else "other")
    return device, browser, system


def traffic(facts, tenant, site, begin, end, counted):
    """Every request the ingress answered for the site's pages, with the query already cut off."""
    hosts = sorted(set(facts["hosts"]))
    pattern = "|".join(re.escape(host) for host in hosts)
    selector = f'{{namespace="ingress",container="traefik"}} |~ `"RequestHost":"(?i:{pattern})"`'
    proxied = set(facts.get("proxiedHosts", []))
    for stamp, line in loki_lines(selector, begin, end, counted):
        try:
            entry = json.loads(line)
            host = entry["RequestHost"].lower()
            path = entry["RequestPath"].split("?", 1)[0].split("#", 1)[0] or "/"
            status = int(entry["DownstreamStatus"])
        except (KeyError, TypeError, ValueError, AttributeError):
            continue
        if host not in hosts or not entry.get("RouterName", "").startswith(f"{tenant}-digita-web-") or site_of_path(facts, path) != site:
            continue
        moment = datetime.fromtimestamp(stamp / 1e9, timezone.utc)
        device, browser, system = classify_agent(entry.get("request_User-Agent", ""))
        yield {
            "time": moment, "path": path, "status": status, "agent": entry.get("request_User-Agent", ""),
            "referrer": urllib.parse.urlsplit(entry.get("request_Referer", "")).hostname or None,
            "country": entry.get("request_Cf-Ipcountry") or None,
            "device": device, "browser": browser, "os": system,
            # Behind Cloudflare the socket peer is the edge, so no visitor can be told from another.
            "ipHash": None if host in proxied else client_hash(entry.get("ClientAddr", ""), moment),
        }


def sign_in_failures(tenant, site, begin, end, counted):
    selector = f'{{namespace="{tenant}"}} |= `"type":"site_attack"`'
    for stamp, line in loki_lines(selector, begin, end, counted):
        try:
            entry = json.loads(line)
            if entry["type"] != "site_attack" or entry["service"] != "digita-auth" or entry["site"] != site or entry["category"] not in AUTH_FAILURES:
                continue
            yield {"time": datetime.fromtimestamp(stamp / 1e9, timezone.utc), "category": entry["category"], "action": "blocked",
                   "statusCode": int(entry.get("statusCode", 401)), "path": str(entry.get("path", "")),
                   "country": entry.get("country") or None, "ipHash": entry.get("ipHash") or None}
        except (KeyError, TypeError, ValueError):
            continue


def is_page_view(event):
    path = event["path"]
    return (200 <= event["status"] < 300 and not PROBE_AGENT.search(event["agent"]) and not STATIC.search(path)
            and not path.startswith(("/_next/", "/api/", "/health")))


def security_category(event):
    path, status = event["path"], event["status"]
    if SCANNER_PATH.search(path):
        return "scanner_probe", ("blocked" if 400 <= status < 500 else "allowed")
    if status == 429:
        return "rate_limit_429", "blocked"
    if path.endswith(("/api/contact", "/api/record")) and status in (400, 403, 413, 415):
        # Traefik carries the status and not the reason, so a forged signature and a honeypot catch
        # cannot be told apart here.
        return "form_rejected", "blocked"
    return None


def buckets(begin, end, span):
    step = timedelta(hours=1) if span <= timedelta(hours=24) else timedelta(days=1)
    start = begin.replace(minute=0, second=0, microsecond=0)
    if step == timedelta(days=1):
        start = start.replace(hour=0)
    return step, [start + step * index for index in range(int((end - start) / step) + 1)]


def ranked(counter, limit=10):
    return [{"key": key, "count": count} for key, count in sorted(counter.items(), key=lambda pair: (-pair[1], str(pair[0]))) if key is not None][:limit]


def paged(events, query, shape):
    size = max(1, min(200, int(query.get("pageSize", "50"))))
    page = max(1, int(query.get("page", "1")))
    newest = sorted(events, key=lambda event: event["time"], reverse=True)
    return {"page": page, "pageSize": size, "total": len(newest),
            "items": [shape(event) for event in newest[(page - 1) * size:page * size]]}


def visitors_report(facts, tenant, site, span, query, begin, end):
    counted = {"lines": 0, "truncated": False}
    filters = {"path": "path", "referrer": "referrer", "country": "country", "device": "device", "browser": "browser", "os": "os"}
    events = [event for event in traffic(facts, tenant, site, begin, end, counted) if is_page_view(event)
              and all(event[field] == query[name] for name, field in filters.items() if name in query)]
    keyed = all(event["ipHash"] is not None for event in events)
    sessions, last = [], {}
    for event in sorted(events, key=lambda event: event["time"]):
        who = event["ipHash"]
        if who is not None and who in last and event["time"] - last[who][-1] <= SESSION_GAP:
            last[who].append(event["time"])
        elif who is not None:
            last[who] = [event["time"]]
            sessions.append(last[who])
    step, slots = buckets(begin, end, span)
    series = {slot: {"pageviews": 0, "visitors": set()} for slot in slots}
    for event in events:
        slot = series[max(slot for slot in slots if slot <= event["time"])] if event["time"] >= slots[0] else None
        if slot is not None:
            slot["pageviews"] += 1
            slot["visitors"].add(event["ipHash"])
    counters = {name: {} for name in ("topPages", "referrers", "countries", "devices", "browsers", "operatingSystems")}
    for event in events:
        for name, value in (("topPages", event["path"]), ("referrers", event["referrer"]), ("countries", event["country"]),
                            ("devices", event["device"]), ("browsers", event["browser"]), ("operatingSystems", event["os"])):
            counters[name][value] = counters[name].get(value, 0) + 1
    return {
        "site": site, "range": query["range"], "from": begin.isoformat(), "to": end.isoformat(), "truncated": counted["truncated"],
        "kpis": {"uniqueVisitors": len({event["ipHash"] for event in events}) if keyed else None,
                 "visits": len(sessions) if keyed else None, "pageviews": len(events),
                 "bounceRate": (sum(1 for session in sessions if len(session) == 1) / len(sessions) if sessions else 0.0) if keyed else None},
        "timeline": [{"time": slot.isoformat(), "pageviews": series[slot]["pageviews"],
                      "uniqueVisitors": len(series[slot]["visitors"]) if keyed else None} for slot in slots],
        **{name: ranked(counter) for name, counter in counters.items()},
        "requests": paged(events, query, lambda event: {k: event[k] for k in ("path", "status", "referrer", "country", "device", "browser", "os", "ipHash")} | {"time": event["time"].isoformat()}),
    }


def security_report(facts, tenant, site, span, query, begin, end):
    counted = {"lines": 0, "truncated": False}
    events = []
    for event in traffic(facts, tenant, site, begin, end, counted):
        found = security_category(event)
        if found is not None:
            events.append({**event, "category": found[0], "action": found[1], "statusCode": event["status"]})
    events += list(sign_in_failures(tenant, site, begin, end, counted))
    filters = {"category": "category", "action": "action", "country": "country", "path": "path", "ipHash": "ipHash"}
    events = [event for event in events if all(event[field] == query[name] for name, field in filters.items() if name in query)
              and ("statusCode" not in query or str(event["statusCode"]) == query["statusCode"])]
    by = lambda field: {key: sum(1 for event in events if event[field] == key) for key in {event[field] for event in events}}
    step, slots = buckets(begin, end, span)
    timeline = {slot: 0 for slot in slots}
    for event in events:
        if event["time"] >= slots[0]:
            timeline[max(slot for slot in slots if slot <= event["time"])] += 1
    categories = by("category")
    return {
        "site": site, "range": query["range"], "from": begin.isoformat(), "to": end.isoformat(), "truncated": counted["truncated"],
        "kpis": {"blockedAttacks": sum(1 for event in events if event["action"] == "blocked"),
                 "scannerProbes": categories.get("scanner_probe", 0),
                 "botFormBlocks": categories.get("rate_limit_429", 0) + categories.get("form_rejected", 0),
                 "signInFailures": sum(categories.get(name, 0) for name in AUTH_FAILURES)},
        "timeline": [{"time": slot.isoformat(), "count": count} for slot, count in timeline.items()],
        "categories": ranked(categories), "countries": ranked(by("country")), "attackers": ranked(by("ipHash")),
        "requests": paged(events, query, lambda event: {k: event[k] for k in ("category", "action", "statusCode", "path", "country", "ipHash")} | {"time": event["time"].isoformat()}),
    }


REPORTS = {"visitors": visitors_report, "security": security_report}


def report(kind, facts, query):
    span = RANGES.get(query.get("range", ""))
    if span is None:
        return 400, {"error": "range"}
    site = query["site"]
    if website_of(facts, site) is None:
        return 404, {"error": "unknown_site"}
    key = (kind, facts["tenant"], tuple(sorted(query.items())))
    with _cache_lock:
        cached = _cache.get(key)
        if cached and cached[0] > time.monotonic():
            return 200, cached[1]
    end = datetime.now(timezone.utc)
    begin = end - span
    try:
        body = REPORTS[kind](facts, facts["tenant"], site, span, query, begin, end)
    except ValueError:
        return 400, {"error": "query"}
    with _cache_lock:
        if len(_cache) >= 256:
            _cache.pop(next(iter(_cache)))
        _cache[key] = (time.monotonic() + CACHE_SECONDS, body)
    return 200, body


def log(message):
    print(message, file=sys.stderr, flush=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "site-telemetry"

    def reply(self, status, body, origin=None):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Vary", "Origin")
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Headers", "authorization")
        self.end_headers()
        self.wfile.write(payload)

    def route(self):
        url = urllib.parse.urlsplit(self.path)
        query = {key: values[0] for key, values in urllib.parse.parse_qs(url.query).items()}
        return url.path, query

    def do_OPTIONS(self):
        path, query = self.route()
        try:
            facts = registrations().get(query.get("tenant", ""))
            origin = self.headers.get("Origin", "")
            if facts is None or origin.removeprefix("https://") not in facts["hosts"] or not origin.startswith("https://"):
                raise Refused
            self.reply(204, {}, origin)
        except Refused:
            self.reply(403, {"error": "forbidden"})

    def do_GET(self):
        path, query = self.route()
        if path == "/healthz":
            return self.reply(200, {"status": "ok"})
        kind = path.removeprefix("/api/v1/site-telemetry/")
        if kind not in REPORTS or not path.startswith("/api/v1/site-telemetry/"):
            return self.reply(404, {"error": "not_found"})
        try:
            facts = authorize(self.headers, query)
        except Refused:
            return self.reply(403, {"error": "forbidden"})
        except Exception as error:
            log(f"the gate failed closed: {type(error).__name__}")
            return self.reply(403, {"error": "forbidden"})
        origin = self.headers.get("Origin", "")
        origin = origin if origin.startswith("https://") and origin.removeprefix("https://") in facts["hosts"] else None
        try:
            status, body = report(kind, facts, query)
        except Exception as error:
            log(f"the statistics of a request could not be counted: {type(error).__name__}")
            status, body = 502, {"error": "upstream"}
        self.reply(status, body, origin)

    def log_message(self, format, *args):
        log(f"{self.command} {self.path.split('?', 1)[0]}")


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()

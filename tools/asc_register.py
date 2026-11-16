#!/usr/bin/env python3
"""App Store Connect helper for Hero Greetings (iOS): register the bundle ID and list apps/builds.

Adapted from PaleoKeyboard/tools/asc_register.py. Lives in ios/tools/ of the hero-greetings repo.

Credentials come from the environment only; the key and the signed token are never printed:
  ASC_KEY_PATH   path to AuthKey_<KEY_ID>.p8 (keep it OUTSIDE the repo, e.g. ~/.keys/)
  ASC_KEY_ID     API key ID
  ASC_ISSUER_ID  issuer ID

Usage:
  python3 ios/tools/asc_register.py register [--dry-run]   # create the bundle IDs that don't exist yet
  python3 ios/tools/asc_register.py list-bundle-ids [--dry-run]
  python3 ios/tools/asc_register.py list-apps [--dry-run]
  python3 ios/tools/asc_register.py list-builds [--dry-run]   # TestFlight builds + processing state

--dry-run makes NO network calls: it checks the environment, signs a token locally if a key is
available (to prove the key loads), and prints the requests it would send.

JWT signing uses PyJWT (pip install pyjwt cryptography) when installed, otherwise the
`cryptography` package directly. Both produce the same ES256 token.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_IDS = [
    ("dev.fire17.storagegenie", "StorageGenie"),
]


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def make_token():
    path, kid, iss = (os.environ.get(k, "") for k in ("ASC_KEY_PATH", "ASC_KEY_ID", "ASC_ISSUER_ID"))
    missing = [k for k, v in (("ASC_KEY_PATH", path), ("ASC_KEY_ID", kid), ("ASC_ISSUER_ID", iss)) if not v]
    if missing:
        die("missing environment: " + ", ".join(missing))
    path = os.path.expanduser(path)
    if not os.path.isfile(path):
        die(f"ASC_KEY_PATH does not point to a file ({path})")
    # ios/tools/ -> repo root is two levels up from ios/
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    if os.path.abspath(path).startswith(repo + os.sep):
        die("the .p8 key is inside the repository — move it outside (e.g. ~/.keys/)")
    with open(path, "rb") as f:
        key_pem = f.read()
    now = int(time.time())
    claims = {"iss": iss, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
    headers = {"alg": "ES256", "kid": kid, "typ": "JWT"}
    try:
        import jwt  # PyJWT
        return jwt.encode(claims, key_pem, algorithm="ES256", headers=headers)
    except ImportError:
        pass
    import base64
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

    def b64(b):
        return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

    key = serialization.load_pem_private_key(key_pem, password=None)
    signing_input = b64(json.dumps(headers, separators=(",", ":")).encode()) + "." + \
        b64(json.dumps(claims, separators=(",", ":")).encode())
    r, s = decode_dss_signature(key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256())))
    return signing_input + "." + b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))


def ssl_context():
    # python.org builds ship without system CA certificates; prefer certifi's bundle when present.
    import ssl
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


def call(token, method, path, body=None):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30, context=ssl_context()) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        try:
            errs = json.loads(detail).get("errors", [])
            detail = "; ".join(f"{x.get('title')}: {x.get('detail')}" for x in errs) or detail
        except ValueError:
            pass
        die(f"{method} {path} -> HTTP {e.code}: {detail}")


def existing_bundle_ids(token):
    q = urllib.parse.urlencode({"filter[identifier]": ",".join(b for b, _ in BUNDLE_IDS), "limit": 200})
    data = call(token, "GET", "/bundleIds?" + q)
    return {d["attributes"]["identifier"]: d for d in data.get("data", [])}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["register", "list-bundle-ids", "list-apps", "list-builds"])
    ap.add_argument("--dry-run", action="store_true", help="no network calls; print what would be sent")
    a = ap.parse_args()

    if a.dry_run:
        have_key = all(os.environ.get(k) for k in ("ASC_KEY_PATH", "ASC_KEY_ID", "ASC_ISSUER_ID"))
        if have_key:
            make_token()
            print("dry-run: API key loads and signs a token (token not shown)")
        else:
            print("dry-run: ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID not all set — skipping the signing check")
        if a.command == "register":
            print("dry-run: GET /v1/bundleIds?filter[identifier]=" + ",".join(b for b, _ in BUNDLE_IDS))
            for ident, name in BUNDLE_IDS:
                print(f'dry-run: POST /v1/bundleIds  (if missing)  identifier={ident} name="{name}" platform=IOS')
        elif a.command == "list-bundle-ids":
            print("dry-run: GET /v1/bundleIds?filter[identifier]=...")
        elif a.command == "list-builds":
            print(f"dry-run: GET /v1/apps?filter[bundleId]={BUNDLE_IDS[0][0]} then GET /v1/builds?filter[app]=<id>")
        else:
            print("dry-run: GET /v1/apps?limit=200")
        return

    token = make_token()
    if a.command == "list-apps":
        apps = call(token, "GET", "/apps?limit=200").get("data", [])
        if not apps:
            print("no apps yet (create the app record in App Store Connect — see ios/README.md)")
        for d in apps:
            at = d["attributes"]
            print(f'{d["id"]}  {at.get("bundleId")}  "{at.get("name")}"  sku={at.get("sku")}  lang={at.get("primaryLocale")}')
        return

    if a.command == "list-builds":
        apps = call(token, "GET", "/apps?" + urllib.parse.urlencode({"filter[bundleId]": BUNDLE_IDS[0][0]})).get("data", [])
        if not apps:
            die(f"no app record for {BUNDLE_IDS[0][0]}")
        q = urllib.parse.urlencode({"filter[app]": apps[0]["id"], "sort": "-uploadedDate", "limit": 20,
                                    "include": "preReleaseVersion"})
        data = call(token, "GET", "/builds?" + q)
        versions = {d["id"]: d["attributes"].get("version") for d in data.get("included", [])
                    if d["type"] == "preReleaseVersions"}
        if not data.get("data"):
            print("no builds yet (a fresh upload can take a few minutes to appear)")
        for b in data.get("data", []):
            at = b["attributes"]
            pv = (b.get("relationships", {}).get("preReleaseVersion", {}).get("data") or {}).get("id")
            print(f'build {at.get("version")}  version {versions.get(pv, "?")}  state={at.get("processingState")}  '
                  f'uploaded={at.get("uploadedDate")}  expired={at.get("expired")}  '
                  f'encryption={at.get("usesNonExemptEncryption")}')
        return

    have = existing_bundle_ids(token)
    if a.command == "list-bundle-ids":
        for ident, _ in BUNDLE_IDS:
            d = have.get(ident)
            print(f"{ident}: " + (f'registered (id {d["id"]}, platform {d["attributes"].get("platform")})' if d else "NOT registered"))
        return

    for ident, name in BUNDLE_IDS:
        if ident in have:
            print(f"{ident}: already registered (id {have[ident]['id']})")
            continue
        body = {"data": {"type": "bundleIds", "attributes": {"identifier": ident, "name": name, "platform": "IOS"}}}
        d = call(token, "POST", "/bundleIds", body)["data"]
        print(f"{ident}: registered (id {d['id']})")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""OTC DNS API client using AKSK signing with temporary agency credentials."""
import sys
import json
import hashlib
import hmac
import datetime
import time
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from urllib.parse import urlparse, parse_qs

def sign(sk, msg):
    return hmac.new(sk, msg.encode(), hashlib.sha256).digest()

def get_signature_key(sk, date, region, service):
    k = sign(("SDK" + sk).encode(), date)
    k = sign(k, region)
    k = sign(k, service)
    return sign(k, "sdk_request")

def aksk_request(method, url, body, ak, sk, security_token, region):
    parsed = urlparse(url)
    host = parsed.hostname
    path = parsed.path or "/"
    if not path.endswith("/"):
        path += "/"
    # Query parameters must be sorted alphabetically for canonical request
    query_parts = parse_qs(parsed.query, keep_blank_values=True)
    sorted_query = "&".join(
        f"{k}={v[0]}" for k, v in sorted(query_parts.items())
    ) if query_parts else ""

    now = datetime.datetime.utcnow()
    timestamp = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")

    body_bytes = body.encode() if isinstance(body, str) else body
    payload_hash = hashlib.sha256(body_bytes).hexdigest()

    headers = {
        "Host": host,
        "X-Sdk-Date": timestamp,
        "Content-Type": "application/json",
    }
    if security_token:
        headers["X-Security-Token"] = security_token

    signed_header_keys = sorted(k.lower() for k in headers)
    signed_headers_str = ";".join(signed_header_keys)
    canonical_headers = "".join(
        f"{k.lower()}:{headers[k]}\n" for k in sorted(headers, key=str.lower)
    )

    canonical_request = (
        f"{method}\n{path}\n{sorted_query}\n{canonical_headers}\n"
        f"{signed_headers_str}\n{payload_hash}"
    )
    credential_scope = f"{datestamp}/{region}/dns/sdk_request"
    string_to_sign = (
        f"SDK-HMAC-SHA256\n{timestamp}\n{credential_scope}\n"
        f"{hashlib.sha256(canonical_request.encode()).hexdigest()}"
    )

    signing_key = get_signature_key(sk, datestamp, region, "dns")
    signature = hmac.new(
        signing_key, string_to_sign.encode(), hashlib.sha256
    ).hexdigest()

    headers["Authorization"] = (
        f"SDK-HMAC-SHA256 Credential={ak}/{credential_scope}, "
        f"SignedHeaders={signed_headers_str}, Signature={signature}"
    )

    req = Request(url, data=body_bytes if body_bytes else None,
                  headers=headers, method=method)
    try:
        resp = urlopen(req)
        return json.loads(resp.read())
    except HTTPError as e:
        err = e.read().decode()
        print(f"ERROR: DNS API {e.code}: {err}", file=sys.stderr)
        sys.exit(1)

def get_creds():
    from urllib.request import urlopen as uo
    creds = json.loads(
        uo("http://169.254.169.254/openstack/latest/securitykey").read()
    )["credential"]
    return creds["access"], creds["secret"], creds.get("securitytoken", "")

def create_txt(zone_id, name, value, region):
    # Delete any existing TXT record with the same name first (avoids conflict)
    for rs_id in find_txt(zone_id, name, region):
        delete_txt(zone_id, rs_id, region)
        time.sleep(2)
    ak, sk, st = get_creds()
    url = f"https://dns.{region}.otc.t-systems.com/v2/zones/{zone_id}/recordsets"
    body = json.dumps({
        "name": name if name.endswith(".") else f"{name}.",
        "type": "TXT",
        "ttl": 60,
        "records": [f'"{value}"']
    })
    result = aksk_request("POST", url, body, ak, sk, st, region)
    return result.get("id", "")

def find_txt(zone_id, name, region):
    ak, sk, st = get_creds()
    clean_name = name if name.endswith(".") else f"{name}."
    url = (f"https://dns.{region}.otc.t-systems.com/v2/zones/{zone_id}"
           f"/recordsets?type=TXT&name={clean_name}")
    result = aksk_request("GET", url, "", ak, sk, st, region)
    return [
        rs["id"] for rs in result.get("recordsets", [])
        if rs.get("name") == clean_name
    ]

def delete_txt(zone_id, recordset_id, region):
    ak, sk, st = get_creds()
    url = (f"https://dns.{region}.otc.t-systems.com/v2/zones/{zone_id}"
           f"/recordsets/{recordset_id}")
    return aksk_request("DELETE", url, "", ak, sk, st, region)

def main():
    if len(sys.argv) < 2:
        print("Usage:", file=sys.stderr)
        print("  otc-dns.py create <zone_id> <fqdn> <value> <region>",
              file=sys.stderr)
        print("  otc-dns.py delete <zone_id> <fqdn> <region>",
              file=sys.stderr)
        sys.exit(1)

    action = sys.argv[1]
    if action == "create":
        zone_id, fqdn, value, region = (
            sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
        )
        rs_id = create_txt(zone_id, fqdn, value, region)
        print(rs_id)
    elif action == "delete":
        zone_id, fqdn, region = sys.argv[2], sys.argv[3], sys.argv[4]
        for rs_id in find_txt(zone_id, fqdn, region):
            delete_txt(zone_id, rs_id, region)
            print(f"Deleted {rs_id}")
    else:
        print(f"Unknown action: {action}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()

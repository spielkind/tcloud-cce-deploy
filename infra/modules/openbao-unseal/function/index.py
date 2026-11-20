import json
import logging
import base64
import datetime
import hashlib
import hmac as hmac_mod
import time
from urllib.request import Request, urlopen
from urllib.error import HTTPError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = "eu-de"
KMS_URL = f"https://kms.{REGION}.otc.t-systems.com/v1.0"


def obs_get(bucket, object_key, ak, sk, security_token):
    """Read an object from OBS using S3 V2 signing with STS credentials."""
    obs_url = f"https://{bucket}.obs.{REGION}.otc.t-systems.com/{object_key}"
    now = datetime.datetime.now(datetime.timezone.utc)
    date_str = now.strftime("%a, %d %b %Y %H:%M:%S GMT")

    resource = f"/{bucket}/{object_key}"
    headers_to_sign = f"x-amz-security-token:{security_token}\n" if security_token else ""
    string_to_sign = f"GET\n\n\n{date_str}\n{headers_to_sign}{resource}"

    signature = base64.b64encode(
        hmac_mod.new(sk.encode(), string_to_sign.encode(), hashlib.sha1).digest()
    ).decode()

    headers = {
        "Date": date_str,
        "Authorization": f"AWS {ak}:{signature}",
    }
    if security_token:
        headers["x-amz-security-token"] = security_token

    req = Request(obs_url, headers=headers)
    return urlopen(req).read().decode().strip()


def bao_status(bao_addr):
    """Check OpenBao seal status. Returns (sealed, initialized) or (None, None) on error."""
    try:
        req = Request(f"{bao_addr}/v1/sys/health", method="GET")
        resp = urlopen(req)
        data = json.loads(resp.read())
        return data.get("sealed", True), data.get("initialized", False)
    except HTTPError as e:
        # OpenBao returns 503 when sealed, 501 when uninitialized
        try:
            data = json.loads(e.read())
            return data.get("sealed", True), data.get("initialized", False)
        except Exception:
            return None, None
    except Exception:
        return None, None


def bao_unseal(bao_addr, unseal_keys):
    """Unseal OpenBao by submitting unseal keys one at a time."""
    results = []
    for i, key in enumerate(unseal_keys):
        url = f"{bao_addr}/v1/sys/unseal"
        body = json.dumps({"key": key}).encode()
        try:
            req = Request(url, data=body, headers={"Content-Type": "application/json"}, method="PUT")
            resp = json.loads(urlopen(req).read())
            sealed = resp.get("sealed", True)
            progress = resp.get("progress", 0)
            threshold = resp.get("t", 0)
            results.append({"key": i + 1, "sealed": sealed, "progress": progress, "threshold": threshold})
            logger.info(f"key {i + 1}: sealed={sealed} progress={progress}/{threshold}")
            if not sealed:
                logger.info("OpenBao is unsealed!")
                break
        except HTTPError as e:
            body_err = e.read().decode() if hasattr(e, 'read') else str(e)
            results.append({"key": i + 1, "error": f"{e.code}: {body_err[:200]}"})
            logger.error(f"unseal key {i + 1} failed: {e.code}: {body_err[:200]}")
    return results


def handler(event, context):
    """
    Read encrypted OpenBao unseal keys from OBS, decrypt via KMS, unseal OpenBao.

    Expected event:
      {"bucket": "...", "bao_addr": "http://openbao.openbao.svc:8200"}
      Optional: {"object_key": "openbao-unseal/keys.enc"}
    """
    token = context.getToken()
    project_id = context.getProjectID()
    ak = context.getSecurityAccessKey()
    sk = context.getSecuritySecretKey()
    st = context.getSecurityToken()

    # Read config from user_data (set by Terraform as JSON key-value pairs)
    user_data = {}
    try:
        user_data["bucket"] = context.getUserData("bucket") or ""
    except Exception:
        pass
    try:
        user_data["object_key"] = context.getUserData("object_key") or ""
    except Exception:
        pass

    bucket = event.get("bucket", "") or user_data.get("bucket", "")
    object_key = event.get("object_key", "") or user_data.get("object_key", "openbao-unseal/keys.enc")
    bao_addr = event.get("bao_addr", "")

    if not bucket:
        return {"statusCode": 400, "body": "missing bucket in user_data and event"}
    if not bao_addr:
        return {"statusCode": 400, "body": "missing bao_addr"}

    # Wait for OpenBao to become reachable (pod may still be starting)
    max_retries = int(event.get("max_retries", 10))
    wait_interval = int(event.get("wait", 5))
    for attempt in range(1, max_retries + 1):
        logger.info(f"attempt {attempt}/{max_retries}: waiting {wait_interval}s")
        time.sleep(wait_interval)
        sealed, initialized = bao_status(bao_addr)
        if sealed is not None:
            break
        logger.info(f"OpenBao not reachable at {bao_addr}")
    else:
        return {"statusCode": 502, "body": f"OpenBao not reachable after {max_retries * wait_interval}s at {bao_addr}"}

    if not initialized:
        logger.info("OpenBao is not initialized yet — nothing to unseal")
        return {"statusCode": 200, "body": json.dumps({"unsealed": False, "reason": "not initialized"})}
    if not sealed:
        logger.info("OpenBao is already unsealed")
        return {"statusCode": 200, "body": json.dumps({"unsealed": True, "reason": "already unsealed"})}

    # 1. Read encrypted data from OBS
    logger.info(f"reading from OBS: {bucket}/{object_key}")
    try:
        cipher_text = obs_get(bucket, object_key, ak, sk, st)
    except HTTPError as e:
        body = e.read().decode() if hasattr(e, 'read') else str(e)
        logger.error(f"OBS error {e.code}: {body}")
        return {"statusCode": e.code, "body": f"OBS read failed: {body[:300]}"}
    logger.info(f"read {len(cipher_text)} bytes from OBS")

    # 2. Decrypt via KMS
    logger.info("decrypting via KMS")
    kms_body = json.dumps({"cipher_text": cipher_text}).encode()
    try:
        kms_req = Request(
            f"{KMS_URL}/{project_id}/kms/decrypt-data",
            data=kms_body,
            headers={"X-Auth-Token": token, "Content-Type": "application/json"},
            method="POST",
        )
        kms_resp = json.loads(urlopen(kms_req).read())
    except HTTPError as e:
        body = e.read().decode() if hasattr(e, 'read') else str(e)
        logger.error(f"KMS error {e.code}: {body}")
        return {"statusCode": e.code, "body": f"KMS decrypt failed: {body[:300]}"}

    plain_b64 = kms_resp.get("plain_text", "")
    if not plain_b64:
        logger.error(f"KMS decrypt failed: {kms_resp}")
        return {"statusCode": 500, "body": "KMS decrypt returned empty plaintext"}

    # 3. Decode unseal keys
    unseal_keys_raw = base64.b64decode(plain_b64).decode()
    unseal_keys = [k.strip() for k in unseal_keys_raw.split(",") if k.strip()]
    logger.info(f"got {len(unseal_keys)} unseal keys")

    # 4. Unseal OpenBao
    logger.info(f"unsealing OpenBao at {bao_addr}")
    unseal_results = bao_unseal(bao_addr, unseal_keys)

    final_sealed = unseal_results[-1].get("sealed", True) if unseal_results else True
    return {
        "statusCode": 200 if not final_sealed else 500,
        "body": json.dumps({
            "unsealed": not final_sealed,
            "keys_used": len(unseal_results),
            "details": unseal_results,
        }),
    }

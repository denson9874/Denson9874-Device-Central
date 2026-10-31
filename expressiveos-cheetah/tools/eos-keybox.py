#!/usr/bin/env python3
"""Validate, check live status of, and publish ExpressiveOS's attestation keybox.xml.

Usage:
  eos-keybox.py check <keybox.xml> [--offline]
      Verify XML structure, private/leaf keypair match, X.509 signature chain,
      expiry dates, Google Hardware Attestation Root CA trust anchor, and
      (unless --offline) live Google CRL status. Never prints private keys.
      Ends with KEYBOX_CHECK=OK (0), KEYBOX_CHECK=REVOKED (2), or KEYBOX_CHECK=FAIL (1).

  eos-keybox.py status
      Fetch EOS_KEYBOX_URL (from ../eos.conf) bypassing caches and run the full
      online check against Google's live root list and CRL.
      Ends with KEYBOX_STATUS=OK (0), KEYBOX_STATUS=REVOKED (2),
      KEYBOX_STATUS=MISSING (3, HTTP 404), or KEYBOX_STATUS=FAIL (1).

  eos-keybox.py upload <keybox.xml>
      Run the full online check on <keybox.xml>, upload it to
      <EOS_R2_REMOTE>/<EOS_KEYBOX_R2_KEY> via rclone with Cache-Control: no-store,
      and verify EOS_KEYBOX_URL serves the exact SHA-256 back.
      Ends with KEYBOX_UPLOAD=OK (0).
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

ROOTS_URL = "https://android.googleapis.com/attestation/root"
CRL_URL = "https://android.googleapis.com/attestation/status?encrypted=0"
EXPIRY_WARN_DAYS = 14

# Pinned Google Hardware Attestation Root SHA-256s (DER), matching Evolver's TrickyStore.kt.
# Used when --offline is passed; online runs fetch ROOTS_URL directly.
FALLBACK_GOOGLE_ROOT_SHA256 = {
    # Google Hardware Attestation Root (RSA-4096), 2019
    "1EF1A04B8BA58AB94589AC498C8982A783F24EA7307E0159A0C3A73B377D87CC",
    # Google Hardware Attestation Root (RSA-4096), 2022 (serialNumber=f92009e853b6b045)
    "CEDB1CB6DC896AE5EC797348BCE9286753C2B38EE71CE0FBE34A9A1248800DFC",
    # Google Hardware Attestation Root (EC P-384) "Key Attestation CA1", 2025
    "6D9DB4CE6C5C0B293166D08986E05774A8776CEB525D9E4329520DE12BA4BCC0",
}

XML_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)


def read_eos_conf():
    here = os.path.dirname(os.path.abspath(__file__))
    conf_path = os.path.join(os.path.dirname(here), "eos.conf")
    out = {}
    with open(conf_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
                v = v[1:-1]
            out[k.strip()] = v
    return out


def normalize_pem(text):
    if not text or not text.strip():
        return ""
    return "\n".join(line.strip() for line in text.strip().splitlines() if line.strip()) + "\n"


def run_openssl(args, stdin_text=None, raw_out=False):
    inp = stdin_text.encode("utf-8") if stdin_text is not None else None
    p = subprocess.run(["openssl"] + list(args), input=inp, capture_output=True)
    if p.returncode != 0:
        err = p.stderr.decode("utf-8", "replace").strip()
        raise ValueError(f"openssl {' '.join(args[:2])} failed: {err}")
    return p.stdout if raw_out else p.stdout.decode("utf-8", "replace")


def parse_openssl_time(val):
    norm = " ".join(val.strip().split())
    if not norm.endswith(" GMT"):
        raise ValueError(f"unexpected certificate timestamp (not GMT): {val!r}")
    dt = datetime.datetime.strptime(norm[:-4], "%b %d %H:%M:%S %Y")
    return dt.replace(tzinfo=datetime.timezone.utc)


def fetch_bytes(url, timeout=15):
    req = urllib.request.Request(
        url,
        headers={
            "Cache-Control": "no-cache, no-store, max-age=0",
            "Pragma": "no-cache",
            "User-Agent": "ExpressiveOS-KeyboxCheck/1.0",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read(), dict(resp.info())


def fetch_google_roots():
    raw, _ = fetch_bytes(ROOTS_URL)
    arr = json.loads(raw.decode("utf-8"))
    if not isinstance(arr, list) or not arr:
        raise ValueError(f"{ROOTS_URL} returned no certificates")
    roots = set()
    for pem in arr:
        der = run_openssl(["x509", "-outform", "DER"], stdin_text=normalize_pem(pem), raw_out=True)
        roots.add(hashlib.sha256(der).hexdigest().upper())
    if not roots:
        raise ValueError(f"{ROOTS_URL} parsed to zero X.509 certificates")
    return roots


def fetch_google_crl():
    raw, _ = fetch_bytes(CRL_URL)
    doc = json.loads(raw.decode("utf-8"))
    entries = doc.get("entries")
    if not isinstance(entries, dict):
        raise ValueError(f"{CRL_URL} missing 'entries' object")
    return {k.lower(): v for k, v in entries.items()}


def inspect_cert(pem):
    der = run_openssl(["x509", "-outform", "DER"], stdin_text=pem, raw_out=True)
    sha256_der = hashlib.sha256(der).hexdigest().upper()
    meta = run_openssl(["x509", "-noout", "-serial", "-subject", "-issuer", "-dates"], stdin_text=pem)
    fields = {}
    for line in meta.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            fields[k.strip()] = v.strip()
    serial = fields.get("serial", "").strip().lower()
    if not serial or not re.fullmatch(r"[0-9a-f]+", serial):
        raise ValueError(f"invalid certificate serial: {serial!r}")
    not_before = parse_openssl_time(fields["notBefore"])
    not_after = parse_openssl_time(fields["notAfter"])
    return {
        "sha256_der": sha256_der,
        "serial": serial,
        "serial_trimmed": serial.lstrip("0") or "0",
        "subject": fields.get("subject", ""),
        "issuer": fields.get("issuer", ""),
        "not_before": not_before,
        "not_after": not_after,
    }


def verify_chain_signatures(certs_pem):
    if len(certs_pem) < 2:
        raise ValueError(f"certificate chain has {len(certs_pem)} cert(s); hardware keyboxes need >= 2")
    with tempfile.TemporaryDirectory() as tmp:
        leaf_path = os.path.join(tmp, "leaf.pem")
        ca_path = os.path.join(tmp, "root.pem")
        with open(leaf_path, "w", encoding="utf-8") as f:
            f.write(certs_pem[0])
        with open(ca_path, "w", encoding="utf-8") as f:
            f.write(certs_pem[-1])
        cmd = [
            "openssl", "verify",
            "-check_ss_sig",
            "-ignore_critical",
            "-purpose", "any",
            "-trusted", ca_path,
        ]
        if len(certs_pem) > 2:
            inter_path = os.path.join(tmp, "inter.pem")
            with open(inter_path, "w", encoding="utf-8") as f:
                f.write("".join(certs_pem[1:-1]))
            cmd += ["-untrusted", inter_path]
        cmd.append(leaf_path)
        p = subprocess.run(cmd, capture_output=True, text=True)
        if p.returncode != 0:
            detail = (p.stderr.strip() or p.stdout.strip())
            raise ValueError(f"X.509 signature chain verification failed: {detail}")


def validate_keybox_xml(xml_text, offline=False):
    """Returns (ok, status_tag, summary_lines). status_tag in ('OK', 'REVOKED', 'FAIL')."""
    lines = []
    sha_xml = hashlib.sha256(xml_text.encode("utf-8")).hexdigest()
    lines.append(f"sha256={sha_xml} ({len(xml_text.encode('utf-8'))} bytes)")

    sanitized = XML_COMMENT.sub("", xml_text).strip()
    try:
        root = ET.fromstring(sanitized)
    except ET.ParseError as e:
        return False, "FAIL", lines + [f"FAIL: malformed XML: {e}"]

    if root.tag != "AndroidAttestation":
        return False, "FAIL", lines + [f"FAIL: root element is <{root.tag}>, expected <AndroidAttestation>"]

    keyboxes = root.findall("Keybox")
    if not keyboxes:
        return False, "FAIL", lines + ["FAIL: no <Keybox> elements found"]

    try:
        trusted_roots = FALLBACK_GOOGLE_ROOT_SHA256 if offline else fetch_google_roots()
        crl = None if offline else fetch_google_crl()
    except Exception as e:
        return False, "FAIL", lines + [f"FAIL: live Google attestation fetch failed: {e}"]

    now = datetime.datetime.now(datetime.timezone.utc)
    kb = keyboxes[0]
    dev_id = kb.attrib.get("DeviceID", "<unnamed>")
    keys = kb.findall("Key")
    if not keys:
        return False, "FAIL", lines + [f"FAIL: <Keybox DeviceID={dev_id!r}> has no <Key> elements"]

    seen_algs = {}
    revoked_hits = []
    earliest_expiry = None

    for key_el in keys:
        alg = key_el.attrib.get("algorithm", "").strip().lower()
        if alg not in ("ecdsa", "rsa"):
            return False, "FAIL", lines + [f"FAIL: unsupported <Key algorithm={alg!r}>"]
        pk_el = key_el.find("PrivateKey")
        chain_el = key_el.find("CertificateChain")
        if pk_el is None or chain_el is None:
            return False, "FAIL", lines + [f"FAIL: <Key algorithm={alg}> missing PrivateKey or CertificateChain"]

        pk_pem = normalize_pem(pk_el.text)
        certs_pem = [normalize_pem(c.text) for c in chain_el.findall("Certificate")]
        if not pk_pem or not certs_pem or any(not c for c in certs_pem):
            return False, "FAIL", lines + [f"FAIL: <Key algorithm={alg}> has empty PEM block"]

        try:
            pk_pub = run_openssl(["pkey", "-pubout"], stdin_text=pk_pem).strip()
            leaf_pub = run_openssl(["x509", "-noout", "-pubkey"], stdin_text=certs_pem[0]).strip()
        except ValueError as e:
            return False, "FAIL", lines + [f"FAIL: <Key algorithm={alg}> key/cert parse error: {e}"]

        if pk_pub != leaf_pub:
            return False, "FAIL", lines + [
                f"FAIL: <Key algorithm={alg}> PrivateKey does not match leaf Certificate[0] public key"
            ]

        try:
            verify_chain_signatures(certs_pem)
            infos = [inspect_cert(c) for c in certs_pem]
        except ValueError as e:
            return False, "FAIL", lines + [f"FAIL: <Key algorithm={alg}> {e}"]

        root_sha = infos[-1]["sha256_der"]
        if root_sha not in trusted_roots:
            return False, "FAIL", lines + [
                f"FAIL: <Key algorithm={alg}> root cert SHA-256 {root_sha} is NOT a Google Hardware Attestation Root CA "
                f"(subject={infos[-1]['subject']})"
            ]

        for idx, info in enumerate(infos):
            if now < info["not_before"]:
                return False, "FAIL", lines + [
                    f"FAIL: <Key algorithm={alg}> cert[{idx}] not valid until {info['not_before'].isoformat()}"
                ]
            if now >= info["not_after"]:
                return False, "FAIL", lines + [
                    f"FAIL: <Key algorithm={alg}> cert[{idx}] expired at {info['not_after'].isoformat()}"
                ]
            if crl is not None:
                entry = crl.get(info["serial_trimmed"]) or crl.get(info["serial"])
                if entry is not None:
                    status = entry.get("status", "REVOKED")
                    reason = entry.get("reason", "UNSPECIFIED")
                    revoked_hits.append(
                        f"{alg} cert[{idx}] serial={info['serial']} status={status} reason={reason}"
                    )

        leaf_exp = infos[0]["not_after"]
        if earliest_expiry is None or leaf_exp < earliest_expiry:
            earliest_expiry = leaf_exp

        seen_algs[alg] = infos
        lines.append(
            f"  {alg}: {len(infos)} certs, leaf serial={infos[0]['serial']}, "
            f"expires={leaf_exp.strftime('%Y-%m-%d')}, root={root_sha[:16]}..."
        )

    if "ecdsa" not in seen_algs:
        return False, "FAIL", lines + [
            "FAIL: keybox has no <Key algorithm=\"ecdsa\"> (required for DroidGuard / Play Integrity)"
        ]
    if "rsa" not in seen_algs:
        lines.append("  note: ECDSA-only keybox (no RSA key; supported on RKP/ECDSA attestation paths)")

    if earliest_expiry is not None:
        days_left = (earliest_expiry - now).days
        if days_left < EXPIRY_WARN_DAYS:
            lines.append(f"  WARNING: earliest leaf certificate expires in {days_left} day(s) ({earliest_expiry.isoformat()})")

    if revoked_hits:
        for h in revoked_hits:
            lines.append(f"FAIL: CRL hit: {h}")
        return False, "REVOKED", lines

    mode_note = "offline root-pin check only (CRL skipped)" if offline else "live Google root + CRL verified"
    lines.append(f"OK: DeviceID={dev_id}, algorithms={','.join(sorted(seen_algs))} ({mode_note})")
    return True, "OK", lines


def find_rclone_with_remote(remote_name):
    candidates = []
    srv = os.path.expanduser("~/bin/rclone")
    if os.path.isfile(srv) and os.access(srv, os.X_OK):
        candidates.append(srv)
    path_bin = shutil.which("rclone")
    if path_bin and path_bin not in candidates:
        candidates.append(path_bin)
    want = f"{remote_name}:"
    for bin_path in candidates:
        p = subprocess.run([bin_path, "listremotes"], capture_output=True, text=True)
        if p.returncode == 0 and want in p.stdout.splitlines():
            return bin_path
    return None


def find_wrangler():
    for cand in (shutil.which("wrangler"), "/opt/homebrew/bin/wrangler", "/usr/local/bin/wrangler"):
        if cand and os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def cmd_check(args):
    if not os.path.isfile(args.file):
        print(f"FAIL: no such file: {args.file}", file=sys.stderr)
        print("KEYBOX_CHECK=FAIL")
        return 1
    with open(args.file, encoding="utf-8") as f:
        xml_text = f.read()
    ok, tag, lines = validate_keybox_xml(xml_text, offline=args.offline)
    stream = sys.stdout if ok else sys.stderr
    for l in lines:
        print(l, file=stream)
    print(f"KEYBOX_CHECK={tag}")
    return 0 if ok else (2 if tag == "REVOKED" else 1)


def cmd_status(_args):
    conf = read_eos_conf()
    url = conf.get("EOS_KEYBOX_URL", "")
    if not url.startswith("https://"):
        print(f"FAIL: eos.conf EOS_KEYBOX_URL is missing or not https: {url!r}", file=sys.stderr)
        print("KEYBOX_STATUS=FAIL")
        return 1
    print(f"== checking {url}")
    try:
        raw, headers = fetch_bytes(url)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print(f"note: {url} returned HTTP 404 (no keybox uploaded yet)", file=sys.stderr)
            print("KEYBOX_STATUS=MISSING")
            return 3
        print(f"FAIL: {url} returned HTTP {e.code}", file=sys.stderr)
        print("KEYBOX_STATUS=FAIL")
        return 1
    except Exception as e:
        print(f"FAIL: couldn't reach {url}: {e}", file=sys.stderr)
        print("KEYBOX_STATUS=FAIL")
        return 1

    cc = headers.get("Cache-Control", headers.get("cache-control", ""))
    if "no-store" not in cc.lower():
        print(f"  note: mirror Cache-Control is {cc!r} (redeploy tools/ota_mirror for 'no-store')")

    ok, tag, lines = validate_keybox_xml(raw.decode("utf-8", "replace"), offline=False)
    stream = sys.stdout if ok else sys.stderr
    for l in lines:
        print(l, file=stream)
    print(f"KEYBOX_STATUS={tag}")
    return 0 if ok else (2 if tag == "REVOKED" else 1)


def cmd_upload(args):
    conf = read_eos_conf()
    r2_remote = conf.get("EOS_R2_REMOTE", "")
    r2_key = conf.get("EOS_KEYBOX_R2_KEY", "")
    url = conf.get("EOS_KEYBOX_URL", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]+:[a-z0-9][a-z0-9-]*", r2_remote):
        print(f"FAIL: eos.conf EOS_R2_REMOTE ({r2_remote!r}) isn't <rclone remote>:<bucket>", file=sys.stderr)
        print("KEYBOX_UPLOAD=FAIL")
        return 1
    if not r2_key or ".." in r2_key.split("/") or r2_key.startswith("/"):
        print(f"FAIL: eos.conf EOS_KEYBOX_R2_KEY ({r2_key!r}) isn't a clean object key", file=sys.stderr)
        print("KEYBOX_UPLOAD=FAIL")
        return 1
    if not url.startswith("https://"):
        print(f"FAIL: eos.conf EOS_KEYBOX_URL ({url!r}) isn't https://", file=sys.stderr)
        print("KEYBOX_UPLOAD=FAIL")
        return 1
    if not os.path.isfile(args.file):
        print(f"FAIL: no such file: {args.file}", file=sys.stderr)
        print("KEYBOX_UPLOAD=FAIL")
        return 1

    remote_name, bucket = r2_remote.split(":", 1)
    rclone = find_rclone_with_remote(remote_name)
    wrangler = None if rclone else find_wrangler()
    if not rclone and not wrangler:
        print(
            f"FAIL: neither rclone with '{remote_name}:' configured nor wrangler found "
            "(see tools/ota_mirror/README.md)",
            file=sys.stderr,
        )
        print("KEYBOX_UPLOAD=FAIL")
        return 1

    raw_bytes = open(args.file, "rb").read()
    xml_text = raw_bytes.decode("utf-8")
    ok, tag, lines = validate_keybox_xml(xml_text, offline=False)
    for l in lines:
        print(l, file=sys.stdout if ok else sys.stderr)
    if not ok:
        print(f"FAIL: refusing to upload keybox ({tag})", file=sys.stderr)
        print("KEYBOX_UPLOAD=FAIL")
        return 2 if tag == "REVOKED" else 1

    if rclone:
        dest = f"{r2_remote}/{r2_key}"
        print(f"== uploading to {dest} (rclone)")
        cmd = [
            rclone, "copyto",
            "--s3-no-check-bucket",
            "--header-upload", "Cache-Control: no-store",
            "--header-upload", "Content-Type: application/xml; charset=utf-8",
            args.file, dest,
        ]
    else:
        dest = f"{bucket}/{r2_key}"
        print(f"== uploading to {dest} (wrangler --remote)")
        cmd = [
            wrangler, "r2", "object", "put", dest,
            "--remote",
            "--file", args.file,
            "--cache-control", "no-store",
            "--content-type", "application/xml; charset=utf-8",
        ]
    run_env = dict(os.environ)
    if wrangler:
        wdir = os.path.dirname(wrangler)
        if wdir not in run_env.get("PATH", "").split(os.pathsep):
            run_env["PATH"] = f"{wdir}{os.pathsep}{run_env.get('PATH', '')}"
    p = subprocess.run(cmd, capture_output=True, text=True, env=run_env)
    if p.returncode != 0:
        detail = (p.stderr.strip() or p.stdout.strip())
        print(f"FAIL: R2 upload failed:\n{detail}", file=sys.stderr)
        print("KEYBOX_UPLOAD=FAIL")
        return 1

    want_sha = hashlib.sha256(raw_bytes).hexdigest()
    print(f"== verifying live mirror {url}")
    try:
        got_bytes, _ = fetch_bytes(url)
    except Exception as e:
        print(f"FAIL: uploaded to {dest}, but {url} failed to fetch: {e}", file=sys.stderr)
        print("KEYBOX_UPLOAD=FAIL")
        return 1
    got_sha = hashlib.sha256(got_bytes).hexdigest()
    if got_sha != want_sha:
        print(f"FAIL: {url} served sha256={got_sha}, expected {want_sha}", file=sys.stderr)
        print("KEYBOX_UPLOAD=FAIL")
        return 1

    print(f"OK: {url} serves sha256={got_sha}")
    print("KEYBOX_UPLOAD=OK")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_check = sub.add_parser("check", help="validate a local keybox.xml")
    p_check.add_argument("file", help="path to keybox.xml")
    p_check.add_argument("--offline", action="store_true", help="skip live Google root/CRL network checks")
    p_check.set_defaults(func=cmd_check)

    p_status = sub.add_parser("status", help="check the live keybox at EOS_KEYBOX_URL")
    p_status.set_defaults(func=cmd_status)

    p_upload = sub.add_parser("upload", help="validate and upload keybox.xml to R2")
    p_upload.add_argument("file", help="path to keybox.xml")
    p_upload.set_defaults(func=cmd_upload)

    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Mac-side Ed25519 feed signing, validation, and R2 publishing tool for EosIntegrityService.

Extends eos-keybox.py for ExpressiveOS 2.0 (Path A) integrity feed management:
  - keygen:
      Generate an Ed25519 private key outside the git tree (0600 permissions) and
      print the base64 SPKI + raw-32-byte public key to pin in EosIntegrityService.
  - validate-keybox:
      Validate a keybox.xml: XML schema, EC+RSA chains, private-key-matches-leaf,
      X.509 signature chain, validity dates, Google Hardware Attestation Root CA
      SHA-256 trust anchor, and Google attestation CRL status (--offline supported).
  - validate-pif:
      Validate a canary PlayIntegrityFix (PIF) profile JSON: required build prop
      schema, fingerprint syntax, SECURITY_PATCH format, expiry timestamp, and
      not-in-revoked fingerprint check.
  - validate-targets:
      Validate a TrickyStore target.txt package list against
      ^[a-zA-Z0-9._]+[!?\\-]?$ and reject any package in XPOSED_PACKAGES.
  - build-manifest:
      Pre-validate all supplied keyboxes, PIF profiles, and target.txt, assemble
      schema v1 manifest.json with SHA-256 digests, sign manifest.json with Ed25519
      detached signature (manifest.json.sig), and self-verify against the public key.
  - verify-manifest:
      Cryptographically verify manifest.json + manifest.json.sig against an Ed25519
      public key (PEM file, SPKI base64, or raw-32-byte base64) and check staged
      artifact SHA-256 digests.
  - publish:
      Verify a signed manifest directory and upload artifacts + manifest.json.sig +
      manifest.json to Cloudflare R2 via rclone (or wrangler) with
      Cache-Control: no-store (--dry-run supported).
"""

import argparse
import base64
import datetime
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

ROOTS_URL = "https://android.googleapis.com/attestation/root"
CRL_URL = "https://android.googleapis.com/attestation/status?encrypted=0"
EXPIRY_WARN_DAYS = 14
SUBPROCESS_TIMEOUT_SEC = 15

# ASN.1 DER prefix for a 32-byte Ed25519 SubjectPublicKeyInfo (RFC 8410):
# SEQUENCE (42 bytes) -> SEQUENCE (OID 1.3.101.112) -> BIT STRING (33 bytes, 0 unused bits + 32-byte key)
ED25519_SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")

DEFAULT_KEY_PATH = os.path.expanduser("~/.config/expressiveos/integrity-ed25519.pem")
DEFAULT_R2_INTEGRITY_PREFIX = "expressiveos/integrity"

# Pinned Google Hardware Attestation Root SHA-256s (DER), matching Evolver's TrickyStore.kt
# and tools/eos-keybox.py.
FALLBACK_GOOGLE_ROOT_SHA256 = {
    # Google Hardware Attestation Root (RSA-4096), 2019
    "1EF1A04B8BA58AB94589AC498C8982A783F24EA7307E0159A0C3A73B377D87CC",
    # Google Hardware Attestation Root (RSA-4096), 2022 (serialNumber=f92009e853b6b045)
    "CEDB1CB6DC896AE5EC797348BCE9286753C2B38EE71CE0FBE34A9A1248800DFC",
    # Google Hardware Attestation Root (EC P-384) "Key Attestation CA1", 2025
    "6D9DB4CE6C5C0B293166D08986E05774A8776CEB525D9E4329520DE12BA4BCC0",
}

REQUIRED_PIF_FIELDS = (
    "MANUFACTURER",
    "MODEL",
    "FINGERPRINT",
    "PRODUCT",
    "DEVICE",
    "RELEASE",
    "ID",
    "INCREMENTAL",
    "TYPE",
    "TAGS",
    "SECURITY_PATCH",
)

PIF_FINGERPRINT_RE = re.compile(r"^[^/\s]+/[^/\s]+/[^:\s]+:[^/\s]+/[^/\s]+/[^:\s]+:[^/\s]+/[^/\s]+$")
SECURITY_PATCH_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
TARGET_LINE_RE = re.compile(r"^[a-zA-Z0-9._]+[!?\-]?$")

# Forbidden Xposed / root-manager packages that must never enter TrickyStore target.txt
XPOSED_PACKAGES = frozenset({
    "org.lsposed.manager",
    "io.github.lsposed.manager",
    "de.robv.android.xposed.installer",
    "org.meowcat.edxposed.manager",
    "com.solohsu.android.edxp.manager",
    "me.weishu.exp",
})

XML_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)


def read_eos_conf():
    here = os.path.dirname(os.path.abspath(__file__))
    conf_path = os.path.join(os.path.dirname(here), "eos.conf")
    out = {}
    if not os.path.isfile(conf_path):
        return out
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


def run_openssl(args, stdin_bytes=None, stdin_text=None, raw_out=False, timeout=SUBPROCESS_TIMEOUT_SEC):
    if stdin_bytes is not None and stdin_text is not None:
        raise ValueError("pass at most one of stdin_bytes or stdin_text")
    inp = stdin_bytes if stdin_bytes is not None else (
        stdin_text.encode("utf-8") if stdin_text is not None else None
    )
    p = subprocess.run(
        ["openssl"] + list(args),
        input=inp,
        capture_output=True,
        timeout=timeout,
    )
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


def parse_iso_utc(val):
    s = val.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    dt = datetime.datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt.astimezone(datetime.timezone.utc)


def format_iso_utc(dt):
    return dt.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def resolve_now(now_str=None):
    if now_str:
        return parse_iso_utc(now_str)
    return datetime.datetime.now(datetime.timezone.utc)


def fetch_bytes(url, timeout=SUBPROCESS_TIMEOUT_SEC):
    req = urllib.request.Request(
        url,
        headers={
            "Cache-Control": "no-cache, no-store, max-age=0",
            "Pragma": "no-cache",
            "User-Agent": "ExpressiveOS-IntegrityTool/2.0",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read(), dict(resp.info())


def parse_roots_json(raw_bytes):
    arr = json.loads(raw_bytes.decode("utf-8"))
    if not isinstance(arr, list) or not arr:
        raise ValueError("roots JSON returned no certificates")
    roots = set()
    for item in arr:
        s = item.strip()
        if re.fullmatch(r"[0-9a-fA-F]{64}", s):
            roots.add(s.upper())
        else:
            der = run_openssl(["x509", "-outform", "DER"], stdin_text=normalize_pem(s), raw_out=True)
            roots.add(hashlib.sha256(der).hexdigest().upper())
    if not roots:
        raise ValueError("roots JSON parsed to zero X.509 certificates")
    return roots


def parse_crl_json(raw_bytes):
    doc = json.loads(raw_bytes.decode("utf-8"))
    entries = doc.get("entries")
    if not isinstance(entries, dict):
        raise ValueError("CRL JSON missing 'entries' object")
    return {k.lower(): v for k, v in entries.items()}


def load_trusted_roots(offline=False, roots_file=None):
    if roots_file:
        with open(roots_file, "rb") as f:
            return parse_roots_json(f.read())
    if offline:
        return set(FALLBACK_GOOGLE_ROOT_SHA256)
    raw, _ = fetch_bytes(ROOTS_URL)
    return parse_roots_json(raw)


def load_crl_entries(offline=False, crl_file=None):
    if crl_file:
        with open(crl_file, "rb") as f:
            return parse_crl_json(f.read())
    if offline:
        return None
    raw, _ = fetch_bytes(CRL_URL)
    return parse_crl_json(raw)


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
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT_SEC)
        if p.returncode != 0:
            detail = (p.stderr.strip() or p.stdout.strip())
            raise ValueError(f"X.509 signature chain verification failed: {detail}")


def validate_keybox_xml(xml_text, offline=False, roots_file=None, crl_file=None, now=None):
    """Returns (ok, status_tag, summary_lines, meta_dict).
    status_tag in ('OK', 'REVOKED', 'FAIL'). Never logs or returns private keys.
    """
    lines = []
    raw_bytes = xml_text.encode("utf-8")
    sha_xml = hashlib.sha256(raw_bytes).hexdigest()
    lines.append(f"sha256={sha_xml} ({len(raw_bytes)} bytes)")
    meta = {
        "sha256": sha_xml,
        "size": len(raw_bytes),
        "device_id": None,
        "algorithms": [],
        "not_after_utc": None,
    }

    sanitized = XML_COMMENT.sub("", xml_text).strip()
    try:
        root = ET.fromstring(sanitized)
    except ET.ParseError as e:
        return False, "FAIL", lines + [f"FAIL: malformed XML: {e}"], meta

    if root.tag != "AndroidAttestation":
        return False, "FAIL", lines + [f"FAIL: root element is <{root.tag}>, expected <AndroidAttestation>"], meta

    keyboxes = root.findall("Keybox")
    if not keyboxes:
        return False, "FAIL", lines + ["FAIL: no <Keybox> elements found"], meta

    try:
        trusted_roots = load_trusted_roots(offline=offline, roots_file=roots_file)
        crl = load_crl_entries(offline=offline, crl_file=crl_file)
    except Exception as e:
        return False, "FAIL", lines + [f"FAIL: attestation root/CRL load failed: {e}"], meta

    now_dt = now if isinstance(now, datetime.datetime) else resolve_now(now)
    kb = keyboxes[0]
    dev_id = kb.attrib.get("DeviceID", "<unnamed>")
    meta["device_id"] = dev_id
    keys = kb.findall("Key")
    if not keys:
        return False, "FAIL", lines + [f"FAIL: <Keybox DeviceID={dev_id!r}> has no <Key> elements"], meta

    seen_algs = {}
    revoked_hits = []
    earliest_expiry = None

    for key_el in keys:
        alg = key_el.attrib.get("algorithm", "").strip().lower()
        if alg not in ("ecdsa", "rsa"):
            return False, "FAIL", lines + [f"FAIL: unsupported <Key algorithm={alg!r}>"], meta
        pk_el = key_el.find("PrivateKey")
        chain_el = key_el.find("CertificateChain")
        if pk_el is None or chain_el is None:
            return False, "FAIL", lines + [f"FAIL: <Key algorithm={alg}> missing PrivateKey or CertificateChain"], meta

        pk_pem = normalize_pem(pk_el.text)
        certs_pem = [normalize_pem(c.text) for c in chain_el.findall("Certificate")]
        if not pk_pem or not certs_pem or any(not c for c in certs_pem):
            return False, "FAIL", lines + [f"FAIL: <Key algorithm={alg}> has empty PEM block"], meta

        try:
            pk_pub = run_openssl(["pkey", "-pubout"], stdin_text=pk_pem).strip()
            leaf_pub = run_openssl(["x509", "-noout", "-pubkey"], stdin_text=certs_pem[0]).strip()
        except ValueError as e:
            return False, "FAIL", lines + [f"FAIL: <Key algorithm={alg}> key/cert parse error: {e}"], meta

        if pk_pub != leaf_pub:
            return False, "FAIL", lines + [
                f"FAIL: <Key algorithm={alg}> PrivateKey does not match leaf Certificate[0] public key"
            ], meta

        try:
            verify_chain_signatures(certs_pem)
            infos = [inspect_cert(c) for c in certs_pem]
        except ValueError as e:
            return False, "FAIL", lines + [f"FAIL: <Key algorithm={alg}> {e}"], meta

        root_sha = infos[-1]["sha256_der"]
        if root_sha not in trusted_roots:
            return False, "FAIL", lines + [
                f"FAIL: <Key algorithm={alg}> root cert SHA-256 {root_sha} is NOT a trusted Google Hardware Attestation Root CA "
                f"(subject={infos[-1]['subject']})"
            ], meta

        for idx, info in enumerate(infos):
            if now_dt < info["not_before"]:
                return False, "FAIL", lines + [
                    f"FAIL: <Key algorithm={alg}> cert[{idx}] not valid until {info['not_before'].isoformat()}"
                ], meta
            if now_dt >= info["not_after"]:
                return False, "FAIL", lines + [
                    f"FAIL: <Key algorithm={alg}> cert[{idx}] expired at {info['not_after'].isoformat()}"
                ], meta
            if crl is not None:
                entry = crl.get(info["serial_trimmed"]) or crl.get(info["serial"])
                if entry is not None:
                    status = str(entry.get("status", "REVOKED")).upper()
                    reason = str(entry.get("reason", "UNSPECIFIED"))
                    revoked_hits.append(
                        f"{alg} cert[{idx}] serial={info['serial']} status={status} reason={reason}"
                    )

        chain_min_exp = min(info["not_after"] for info in infos)
        if earliest_expiry is None or chain_min_exp < earliest_expiry:
            earliest_expiry = chain_min_exp

        seen_algs[alg] = infos
        lines.append(
            f"  {alg}: {len(infos)} certs, leaf serial={infos[0]['serial']}, "
            f"expires={chain_min_exp.strftime('%Y-%m-%d')}, root={root_sha[:16]}..."
        )

    if "ecdsa" not in seen_algs:
        return False, "FAIL", lines + [
            "FAIL: keybox has no <Key algorithm=\"ecdsa\"> (required for DroidGuard / Play Integrity)"
        ], meta
    if "rsa" not in seen_algs:
        lines.append("  note: ECDSA-only keybox (no RSA key; supported on RKP/ECDSA attestation paths)")

    meta["algorithms"] = sorted(seen_algs.keys())
    if earliest_expiry is not None:
        meta["not_after_utc"] = format_iso_utc(earliest_expiry)
        days_left = (earliest_expiry - now_dt).days
        if days_left < EXPIRY_WARN_DAYS:
            lines.append(f"  WARNING: earliest certificate expires in {days_left} day(s) ({earliest_expiry.isoformat()})")

    if revoked_hits:
        for h in revoked_hits:
            lines.append(f"FAIL: CRL hit: {h}")
        return False, "REVOKED", lines, meta

    mode_note = "offline root-pin check only (CRL skipped)" if (offline and not crl_file) else "Google root + CRL verified"
    lines.append(f"OK: DeviceID={dev_id}, algorithms={','.join(meta['algorithms'])} ({mode_note})")
    return True, "OK", lines, meta


def load_revoked_pif_set(revoked_file=None, extra_revoked=None):
    revoked = set()
    if extra_revoked:
        for item in extra_revoked:
            if item and item.strip():
                revoked.add(item.strip())
    if revoked_file:
        with open(revoked_file, encoding="utf-8") as f:
            doc = json.load(f)
        if isinstance(doc, list):
            items = doc
        elif isinstance(doc, dict):
            items = doc.get("revoked_pif_fingerprints", [])
        else:
            raise ValueError(f"unsupported revoked PIF JSON format in {revoked_file}")
        for item in items:
            if isinstance(item, str) and item.strip():
                revoked.add(item.strip())
    return revoked


def validate_pif_data(raw_text, revoked_set=None, now=None):
    """Returns (ok, status_tag, summary_lines, meta_dict).
    status_tag in ('OK', 'REVOKED', 'EXPIRED', 'FAIL').
    """
    lines = []
    raw_bytes = raw_text.encode("utf-8")
    sha_pif = hashlib.sha256(raw_bytes).hexdigest()
    lines.append(f"sha256={sha_pif} ({len(raw_bytes)} bytes)")
    meta = {
        "sha256": sha_pif,
        "size": len(raw_bytes),
        "device": None,
        "fingerprint": None,
        "security_patch": None,
        "expires_utc": None,
        "status": "ACTIVE",
    }

    try:
        doc = json.loads(raw_text)
    except json.JSONDecodeError as e:
        return False, "FAIL", lines + [f"FAIL: malformed JSON: {e}"], meta

    if not isinstance(doc, dict):
        return False, "FAIL", lines + ["FAIL: PIF root must be a JSON object"], meta

    missing = [k for k in REQUIRED_PIF_FIELDS if not isinstance(doc.get(k), str) or not doc.get(k).strip()]
    if missing:
        return False, "FAIL", lines + [f"FAIL: missing or empty required PIF field(s): {', '.join(missing)}"], meta

    fp = doc["FINGERPRINT"].strip()
    if not PIF_FINGERPRINT_RE.fullmatch(fp):
        return False, "FAIL", lines + [f"FAIL: invalid FINGERPRINT syntax: {fp!r}"], meta

    sec_patch = doc["SECURITY_PATCH"].strip()
    if not SECURITY_PATCH_RE.fullmatch(sec_patch):
        return False, "FAIL", lines + [f"FAIL: invalid SECURITY_PATCH format (expected YYYY-MM-DD): {sec_patch!r}"], meta
    try:
        datetime.date.fromisoformat(sec_patch)
    except ValueError as e:
        return False, "FAIL", lines + [f"FAIL: invalid SECURITY_PATCH calendar date {sec_patch!r}: {e}"], meta

    build_type = doc["TYPE"].strip()
    if build_type != "user":
        return False, "FAIL", lines + [f"FAIL: PIF TYPE must be 'user', got {build_type!r}"], meta

    tags = doc["TAGS"].strip()
    if tags not in ("release-keys", "dev-keys"):
        return False, "FAIL", lines + [f"FAIL: PIF TAGS must be 'release-keys' or 'dev-keys', got {tags!r}"], meta

    init_sdk = doc.get("DEVICE_INITIAL_SDK_INT", doc.get("FIRST_API_LEVEL"))
    if init_sdk is not None:
        try:
            sdk_val = int(str(init_sdk).strip())
            if sdk_val < 21 or sdk_val > 45:
                return False, "FAIL", lines + [f"FAIL: DEVICE_INITIAL_SDK_INT out of range: {sdk_val}"], meta
        except ValueError:
            return False, "FAIL", lines + [f"FAIL: non-integer DEVICE_INITIAL_SDK_INT: {init_sdk!r}"], meta

    meta["device"] = doc["DEVICE"].strip()
    meta["fingerprint"] = fp
    meta["security_patch"] = sec_patch

    status_val = str(doc.get("status", "ACTIVE")).strip().upper()
    meta["status"] = status_val
    if status_val == "REVOKED":
        return False, "REVOKED", lines + [f"FAIL: PIF profile has status=REVOKED ({fp})"], meta
    if status_val == "EXPIRED":
        return False, "EXPIRED", lines + [f"FAIL: PIF profile has status=EXPIRED ({fp})"], meta
    if status_val != "ACTIVE":
        return False, "FAIL", lines + [f"FAIL: unsupported PIF status {status_val!r}"], meta

    revoked = revoked_set or set()
    build_id = doc["ID"].strip()
    if fp in revoked or build_id in revoked:
        return False, "REVOKED", lines + [f"FAIL: PIF fingerprint/ID is in revoked list: {fp}"], meta

    now_dt = now if isinstance(now, datetime.datetime) else resolve_now(now)
    expires_raw = doc.get("expires_utc")
    if expires_raw is not None:
        if not isinstance(expires_raw, str) or not expires_raw.strip():
            return False, "FAIL", lines + ["FAIL: expires_utc must be a non-empty ISO-8601 UTC string"], meta
        try:
            exp_dt = parse_iso_utc(expires_raw)
        except Exception as e:
            return False, "FAIL", lines + [f"FAIL: invalid expires_utc {expires_raw!r}: {e}"], meta
        meta["expires_utc"] = format_iso_utc(exp_dt)
        if now_dt >= exp_dt:
            return False, "EXPIRED", lines + [
                f"FAIL: PIF profile expired at {meta['expires_utc']} (now={format_iso_utc(now_dt)})"
            ], meta

    lines.append(
        f"OK: device={meta['device']} id={build_id} patch={sec_patch} "
        f"expires={meta['expires_utc'] or 'unspecified'}"
    )
    return True, "OK", lines, meta


def validate_targets_text(raw_text):
    """Returns (ok, status_tag, summary_lines, meta_dict).
    status_tag in ('OK', 'FAIL').
    """
    lines = []
    raw_bytes = raw_text.encode("utf-8")
    sha_targets = hashlib.sha256(raw_bytes).hexdigest()
    lines.append(f"sha256={sha_targets} ({len(raw_bytes)} bytes)")
    meta = {
        "sha256": sha_targets,
        "size": len(raw_bytes),
        "count": 0,
        "entries": [],
    }

    seen = {}
    ordered = []
    for lineno, raw_line in enumerate(raw_text.splitlines(), start=1):
        s = raw_line.strip()
        if not s or s.startswith("#"):
            continue
        if not TARGET_LINE_RE.fullmatch(s):
            return False, "FAIL", lines + [
                f"FAIL: line {lineno} {s!r} does not match ^[a-zA-Z0-9._]+[!?\\-]?$"
            ], meta
        base_pkg = s[:-1] if s[-1] in ("!", "?", "-") else s
        if "." not in base_pkg or base_pkg.startswith(".") or base_pkg.endswith(".") or ".." in base_pkg:
            return False, "FAIL", lines + [
                f"FAIL: line {lineno} {s!r} is not a valid Android package identifier"
            ], meta
        if base_pkg.lower() in XPOSED_PACKAGES:
            return False, "FAIL", lines + [
                f"FAIL: line {lineno} {s!r} is in forbidden XPOSED_PACKAGES ({base_pkg})"
            ], meta
        if base_pkg not in seen:
            seen[base_pkg] = s
            ordered.append(s)

    if not ordered:
        return False, "FAIL", lines + ["FAIL: target.txt contains zero valid package entries"], meta

    meta["count"] = len(ordered)
    meta["entries"] = ordered
    lines.append(f"OK: {len(ordered)} valid target package(s)")
    return True, "OK", lines, meta


def is_inside_git_worktree(target_path):
    parent = os.path.dirname(os.path.abspath(target_path))
    while True:
        if os.path.exists(os.path.join(parent, ".git")):
            return True
        nxt = os.path.dirname(parent)
        if nxt == parent:
            return False
        parent = nxt


def extract_ed25519_pubkey_info(priv_or_pub_pem, is_private=True):
    """Returns (pub_pem, spki_b64, raw32_b64, spki_sha256_hex) for an Ed25519 key."""
    if is_private:
        pub_pem = run_openssl(["pkey", "-pubout"], stdin_text=priv_or_pub_pem)
        spki_der = run_openssl(["pkey", "-pubout", "-outform", "DER"], stdin_text=priv_or_pub_pem, raw_out=True)
    else:
        pub_pem = normalize_pem(priv_or_pub_pem)
        spki_der = run_openssl(["pkey", "-pubin", "-pubout", "-outform", "DER"], stdin_text=pub_pem, raw_out=True)

    if len(spki_der) != 44 or not spki_der.startswith(ED25519_SPKI_PREFIX):
        raise ValueError(
            f"key is not a 44-byte Ed25519 SubjectPublicKeyInfo (got {len(spki_der)} bytes, "
            f"prefix={spki_der[:12].hex()})"
        )
    raw32 = spki_der[12:]
    spki_b64 = base64.b64encode(spki_der).decode("ascii")
    raw32_b64 = base64.b64encode(raw32).decode("ascii")
    spki_sha256 = hashlib.sha256(spki_der).hexdigest()
    return pub_pem, spki_b64, raw32_b64, spki_sha256


def pubkey_pem_from_spec(pubkey_spec):
    """Accepts a path to a PEM file, inline PEM text, base64 44-byte SPKI DER, or base64 32-byte raw Ed25519 key."""
    if os.path.isfile(pubkey_spec):
        text = open(pubkey_spec, encoding="utf-8").read().strip()
    else:
        text = pubkey_spec.strip()

    if "-----BEGIN" in text:
        pub_pem, _, _, _ = extract_ed25519_pubkey_info(text, is_private=("PRIVATE KEY" in text))
        return pub_pem

    raw = base64.b64decode(text, validate=True)
    if len(raw) == 32:
        spki_der = ED25519_SPKI_PREFIX + raw
    elif len(raw) == 44 and raw.startswith(ED25519_SPKI_PREFIX):
        spki_der = raw
    else:
        raise ValueError(f"expected 32-byte raw or 44-byte SPKI Ed25519 public key, got {len(raw)} bytes")

    b64_lines = "\n".join(
        base64.b64encode(spki_der).decode("ascii")[i:i + 64]
        for i in range(0, len(base64.b64encode(spki_der)), 64)
    )
    pem = f"-----BEGIN PUBLIC KEY-----\n{b64_lines}\n-----END PUBLIC KEY-----\n"
    pub_pem, _, _, _ = extract_ed25519_pubkey_info(pem, is_private=False)
    return pub_pem


def sign_ed25519(priv_pem_path, payload_bytes):
    with tempfile.TemporaryDirectory() as tmp:
        msg_path = os.path.join(tmp, "msg.bin")
        with open(msg_path, "wb") as f:
            f.write(payload_bytes)
        sig_bytes = run_openssl(
            ["pkeyutl", "-sign", "-inkey", priv_pem_path, "-rawin", "-in", msg_path],
            raw_out=True,
        )
    if len(sig_bytes) != 64:
        raise ValueError(f"expected 64-byte Ed25519 signature, got {len(sig_bytes)} bytes")
    return sig_bytes


def verify_ed25519(pub_pem_text, payload_bytes, sig_bytes):
    if len(sig_bytes) != 64:
        raise ValueError(f"invalid Ed25519 signature length: {len(sig_bytes)} bytes (expected 64)")
    with tempfile.TemporaryDirectory() as tmp:
        pub_path = os.path.join(tmp, "pub.pem")
        msg_path = os.path.join(tmp, "msg.bin")
        sig_path = os.path.join(tmp, "sig.bin")
        with open(pub_path, "w", encoding="utf-8") as f:
            f.write(pub_pem_text)
        with open(msg_path, "wb") as f:
            f.write(payload_bytes)
        with open(sig_path, "wb") as f:
            f.write(sig_bytes)
        p = subprocess.run(
            [
                "openssl", "pkeyutl", "-verify",
                "-pubin", "-inkey", pub_path,
                "-rawin", "-in", msg_path,
                "-sigfile", sig_path,
            ],
            capture_output=True,
            text=True,
            timeout=SUBPROCESS_TIMEOUT_SEC,
        )
        if p.returncode != 0:
            detail = (p.stderr.strip() or p.stdout.strip())
            raise ValueError(f"Ed25519 signature verification failed: {detail}")


def verify_manifest_bundle(manifest_dir, pubkey_spec=None):
    """Verifies manifest.json + manifest.json.sig and all locally staged artifact SHA-256s."""
    manifest_path = os.path.join(manifest_dir, "manifest.json")
    sig_path = os.path.join(manifest_dir, "manifest.json.sig")
    if not os.path.isfile(manifest_path):
        raise ValueError(f"missing manifest.json in {manifest_dir}")
    if not os.path.isfile(sig_path):
        raise ValueError(f"missing manifest.json.sig in {manifest_dir}")

    manifest_bytes = open(manifest_path, "rb").read()
    sig_b64 = open(sig_path, encoding="utf-8").read().strip()
    try:
        sig_bytes = base64.b64decode(sig_b64, validate=True)
    except Exception as e:
        raise ValueError(f"malformed base64 in manifest.json.sig: {e}")

    doc = json.loads(manifest_bytes.decode("utf-8"))
    if doc.get("version") != 1:
        raise ValueError(f"unsupported manifest schema version: {doc.get('version')!r}")

    if pubkey_spec:
        pub_pem = pubkey_pem_from_spec(pubkey_spec)
    else:
        pub_file = os.path.join(manifest_dir, "manifest.pub.pem")
        if os.path.isfile(pub_file):
            pub_pem = pubkey_pem_from_spec(pub_file)
        elif doc.get("pubkey_spki_b64"):
            pub_pem = pubkey_pem_from_spec(doc["pubkey_spki_b64"])
        else:
            raise ValueError("no public key supplied and neither manifest.pub.pem nor pubkey_spki_b64 found")

    verify_ed25519(pub_pem, manifest_bytes, sig_bytes)

    _, spki_b64, raw32_b64, _ = extract_ed25519_pubkey_info(pub_pem, is_private=False)
    if doc.get("pubkey_spki_b64") and doc["pubkey_spki_b64"] != spki_b64:
        raise ValueError("manifest pubkey_spki_b64 does not match verifying public key")
    if doc.get("pubkey_raw32_b64") and doc["pubkey_raw32_b64"] != raw32_b64:
        raise ValueError("manifest pubkey_raw32_b64 does not match verifying public key")

    staged_files = []
    for entry in doc.get("keyboxes", []):
        fname = entry.get("file")
        if fname:
            fpath = os.path.join(manifest_dir, fname)
            if not os.path.isfile(fpath):
                raise ValueError(f"missing staged keybox file: {fpath}")
            got_sha = hashlib.sha256(open(fpath, "rb").read()).hexdigest()
            if got_sha != entry.get("sha256"):
                raise ValueError(f"SHA-256 mismatch for {fname}: got {got_sha}, expected {entry.get('sha256')}")
            staged_files.append((fname, "application/xml; charset=utf-8", got_sha))

    for entry in doc.get("pif_profiles", []):
        fname = entry.get("file")
        if fname:
            fpath = os.path.join(manifest_dir, fname)
            if not os.path.isfile(fpath):
                raise ValueError(f"missing staged PIF file: {fpath}")
            got_sha = hashlib.sha256(open(fpath, "rb").read()).hexdigest()
            if got_sha != entry.get("sha256"):
                raise ValueError(f"SHA-256 mismatch for {fname}: got {got_sha}, expected {entry.get('sha256')}")
            staged_files.append((fname, "application/json; charset=utf-8", got_sha))

    targets_file = doc.get("targets_file")
    if targets_file:
        fpath = os.path.join(manifest_dir, targets_file)
        if not os.path.isfile(fpath):
            raise ValueError(f"missing staged targets file: {fpath}")
        got_sha = hashlib.sha256(open(fpath, "rb").read()).hexdigest()
        if got_sha != doc.get("targets_sha256"):
            raise ValueError(f"SHA-256 mismatch for {targets_file}: got {got_sha}, expected {doc.get('targets_sha256')}")
        staged_files.append((targets_file, "text/plain; charset=utf-8", got_sha))

    return doc, staged_files, spki_b64, raw32_b64


def parse_artifact_arg(spec, default_filename, base_url):
    """Parses '<path>' or '<path>:<url>' where url must start with https://."""
    if ":https://" in spec:
        path_part, url_part = spec.split(":https://", 1)
        return path_part, "https://" + url_part
    if ":http://" in spec:
        raise ValueError(f"artifact URL must use https://, got {spec!r}")
    return spec, f"{base_url.rstrip('/')}/{default_filename}"


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
        p = subprocess.run([bin_path, "listremotes"], capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT_SEC)
        if p.returncode == 0 and want in p.stdout.splitlines():
            return bin_path
    return None


def find_wrangler():
    for cand in (shutil.which("wrangler"), "/opt/homebrew/bin/wrangler", "/usr/local/bin/wrangler"):
        if cand and os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def cmd_keygen(args):
    key_path = os.path.abspath(os.path.expanduser(args.key))
    if not args.allow_in_git and is_inside_git_worktree(key_path):
        print(
            f"FAIL: refusing to generate private key inside a git working tree: {key_path}",
            file=sys.stderr,
        )
        print("INTEGRITY_KEYGEN=FAIL")
        return 1

    if os.path.exists(key_path) and not args.force:
        print(f"FAIL: key already exists at {key_path} (pass --force to overwrite)", file=sys.stderr)
        print("INTEGRITY_KEYGEN=FAIL")
        return 1

    key_dir = os.path.dirname(key_path)
    os.makedirs(key_dir, mode=0o700, exist_ok=True)

    try:
        priv_pem = run_openssl(["genpkey", "-algorithm", "ED25519"])
        pub_pem, spki_b64, raw32_b64, spki_sha256 = extract_ed25519_pubkey_info(priv_pem, is_private=True)
    except Exception as e:
        print(f"FAIL: Ed25519 key generation failed: {e}", file=sys.stderr)
        print("INTEGRITY_KEYGEN=FAIL")
        return 1

    fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(priv_pem)
    os.chmod(key_path, 0o600)

    pub_path = args.pub_out or (key_path + ".pub")
    pub_path = os.path.abspath(os.path.expanduser(pub_path))
    with open(pub_path, "w", encoding="utf-8") as f:
        f.write(pub_pem)
    os.chmod(pub_path, 0o644)

    print(f"PRIVATE_KEY_PATH={key_path}")
    print(f"PUBLIC_KEY_PATH={pub_path}")
    print(f"PUBKEY_SPKI_B64={spki_b64}")
    print(f"PUBKEY_RAW32_B64={raw32_b64}")
    print(f"PUBKEY_SHA256={spki_sha256}")
    print("INTEGRITY_KEYGEN=OK")
    return 0


def cmd_validate_keybox(args):
    if not os.path.isfile(args.file):
        print(f"FAIL: no such file: {args.file}", file=sys.stderr)
        print("INTEGRITY_KEYBOX=FAIL")
        return 1
    with open(args.file, encoding="utf-8") as f:
        xml_text = f.read()
    ok, tag, lines, _ = validate_keybox_xml(
        xml_text,
        offline=args.offline,
        roots_file=args.roots_file,
        crl_file=args.crl_file,
        now=args.now,
    )
    stream = sys.stdout if ok else sys.stderr
    for l in lines:
        print(l, file=stream)
    print(f"INTEGRITY_KEYBOX={tag}")
    return 0 if ok else (2 if tag == "REVOKED" else 1)


def cmd_validate_pif(args):
    if not os.path.isfile(args.file):
        print(f"FAIL: no such file: {args.file}", file=sys.stderr)
        print("INTEGRITY_PIF=FAIL")
        return 1
    try:
        revoked = load_revoked_pif_set(args.revoked_file, args.revoked_fingerprint)
    except Exception as e:
        print(f"FAIL: failed to load revoked PIF list: {e}", file=sys.stderr)
        print("INTEGRITY_PIF=FAIL")
        return 1
    with open(args.file, encoding="utf-8") as f:
        raw_text = f.read()
    ok, tag, lines, _ = validate_pif_data(raw_text, revoked_set=revoked, now=args.now)
    stream = sys.stdout if ok else sys.stderr
    for l in lines:
        print(l, file=stream)
    print(f"INTEGRITY_PIF={tag}")
    return 0 if ok else (2 if tag in ("REVOKED", "EXPIRED") else 1)


def cmd_validate_targets(args):
    if not os.path.isfile(args.file):
        print(f"FAIL: no such file: {args.file}", file=sys.stderr)
        print("INTEGRITY_TARGETS=FAIL")
        return 1
    with open(args.file, encoding="utf-8") as f:
        raw_text = f.read()
    ok, tag, lines, _ = validate_targets_text(raw_text)
    stream = sys.stdout if ok else sys.stderr
    for l in lines:
        print(l, file=stream)
    print(f"INTEGRITY_TARGETS={tag}")
    return 0 if ok else 1


def cmd_build_manifest(args):
    key_path = os.path.abspath(os.path.expanduser(args.key))
    if not os.path.isfile(key_path):
        print(f"FAIL: Ed25519 private key not found: {key_path}", file=sys.stderr)
        print("INTEGRITY_MANIFEST=FAIL")
        return 1

    try:
        priv_pem = open(key_path, encoding="utf-8").read()
        pub_pem, spki_b64, raw32_b64, spki_sha256 = extract_ed25519_pubkey_info(priv_pem, is_private=True)
    except Exception as e:
        print(f"FAIL: invalid Ed25519 private key {key_path}: {e}", file=sys.stderr)
        print("INTEGRITY_MANIFEST=FAIL")
        return 1

    conf = read_eos_conf()
    base_url = args.base_url
    if not base_url:
        mirror = conf.get("EOS_OTA_MIRROR", "https://ota-mirror.daryldenson-apps.workers.dev").rstrip("/")
        base_url = f"{mirror}/{DEFAULT_R2_INTEGRITY_PREFIX}"
    if not base_url.startswith("https://"):
        print(f"FAIL: --base-url must start with https://, got {base_url!r}", file=sys.stderr)
        print("INTEGRITY_MANIFEST=FAIL")
        return 1

    try:
        now_dt = resolve_now(args.now)
        revoked_set = load_revoked_pif_set(args.revoked_file, args.revoked_pif)
    except Exception as e:
        print(f"FAIL: manifest parameter error: {e}", file=sys.stderr)
        print("INTEGRITY_MANIFEST=FAIL")
        return 1

    out_dir = os.path.abspath(args.out_dir)
    os.makedirs(out_dir, exist_ok=True)

    keyboxes_list = []
    for idx, spec in enumerate(args.keybox or []):
        default_name = "keybox.xml" if idx == 0 else f"keybox-{idx + 1}.xml"
        try:
            src_path, url = parse_artifact_arg(spec, default_name, base_url)
        except ValueError as e:
            print(f"FAIL: {e}", file=sys.stderr)
            print("INTEGRITY_MANIFEST=FAIL")
            return 1
        if not os.path.isfile(src_path):
            print(f"FAIL: keybox file not found: {src_path}", file=sys.stderr)
            print("INTEGRITY_MANIFEST=FAIL")
            return 1
        xml_text = open(src_path, encoding="utf-8").read()
        ok, tag, lines, meta = validate_keybox_xml(
            xml_text,
            offline=args.offline,
            roots_file=args.roots_file,
            crl_file=args.crl_file,
            now=now_dt,
        )
        for l in lines:
            print(l, file=sys.stdout if ok else sys.stderr)
        if not ok:
            print(f"FAIL: refusing to include invalid/revoked keybox {src_path} ({tag})", file=sys.stderr)
            print("INTEGRITY_MANIFEST=FAIL")
            return 2 if tag == "REVOKED" else 1
        shutil.copyfile(src_path, os.path.join(out_dir, default_name))
        keyboxes_list.append({
            "id": f"keybox-{idx + 1}",
            "priority": idx + 1,
            "file": default_name,
            "url": url,
            "sha256": meta["sha256"],
            "size": meta["size"],
            "algorithms": meta["algorithms"],
            "not_after_utc": meta["not_after_utc"],
        })

    pif_list = []
    for idx, spec in enumerate(args.pif or []):
        default_name = "pif.json" if idx == 0 else f"pif-{idx + 1}.json"
        try:
            src_path, url = parse_artifact_arg(spec, default_name, base_url)
        except ValueError as e:
            print(f"FAIL: {e}", file=sys.stderr)
            print("INTEGRITY_MANIFEST=FAIL")
            return 1
        if not os.path.isfile(src_path):
            print(f"FAIL: PIF file not found: {src_path}", file=sys.stderr)
            print("INTEGRITY_MANIFEST=FAIL")
            return 1
        raw_text = open(src_path, encoding="utf-8").read()
        ok, tag, lines, meta = validate_pif_data(raw_text, revoked_set=revoked_set, now=now_dt)
        for l in lines:
            print(l, file=sys.stdout if ok else sys.stderr)
        if not ok:
            print(f"FAIL: refusing to include invalid/revoked/expired PIF {src_path} ({tag})", file=sys.stderr)
            print("INTEGRITY_MANIFEST=FAIL")
            return 2 if tag in ("REVOKED", "EXPIRED") else 1
        shutil.copyfile(src_path, os.path.join(out_dir, default_name))
        pif_list.append({
            "id": f"pif-{idx + 1}",
            "priority": idx + 1,
            "status": meta["status"],
            "file": default_name,
            "url": url,
            "sha256": meta["sha256"],
            "size": meta["size"],
            "device": meta["device"],
            "fingerprint": meta["fingerprint"],
            "security_patch": meta["security_patch"],
            "expires_utc": meta["expires_utc"],
        })

    targets_meta = None
    targets_url = None
    targets_fname = None
    if args.targets:
        targets_fname = "target.txt"
        try:
            src_path, targets_url = parse_artifact_arg(args.targets, targets_fname, base_url)
        except ValueError as e:
            print(f"FAIL: {e}", file=sys.stderr)
            print("INTEGRITY_MANIFEST=FAIL")
            return 1
        if not os.path.isfile(src_path):
            print(f"FAIL: targets file not found: {src_path}", file=sys.stderr)
            print("INTEGRITY_MANIFEST=FAIL")
            return 1
        raw_text = open(src_path, encoding="utf-8").read()
        ok, tag, lines, targets_meta = validate_targets_text(raw_text)
        for l in lines:
            print(l, file=sys.stdout if ok else sys.stderr)
        if not ok:
            print(f"FAIL: refusing to include invalid target.txt {src_path} ({tag})", file=sys.stderr)
            print("INTEGRITY_MANIFEST=FAIL")
            return 1
        shutil.copyfile(src_path, os.path.join(out_dir, targets_fname))

    manifest_doc = {
        "version": 1,
        "generated_utc": format_iso_utc(now_dt),
        "pubkey_spki_b64": spki_b64,
        "pubkey_raw32_b64": raw32_b64,
        "pubkey_sha256": spki_sha256,
        "keyboxes": keyboxes_list,
        "pif_profiles": pif_list,
        "revoked_pif_fingerprints": sorted(revoked_set),
        "targets_file": targets_fname,
        "targets_url": targets_url,
        "targets_sha256": targets_meta["sha256"] if targets_meta else None,
        "targets_version": args.targets_version or now_dt.strftime("%Y%m%d%H%M%S"),
        "targets_count": targets_meta["count"] if targets_meta else 0,
    }

    manifest_json_text = json.dumps(manifest_doc, indent=2, sort_keys=False) + "\n"
    manifest_bytes = manifest_json_text.encode("utf-8")
    manifest_path = os.path.join(out_dir, "manifest.json")
    sig_path = os.path.join(out_dir, "manifest.json.sig")
    pub_path = os.path.join(out_dir, "manifest.pub.pem")

    with open(manifest_path, "wb") as f:
        f.write(manifest_bytes)
    with open(pub_path, "w", encoding="utf-8") as f:
        f.write(pub_pem)

    try:
        sig_bytes = sign_ed25519(key_path, manifest_bytes)
        sig_b64 = base64.b64encode(sig_bytes).decode("ascii")
        with open(sig_path, "w", encoding="utf-8") as f:
            f.write(sig_b64 + "\n")
        # Immediate cryptographic self-verification against the public key
        verify_manifest_bundle(out_dir, pubkey_spec=spki_b64)
    except Exception as e:
        print(f"FAIL: manifest signing / self-verification failed: {e}", file=sys.stderr)
        print("INTEGRITY_MANIFEST=FAIL")
        return 1

    manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
    print(f"MANIFEST_PATH={manifest_path}")
    print(f"SIGNATURE_PATH={sig_path}")
    print(f"MANIFEST_SHA256={manifest_sha}")
    print(f"SIGNATURE_B64={sig_b64}")
    print("INTEGRITY_MANIFEST=OK")
    return 0


def cmd_verify_manifest(args):
    try:
        doc, staged, spki_b64, _ = verify_manifest_bundle(args.manifest_dir, pubkey_spec=args.pubkey)
    except Exception as e:
        print(f"FAIL: {e}", file=sys.stderr)
        print("INTEGRITY_VERIFY=FAIL")
        return 1
    print(
        f"OK: manifest v{doc['version']} verified (pubkey={spki_b64[:16]}..., "
        f"keyboxes={len(doc.get('keyboxes', []))}, pifs={len(doc.get('pif_profiles', []))}, "
        f"staged_files={len(staged)})"
    )
    print("INTEGRITY_VERIFY=OK")
    return 0


def cmd_publish(args):
    manifest_dir = os.path.abspath(args.manifest_dir)
    try:
        _, staged_files, _, _ = verify_manifest_bundle(manifest_dir, pubkey_spec=args.pubkey)
    except Exception as e:
        print(f"FAIL: refusing to publish unverified manifest bundle: {e}", file=sys.stderr)
        print("INTEGRITY_PUBLISH=FAIL")
        return 1

    conf = read_eos_conf()
    r2_remote = args.r2_remote or conf.get("EOS_R2_REMOTE", "r2:denson9874-ota")
    r2_prefix = (args.r2_prefix or conf.get("EOS_INTEGRITY_R2_PREFIX", DEFAULT_R2_INTEGRITY_PREFIX)).strip("/")
    mirror_base = (
        args.mirror_url
        or conf.get("EOS_OTA_MIRROR", "https://ota-mirror.daryldenson-apps.workers.dev")
    ).rstrip("/")

    if not re.fullmatch(r"[A-Za-z0-9_-]+:[a-z0-9][a-z0-9-]*", r2_remote):
        print(f"FAIL: invalid R2 remote {r2_remote!r} (expected <remote>:<bucket>)", file=sys.stderr)
        print("INTEGRITY_PUBLISH=FAIL")
        return 1
    if not r2_prefix or ".." in r2_prefix.split("/"):
        print(f"FAIL: invalid R2 prefix {r2_prefix!r}", file=sys.stderr)
        print("INTEGRITY_PUBLISH=FAIL")
        return 1

    # Upload referenced artifacts first, then manifest.json.sig, and manifest.json last
    upload_items = list(staged_files)
    sig_sha = hashlib.sha256(open(os.path.join(manifest_dir, "manifest.json.sig"), "rb").read()).hexdigest()
    man_sha = hashlib.sha256(open(os.path.join(manifest_dir, "manifest.json"), "rb").read()).hexdigest()
    upload_items.append(("manifest.json.sig", "text/plain; charset=utf-8", sig_sha))
    upload_items.append(("manifest.json", "application/json; charset=utf-8", man_sha))

    remote_name, bucket = r2_remote.split(":", 1)

    if args.dry_run:
        for fname, ctype, sha in upload_items:
            local_path = os.path.join(manifest_dir, fname)
            dest = f"{r2_remote}/{r2_prefix}/{fname}"
            print(
                f"DRY_RUN: rclone copyto --s3-no-check-bucket "
                f"--header-upload 'Cache-Control: no-store' "
                f"--header-upload 'Content-Type: {ctype}' "
                f"{local_path} {dest} (sha256={sha})"
            )
        print("INTEGRITY_PUBLISH=DRY_RUN")
        return 0

    rclone = find_rclone_with_remote(remote_name)
    wrangler = None if rclone else find_wrangler()
    if not rclone and not wrangler:
        print(
            f"FAIL: neither rclone with '{remote_name}:' configured nor wrangler found",
            file=sys.stderr,
        )
        print("INTEGRITY_PUBLISH=FAIL")
        return 1

    run_env = dict(os.environ)
    if wrangler:
        wdir = os.path.dirname(wrangler)
        if wdir not in run_env.get("PATH", "").split(os.pathsep):
            run_env["PATH"] = f"{wdir}{os.pathsep}{run_env.get('PATH', '')}"

    for fname, ctype, want_sha in upload_items:
        local_path = os.path.join(manifest_dir, fname)
        r2_key = f"{r2_prefix}/{fname}"
        if rclone:
            dest = f"{r2_remote}/{r2_key}"
            print(f"== uploading {fname} -> {dest} (rclone, Cache-Control: no-store)")
            cmd = [
                rclone, "copyto",
                "--s3-no-check-bucket",
                "--header-upload", "Cache-Control: no-store",
                "--header-upload", f"Content-Type: {ctype}",
                local_path, dest,
            ]
        else:
            dest = f"{bucket}/{r2_key}"
            print(f"== uploading {fname} -> {dest} (wrangler --remote, Cache-Control: no-store)")
            cmd = [
                wrangler, "r2", "object", "put", dest,
                "--remote",
                "--file", local_path,
                "--cache-control", "no-store",
                "--content-type", ctype,
            ]
        p = subprocess.run(cmd, capture_output=True, text=True, env=run_env, timeout=60)
        if p.returncode != 0:
            detail = (p.stderr.strip() or p.stdout.strip())
            print(f"FAIL: R2 upload failed for {fname}:\n{detail}", file=sys.stderr)
            print("INTEGRITY_PUBLISH=FAIL")
            return 1

        live_url = f"{mirror_base}/{r2_key}"
        try:
            got_bytes, _ = fetch_bytes(live_url)
        except Exception as e:
            print(f"FAIL: uploaded {dest}, but {live_url} failed to fetch: {e}", file=sys.stderr)
            print("INTEGRITY_PUBLISH=FAIL")
            return 1
        got_sha = hashlib.sha256(got_bytes).hexdigest()
        if got_sha != want_sha:
            print(f"FAIL: {live_url} served sha256={got_sha}, expected {want_sha}", file=sys.stderr)
            print("INTEGRITY_PUBLISH=FAIL")
            return 1

    print(f"OK: published {len(upload_items)} object(s) to {r2_remote}/{r2_prefix}/")
    print("INTEGRITY_PUBLISH=OK")
    return 0


def build_parser():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_kg = sub.add_parser("keygen", help="generate an Ed25519 feed signing keypair outside git")
    p_kg.add_argument(
        "--key", "--out", dest="key", default=DEFAULT_KEY_PATH,
        help=f"output path for private key PEM (default: {DEFAULT_KEY_PATH})",
    )
    p_kg.add_argument("--pub-out", help="output path for public key PEM (default: <key>.pub)")
    p_kg.add_argument("--force", action="store_true", help="overwrite existing keypair")
    p_kg.add_argument("--allow-in-git", action="store_true", help=argparse.SUPPRESS)
    p_kg.set_defaults(func=cmd_keygen)

    p_vk = sub.add_parser("validate-keybox", help="validate a keybox.xml against Google roots and CRL")
    p_vk.add_argument("file", help="path to keybox.xml")
    p_vk.add_argument("--offline", action="store_true", help="skip live Google root/CRL network checks")
    p_vk.add_argument("--roots-file", help="optional local JSON file of trusted root certs/SHA-256s")
    p_vk.add_argument("--crl-file", help="optional local Google attestation status CRL JSON file")
    p_vk.add_argument("--now", help="override current UTC timestamp (ISO-8601) for deterministic testing")
    p_vk.set_defaults(func=cmd_validate_keybox)

    p_vp = sub.add_parser("validate-pif", help="validate a canary PIF profile JSON")
    p_vp.add_argument("file", help="path to pif.json")
    p_vp.add_argument("--revoked-file", help="optional JSON file containing revoked_pif_fingerprints")
    p_vp.add_argument(
        "--revoked-fingerprint", action="append", default=[],
        help="additional revoked fingerprint or build ID (repeatable)",
    )
    p_vp.add_argument("--now", help="override current UTC timestamp (ISO-8601)")
    p_vp.set_defaults(func=cmd_validate_pif)

    p_vt = sub.add_parser("validate-targets", help="validate a TrickyStore target.txt package list")
    p_vt.add_argument("file", help="path to target.txt")
    p_vt.set_defaults(func=cmd_validate_targets)

    p_bm = sub.add_parser("build-manifest", help="validate artifacts, assemble manifest.json, and sign with Ed25519")
    p_bm.add_argument("--out-dir", required=True, help="output directory for manifest.json, manifest.json.sig, and staged files")
    p_bm.add_argument("--key", default=DEFAULT_KEY_PATH, help="path to Ed25519 private key PEM")
    p_bm.add_argument("--keybox", action="append", default=[], help="keybox path or <path>:<https_url> (repeatable, priority order)")
    p_bm.add_argument("--pif", action="append", default=[], help="PIF JSON path or <path>:<https_url> (repeatable, priority order)")
    p_bm.add_argument("--targets", help="target.txt path or <path>:<https_url>")
    p_bm.add_argument("--targets-version", help="explicit targets_version string")
    p_bm.add_argument("--revoked-file", help="optional JSON file of revoked_pif_fingerprints")
    p_bm.add_argument("--revoked-pif", action="append", default=[], help="revoked PIF fingerprint (repeatable)")
    p_bm.add_argument("--base-url", help="base HTTPS URL for feed artifacts")
    p_bm.add_argument("--offline", action="store_true", help="use offline root check when validating keyboxes")
    p_bm.add_argument("--roots-file", help="optional local JSON file of trusted root certs/SHA-256s")
    p_bm.add_argument("--crl-file", help="optional local CRL JSON file")
    p_bm.add_argument("--now", help="override current UTC timestamp (ISO-8601)")
    p_bm.set_defaults(func=cmd_build_manifest)

    p_vm = sub.add_parser("verify-manifest", help="verify manifest.json + manifest.json.sig and staged SHA-256s")
    p_vm.add_argument("--manifest-dir", required=True, help="directory containing manifest.json and manifest.json.sig")
    p_vm.add_argument("--pubkey", help="Ed25519 public key (PEM path, SPKI base64, or raw-32-byte base64)")
    p_vm.set_defaults(func=cmd_verify_manifest)

    p_pub = sub.add_parser("publish", help="verify and upload signed integrity feed to R2 with Cache-Control: no-store")
    p_pub.add_argument("--manifest-dir", required=True, help="directory containing verified manifest bundle")
    p_pub.add_argument("--pubkey", help="optional Ed25519 public key override for pre-publish verification")
    p_pub.add_argument("--r2-remote", help="override EOS_R2_REMOTE (<remote>:<bucket>)")
    p_pub.add_argument("--r2-prefix", help=f"override R2 object prefix (default: {DEFAULT_R2_INTEGRITY_PREFIX})")
    p_pub.add_argument("--mirror-url", help="override EOS_OTA_MIRROR base URL")
    p_pub.add_argument("--dry-run", action="store_true", help="verify bundle and print upload commands without network calls")
    p_pub.set_defaults(func=cmd_publish)

    return ap


def main(argv=None):
    ap = build_parser()
    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())

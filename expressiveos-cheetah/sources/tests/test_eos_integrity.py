#!/usr/bin/env python3
"""Offline unit tests for expressiveos-cheetah/tools/eos-integrity.py.

All certificates, keys, CRLs, PIF profiles, and target lists are synthesized
dynamically in a temporary directory during test setup (zero static keys in git).
Every subprocess call enforces an explicit timeout.
"""

import base64
import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
KIT_DIR = TESTS_DIR.parent.parent
INTEGRITY_TOOL = KIT_DIR / "tools" / "eos-integrity.py"
SUBPROCESS_TIMEOUT = 15


def run_cmd(cmd, cwd=None, check=True, timeout=SUBPROCESS_TIMEOUT):
    proc = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    if check and proc.returncode != 0:
        raise AssertionError(
            f"command failed ({proc.returncode}): {' '.join(str(c) for c in cmd)}\n"
            f"STDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        )
    return proc


def run_tool(args, check=False, timeout=SUBPROCESS_TIMEOUT):
    return run_cmd([sys.executable, str(INTEGRITY_TOOL)] + list(args), check=check, timeout=timeout)


class TestEosIntegrityTool(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory(prefix="eos-integrity-test-")
        cls.tmp_dir = Path(cls._tmp.name)
        cls._build_synthetic_pki(cls.tmp_dir)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    @classmethod
    def _build_synthetic_pki(cls, base: Path):
        pki = base / "pki"
        pki.mkdir(parents=True, exist_ok=True)

        # OpenSSL config for Root CA, Intermediate CA, and Leaf certificates
        openssl_cnf = pki / "openssl.cnf"
        openssl_cnf.write_text(
            "[ req ]\n"
            "distinguished_name = req_dn\n"
            "prompt = no\n"
            "[ req_dn ]\n"
            "CN = Test Attestation Root\n"
            "[ v3_ca ]\n"
            "basicConstraints = critical,CA:TRUE\n"
            "keyUsage = critical,keyCertSign,cRLSign\n"
            "subjectKeyIdentifier = hash\n"
            "[ v3_inter ]\n"
            "basicConstraints = critical,CA:TRUE,pathlen:0\n"
            "keyUsage = critical,keyCertSign,cRLSign\n"
            "subjectKeyIdentifier = hash\n"
            "authorityKeyIdentifier = keyid:always\n"
            "[ v3_leaf ]\n"
            "basicConstraints = critical,CA:FALSE\n"
            "keyUsage = critical,digitalSignature\n"
            "subjectKeyIdentifier = hash\n"
            "authorityKeyIdentifier = keyid:always\n",
            encoding="utf-8",
        )

        # 1. Root CA (RSA-2048)
        root_key = pki / "root.key"
        root_pem = pki / "root.pem"
        run_cmd(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(root_key)])
        run_cmd([
            "openssl", "req", "-x509", "-new", "-key", str(root_key),
            "-subj", "/CN=Synthetic Attestation Root CA",
            "-days", "3650", "-sha256",
            "-config", str(openssl_cnf), "-extensions", "v3_ca",
            "-set_serial", "0x1001",
            "-out", str(root_pem),
        ])

        # 2. Intermediate CA (RSA-2048)
        inter_key = pki / "inter.key"
        inter_csr = pki / "inter.csr"
        inter_pem = pki / "inter.pem"
        run_cmd(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(inter_key)])
        run_cmd([
            "openssl", "req", "-new", "-key", str(inter_key),
            "-subj", "/CN=Synthetic Attestation Intermediate CA",
            "-config", str(openssl_cnf),
            "-out", str(inter_csr),
        ])
        run_cmd([
            "openssl", "x509", "-req", "-in", str(inter_csr),
            "-CA", str(root_pem), "-CAkey", str(root_key),
            "-set_serial", "0x2002",
            "-days", "1825", "-sha256",
            "-extfile", str(openssl_cnf), "-extensions", "v3_inter",
            "-out", str(inter_pem),
        ])

        # 3. EC Leaf (prime256v1)
        ec_key = pki / "ec_leaf.key"
        ec_csr = pki / "ec_leaf.csr"
        ec_pem = pki / "ec_leaf.pem"
        run_cmd(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(ec_key)])
        run_cmd([
            "openssl", "req", "-new", "-key", str(ec_key),
            "-subj", "/CN=Synthetic EC Hardware Keybox Leaf",
            "-config", str(openssl_cnf),
            "-out", str(ec_csr),
        ])
        run_cmd([
            "openssl", "x509", "-req", "-in", str(ec_csr),
            "-CA", str(inter_pem), "-CAkey", str(inter_key),
            "-set_serial", "0x3003abcd",
            "-days", "730", "-sha256",
            "-extfile", str(openssl_cnf), "-extensions", "v3_leaf",
            "-out", str(ec_pem),
        ])

        # 4. RSA Leaf (RSA-2048)
        rsa_key = pki / "rsa_leaf.key"
        rsa_csr = pki / "rsa_leaf.csr"
        rsa_pem = pki / "rsa_leaf.pem"
        run_cmd(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(rsa_key)])
        run_cmd([
            "openssl", "req", "-new", "-key", str(rsa_key),
            "-subj", "/CN=Synthetic RSA Hardware Keybox Leaf",
            "-config", str(openssl_cnf),
            "-out", str(rsa_csr),
        ])
        run_cmd([
            "openssl", "x509", "-req", "-in", str(rsa_csr),
            "-CA", str(inter_pem), "-CAkey", str(inter_key),
            "-set_serial", "0x4004ef01",
            "-days", "730", "-sha256",
            "-extfile", str(openssl_cnf), "-extensions", "v3_leaf",
            "-out", str(rsa_pem),
        ])

        # 5. Wrong EC key (for mismatch test)
        wrong_ec_key = pki / "wrong_ec.key"
        run_cmd(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(wrong_ec_key)])

        cls.root_pem_text = root_pem.read_text(encoding="utf-8")
        cls.inter_pem_text = inter_pem.read_text(encoding="utf-8")
        cls.ec_key_text = ec_key.read_text(encoding="utf-8")
        cls.ec_pem_text = ec_pem.read_text(encoding="utf-8")
        cls.rsa_key_text = rsa_key.read_text(encoding="utf-8")
        cls.rsa_pem_text = rsa_pem.read_text(encoding="utf-8")
        cls.wrong_ec_key_text = wrong_ec_key.read_text(encoding="utf-8")

        # Trusted roots JSON & clean/revoked CRL JSONs
        cls.roots_json = base / "roots.json"
        cls.roots_json.write_text(json.dumps([cls.root_pem_text]), encoding="utf-8")

        cls.clean_crl_json = base / "crl_clean.json"
        cls.clean_crl_json.write_text(json.dumps({"entries": {}}), encoding="utf-8")

        cls.revoked_crl_json = base / "crl_revoked.json"
        cls.revoked_crl_json.write_text(
            json.dumps({
                "entries": {
                    "3003abcd": {
                        "status": "REVOKED",
                        "reason": "KEY_COMPROMISE",
                    }
                }
            }),
            encoding="utf-8",
        )

        # Valid keybox.xml
        cls.valid_keybox = base / "keybox_valid.xml"
        cls.valid_keybox.write_text(
            cls._make_keybox_xml(cls.ec_key_text, cls.rsa_key_text),
            encoding="utf-8",
        )

        # Mismatched private key keybox.xml
        cls.mismatch_keybox = base / "keybox_mismatch.xml"
        cls.mismatch_keybox.write_text(
            cls._make_keybox_xml(cls.wrong_ec_key_text, cls.rsa_key_text),
            encoding="utf-8",
        )

    @classmethod
    def _make_keybox_xml(cls, ec_priv_pem: str, rsa_priv_pem: str) -> str:
        return (
            '<?xml version="1.0"?>\n'
            "<AndroidAttestation>\n"
            "  <NumberOfKeyboxes>1</NumberOfKeyboxes>\n"
            '  <Keybox DeviceID="synthetic-test-keybox-01">\n'
            '    <Key algorithm="ecdsa">\n'
            f'      <PrivateKey format="pem">\n{ec_priv_pem}      </PrivateKey>\n'
            "      <CertificateChain>\n"
            "        <NumberOfCertificates>3</NumberOfCertificates>\n"
            f'        <Certificate format="pem">\n{cls.ec_pem_text}        </Certificate>\n'
            f'        <Certificate format="pem">\n{cls.inter_pem_text}        </Certificate>\n'
            f'        <Certificate format="pem">\n{cls.root_pem_text}        </Certificate>\n'
            "      </CertificateChain>\n"
            "    </Key>\n"
            '    <Key algorithm="rsa">\n'
            f'      <PrivateKey format="pem">\n{rsa_priv_pem}      </PrivateKey>\n'
            "      <CertificateChain>\n"
            "        <NumberOfCertificates>3</NumberOfCertificates>\n"
            f'        <Certificate format="pem">\n{cls.rsa_pem_text}        </Certificate>\n'
            f'        <Certificate format="pem">\n{cls.inter_pem_text}        </Certificate>\n'
            f'        <Certificate format="pem">\n{cls.root_pem_text}        </Certificate>\n'
            "      </CertificateChain>\n"
            "    </Key>\n"
            "  </Keybox>\n"
            "</AndroidAttestation>\n"
        )

    def _make_valid_pif_dict(self):
        return {
            "MANUFACTURER": "Google",
            "MODEL": "Pixel 10 Pro XL",
            "FINGERPRINT": "google/kodiak_beta/kodiak:17/CP4A.261105.040.D1/14281990:user/release-keys",
            "BRAND": "google",
            "PRODUCT": "kodiak_beta",
            "DEVICE": "kodiak",
            "RELEASE": "17",
            "ID": "CP4A.261105.040.D1",
            "INCREMENTAL": "14281990",
            "TYPE": "user",
            "TAGS": "release-keys",
            "SECURITY_PATCH": "2026-11-05",
            "DEVICE_INITIAL_SDK_INT": "36",
            "expires_utc": "2026-12-20T00:00:00Z",
        }

    def test_01_keygen_permissions_and_git_guard(self):
        key_dir = self.tmp_dir / "keys"
        priv_path = key_dir / "test-ed25519.pem"
        proc = run_tool(["keygen", "--key", str(priv_path)])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("INTEGRITY_KEYGEN=OK", proc.stdout)
        self.assertTrue(priv_path.is_file())
        self.assertEqual(stat.S_IMODE(priv_path.stat().st_mode), 0o600)

        fields = dict(
            line.split("=", 1) for line in proc.stdout.strip().splitlines() if "=" in line
        )
        spki_raw = base64.b64decode(fields["PUBKEY_SPKI_B64"], validate=True)
        raw32 = base64.b64decode(fields["PUBKEY_RAW32_B64"], validate=True)
        self.assertEqual(len(spki_raw), 44)
        self.assertEqual(len(raw32), 32)
        self.assertEqual(spki_raw[12:], raw32)

        # Refuses overwrite without --force
        proc_dup = run_tool(["keygen", "--key", str(priv_path)])
        self.assertEqual(proc_dup.returncode, 1)
        self.assertIn("INTEGRITY_KEYGEN=FAIL", proc_dup.stdout)

        # Refuses generation inside a git working tree
        fake_git = self.tmp_dir / "fake_git_repo"
        (fake_git / ".git").mkdir(parents=True, exist_ok=True)
        in_git_key = fake_git / "sub" / "bad.pem"
        proc_git = run_tool(["keygen", "--key", str(in_git_key)])
        self.assertEqual(proc_git.returncode, 1)
        self.assertIn("INTEGRITY_KEYGEN=FAIL", proc_git.stdout)
        self.assertFalse(in_git_key.exists())

    def test_02_validate_keybox_valid_mismatch_untrusted_expired_revoked(self):
        # 1. Valid synthetic EC+RSA keybox
        proc_ok = run_tool([
            "validate-keybox", str(self.valid_keybox),
            "--roots-file", str(self.roots_json),
            "--crl-file", str(self.clean_crl_json),
        ])
        self.assertEqual(proc_ok.returncode, 0, proc_ok.stderr)
        self.assertIn("INTEGRITY_KEYBOX=OK", proc_ok.stdout)
        self.assertNotIn("PRIVATE KEY", proc_ok.stdout + proc_ok.stderr)

        # 2. Private key does not match leaf certificate
        proc_mis = run_tool([
            "validate-keybox", str(self.mismatch_keybox),
            "--roots-file", str(self.roots_json),
            "--crl-file", str(self.clean_crl_json),
        ])
        self.assertEqual(proc_mis.returncode, 1)
        self.assertIn("INTEGRITY_KEYBOX=FAIL", proc_mis.stdout)
        self.assertIn("PrivateKey does not match leaf", proc_mis.stderr)

        # 3. Untrusted root (offline mode checks against pinned Google Hardware Attestation roots)
        proc_untrusted = run_tool([
            "validate-keybox", str(self.valid_keybox),
            "--offline",
        ])
        self.assertEqual(proc_untrusted.returncode, 1)
        self.assertIn("INTEGRITY_KEYBOX=FAIL", proc_untrusted.stdout)
        self.assertIn("NOT a trusted Google Hardware Attestation Root CA", proc_untrusted.stderr)

        # 4. Expired certificate check via --now
        proc_exp = run_tool([
            "validate-keybox", str(self.valid_keybox),
            "--roots-file", str(self.roots_json),
            "--crl-file", str(self.clean_crl_json),
            "--now", "2035-01-01T00:00:00Z",
        ])
        self.assertEqual(proc_exp.returncode, 1)
        self.assertIn("INTEGRITY_KEYBOX=FAIL", proc_exp.stdout)
        self.assertIn("expired at", proc_exp.stderr)

        # 5. Revoked leaf serial in CRL returns exit code 2 + INTEGRITY_KEYBOX=REVOKED
        proc_rev = run_tool([
            "validate-keybox", str(self.valid_keybox),
            "--roots-file", str(self.roots_json),
            "--crl-file", str(self.revoked_crl_json),
        ])
        self.assertEqual(proc_rev.returncode, 2)
        self.assertIn("INTEGRITY_KEYBOX=REVOKED", proc_rev.stdout)
        self.assertIn("CRL hit", proc_rev.stderr)

    def test_03_validate_pif_valid_missing_expired_revoked(self):
        pif_dir = self.tmp_dir / "pifs"
        pif_dir.mkdir(exist_ok=True)

        valid_pif = pif_dir / "valid.json"
        valid_doc = self._make_valid_pif_dict()
        valid_pif.write_text(json.dumps(valid_doc), encoding="utf-8")

        # 1. Valid canary PIF
        proc_ok = run_tool([
            "validate-pif", str(valid_pif),
            "--now", "2026-11-19T12:00:00Z",
        ])
        self.assertEqual(proc_ok.returncode, 0, proc_ok.stderr)
        self.assertIn("INTEGRITY_PIF=OK", proc_ok.stdout)

        # 2. Missing required field
        bad_pif = pif_dir / "missing.json"
        bad_doc = dict(valid_doc)
        del bad_doc["SECURITY_PATCH"]
        bad_pif.write_text(json.dumps(bad_doc), encoding="utf-8")
        proc_bad = run_tool(["validate-pif", str(bad_pif)])
        self.assertEqual(proc_bad.returncode, 1)
        self.assertIn("INTEGRITY_PIF=FAIL", proc_bad.stdout)

        # 3. Expired expires_utc returns exit code 2 + INTEGRITY_PIF=EXPIRED
        proc_exp = run_tool([
            "validate-pif", str(valid_pif),
            "--now", "2027-01-01T00:00:00Z",
        ])
        self.assertEqual(proc_exp.returncode, 2)
        self.assertIn("INTEGRITY_PIF=EXPIRED", proc_exp.stdout)

        # 4. Revoked fingerprint returns exit code 2 + INTEGRITY_PIF=REVOKED
        rev_file = pif_dir / "revoked.json"
        rev_file.write_text(
            json.dumps({"revoked_pif_fingerprints": [valid_doc["FINGERPRINT"]]}),
            encoding="utf-8",
        )
        proc_rev = run_tool([
            "validate-pif", str(valid_pif),
            "--revoked-file", str(rev_file),
            "--now", "2026-11-19T12:00:00Z",
        ])
        self.assertEqual(proc_rev.returncode, 2)
        self.assertIn("INTEGRITY_PIF=REVOKED", proc_rev.stdout)

    def test_04_validate_targets_valid_syntax_and_xposed_rejection(self):
        tgt_dir = self.tmp_dir / "targets"
        tgt_dir.mkdir(exist_ok=True)

        valid_tgt = tgt_dir / "target_valid.txt"
        valid_tgt.write_text(
            "# TrickyStore targets for ExpressiveOS 2.0\n"
            "com.google.android.gms!\n"
            "com.android.vending?\n"
            "com.google.android.gsf\n",
            encoding="utf-8",
        )
        proc_ok = run_tool(["validate-targets", str(valid_tgt)])
        self.assertEqual(proc_ok.returncode, 0, proc_ok.stderr)
        self.assertIn("INTEGRITY_TARGETS=OK", proc_ok.stdout)

        # Reject invalid characters
        bad_syntax = tgt_dir / "target_bad_syntax.txt"
        bad_syntax.write_text("com.google.android.gms!\ncom.bad;whoami\n", encoding="utf-8")
        proc_syntax = run_tool(["validate-targets", str(bad_syntax)])
        self.assertEqual(proc_syntax.returncode, 1)
        self.assertIn("INTEGRITY_TARGETS=FAIL", proc_syntax.stdout)

        # Reject XPOSED_PACKAGES
        xposed_tgt = tgt_dir / "target_xposed.txt"
        xposed_tgt.write_text(
            "com.google.android.gms!\n"
            "org.lsposed.manager!\n",
            encoding="utf-8",
        )
        proc_xp = run_tool(["validate-targets", str(xposed_tgt)])
        self.assertEqual(proc_xp.returncode, 1)
        self.assertIn("INTEGRITY_TARGETS=FAIL", proc_xp.stdout)
        self.assertIn("XPOSED_PACKAGES", proc_xp.stderr)

    def test_05_build_verify_tamper_and_publish_dry_run(self):
        work = self.tmp_dir / "bundle_test"
        work.mkdir(exist_ok=True)

        priv_key = work / "feed-ed25519.pem"
        proc_kg = run_tool(["keygen", "--key", str(priv_key)])
        self.assertEqual(proc_kg.returncode, 0, proc_kg.stderr)
        kg_fields = dict(
            line.split("=", 1) for line in proc_kg.stdout.strip().splitlines() if "=" in line
        )
        spki_b64 = kg_fields["PUBKEY_SPKI_B64"]
        raw32_b64 = kg_fields["PUBKEY_RAW32_B64"]

        pif_file = work / "pif.json"
        pif_file.write_text(json.dumps(self._make_valid_pif_dict()), encoding="utf-8")

        tgt_file = work / "target.txt"
        tgt_file.write_text(
            "com.google.android.gms!\n"
            "com.android.vending\n",
            encoding="utf-8",
        )

        out_dir = work / "dist"
        proc_bm = run_tool([
            "build-manifest",
            "--out-dir", str(out_dir),
            "--key", str(priv_key),
            "--keybox", str(self.valid_keybox),
            "--pif", str(pif_file),
            "--targets", str(tgt_file),
            "--targets-version", "2026111901",
            "--revoked-pif", "google/old_beta/old:16/BP11.250101.001/11111111:user/release-keys",
            "--roots-file", str(self.roots_json),
            "--crl-file", str(self.clean_crl_json),
            "--now", "2026-11-19T12:00:00Z",
        ])
        self.assertEqual(proc_bm.returncode, 0, proc_bm.stderr)
        self.assertIn("INTEGRITY_MANIFEST=OK", proc_bm.stdout)

        manifest_path = out_dir / "manifest.json"
        sig_path = out_dir / "manifest.json.sig"
        self.assertTrue(manifest_path.is_file())
        self.assertTrue(sig_path.is_file())

        doc = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(doc["version"], 1)
        self.assertEqual(doc["pubkey_spki_b64"], spki_b64)
        self.assertEqual(doc["pubkey_raw32_b64"], raw32_b64)
        self.assertEqual(len(doc["keyboxes"]), 1)
        self.assertEqual(len(doc["pif_profiles"]), 1)
        self.assertEqual(doc["targets_count"], 2)
        self.assertEqual(doc["targets_version"], "2026111901")

        # Verify with both SPKI base64 and raw-32-byte base64 public keys
        for pub in (spki_b64, raw32_b64):
            proc_vm = run_tool([
                "verify-manifest",
                "--manifest-dir", str(out_dir),
                "--pubkey", pub,
            ])
            self.assertEqual(proc_vm.returncode, 0, proc_vm.stderr)
            self.assertIn("INTEGRITY_VERIFY=OK", proc_vm.stdout)

        # Dry-run publish verifies bundle and emits Cache-Control: no-store
        proc_pub = run_tool([
            "publish",
            "--manifest-dir", str(out_dir),
            "--pubkey", spki_b64,
            "--dry-run",
        ])
        self.assertEqual(proc_pub.returncode, 0, proc_pub.stderr)
        self.assertIn("INTEGRITY_PUBLISH=DRY_RUN", proc_pub.stdout)
        self.assertIn("Cache-Control: no-store", proc_pub.stdout)

        # Verify manifest.json is uploaded LAST in dry-run output
        dry_lines = [l for l in proc_pub.stdout.splitlines() if l.startswith("DRY_RUN:")]
        self.assertEqual(len(dry_lines), 5)
        self.assertIn("/manifest.json.sig ", dry_lines[-2])
        self.assertIn("/manifest.json ", dry_lines[-1])

        # Tamper with 1 byte of manifest.json -> verify-manifest and publish must fail
        orig_bytes = manifest_path.read_bytes()
        manifest_path.write_bytes(orig_bytes + b" ")
        proc_tamper = run_tool([
            "verify-manifest",
            "--manifest-dir", str(out_dir),
            "--pubkey", spki_b64,
        ])
        self.assertEqual(proc_tamper.returncode, 1)
        self.assertIn("INTEGRITY_VERIFY=FAIL", proc_tamper.stdout)

        proc_pub_tamper = run_tool([
            "publish",
            "--manifest-dir", str(out_dir),
            "--pubkey", spki_b64,
            "--dry-run",
        ])
        self.assertEqual(proc_pub_tamper.returncode, 1)
        self.assertIn("INTEGRITY_PUBLISH=FAIL", proc_pub_tamper.stdout)

        # Restore manifest.json, tamper with staged keybox.xml -> SHA-256 check must fail
        manifest_path.write_bytes(orig_bytes)
        staged_kb = out_dir / "keybox.xml"
        orig_kb = staged_kb.read_bytes()
        staged_kb.write_bytes(orig_kb + b"\n")
        proc_kb_tamper = run_tool([
            "verify-manifest",
            "--manifest-dir", str(out_dir),
            "--pubkey", spki_b64,
        ])
        self.assertEqual(proc_kb_tamper.returncode, 1)
        self.assertIn("SHA-256 mismatch for keybox.xml", proc_kb_tamper.stderr)
        staged_kb.write_bytes(orig_kb)

        # Verify build-manifest refuses to sign if a keybox hits the CRL
        bad_out = work / "dist_revoked"
        proc_bm_rev = run_tool([
            "build-manifest",
            "--out-dir", str(bad_out),
            "--key", str(priv_key),
            "--keybox", str(self.valid_keybox),
            "--roots-file", str(self.roots_json),
            "--crl-file", str(self.revoked_crl_json),
        ])
        self.assertEqual(proc_bm_rev.returncode, 2)
        self.assertIn("INTEGRITY_MANIFEST=FAIL", proc_bm_rev.stdout)
        self.assertFalse((bad_out / "manifest.json").exists())


if __name__ == "__main__":
    unittest.main()

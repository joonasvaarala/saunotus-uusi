"""Hetzner-lähetys: pakotettu upload-komento, ei avaimen vuotoa, ei scp/rsync."""
from __future__ import annotations

import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "backup" / "hetzner_upload.sh"
NAME_RE = re.compile(r"^[A-Za-z0-9._-]+\.age$")
KEY_MARKER = "SUPERSECRETKEYMATERIALLINE"
HOST_MARKER = "AAAASUPERSECRETHOSTKEYLINE"
PRIVATE_KEY = (
    "-----BEGIN OPENSSH PRIVATE KEY-----\n"
    f"{KEY_MARKER}\n"
    "-----END OPENSSH PRIVATE KEY-----\n"
)
KNOWN_HOSTS = f"backup.example.test ssh-ed25519 {HOST_MARKER}\n"


class HetznerUploadTest(unittest.TestCase):
    def test_script_has_no_scp_or_relaxed_hostcheck(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("scp ", text)
        self.assertNotIn("rsync", text)
        self.assertNotIn("StrictHostKeyChecking=no", text)
        self.assertNotIn("StrictHostKeyChecking=accept-new", text)
        self.assertIn("StrictHostKeyChecking=yes", text)
        self.assertIn("chmod 600", text)
        self.assertIn('upload ${remote}', text)

    def test_skips_cleanly_when_host_missing(self):
        for host in (None, "", "   "):
            with self.subTest(host=host):
                env = base_env()
                if host is None:
                    env.pop("BACKUP_SSH_HOST", None)
                else:
                    env["BACKUP_SSH_HOST"] = host
                result = run_script(env, ssh=fake_ssh_that_fails())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Hetzner ohitettu", result.stdout)
                self.assertIn("BACKUP_SSH_HOST puuttuu", result.stdout)
                self.assertEqual(list(Path(result.ssh_dir).glob("**/argv")), [])
                self.assertNotIn(KEY_MARKER, result.stdout + result.stderr)
                self.assertNotIn(HOST_MARKER, result.stdout + result.stderr)
                self.assertEqual(list(Path(result.tmpdir).glob("tapio-hetzner.*")), [])

    def test_uploads_each_age_file_with_unique_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            age = Path(tmp) / "age"
            age.mkdir()
            payloads = {
                "tapio-havuhattu_2026-10-22_0015.dump.tar.age": b"db-bytes",
                "tapio-havuhattu_2026-10-22_0015.storage.tar.age": b"storage-bytes-22",
            }
            for name, blob in payloads.items():
                (age / name).write_bytes(blob)
            capture = Path(tmp) / "ssh"
            capture.mkdir()
            env = base_env()
            env["BACKUP_AGE_DIR"] = str(age)
            env["TMPDIR"] = tmp
            env["GITHUB_RUN_ID"] = "4242"
            env["GITHUB_RUN_ATTEMPT"] = "3"
            result = run_script(env, ssh=write_fake_ssh(capture, mode="ok"), tmpdir=tmp)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = sorted(p for p in capture.iterdir() if p.is_dir())
            self.assertEqual(len(calls), 2)
            remotes = []
            for call in calls:
                argv = (call / "argv").read_text(encoding="utf-8").splitlines()
                self.assertIn("StrictHostKeyChecking=yes", argv)
                self.assertIn("UserKnownHostsFile=" + (call / "known_path").read_text(encoding="utf-8").strip(), [
                    item if item.startswith("UserKnownHostsFile=") else "" for item in argv
                ] or argv)
                joined = "\n".join(argv)
                self.assertIn("StrictHostKeyChecking=yes", joined)
                self.assertIn("GlobalKnownHostsFile=/dev/null", joined)
                self.assertIn("IdentitiesOnly=yes", joined)
                self.assertIn("BatchMode=yes", joined)
                self.assertIn("-T", argv)
                self.assertNotIn("scp", joined)
                remote_cmd = argv[-1]
                self.assertTrue(remote_cmd.startswith("upload "))
                remote = remote_cmd.split(" ", 1)[1]
                self.assertRegex(remote, NAME_RE)
                self.assertRegex(remote, r"\.\d{8}T\d{6}Z\.r4242\.a3\.age$")
                self.assertNotIn(" ", remote)
                remotes.append(remote)
                stdin = (call / "stdin").read_bytes()
                self.assertIn(stdin, payloads.values())
                stem = remote.split(".", 1)[0]
                # alkuperäinen nimi säilyy etänimen alussa
                self.assertTrue(
                    any(name.startswith(stem) or remote.startswith(name[: -len(".age")]) for name in payloads),
                    remote,
                )
                self.assertEqual((call / "key_mode").read_text(encoding="utf-8").strip(), "600")
                self.assertEqual((call / "key_match").read_text(encoding="utf-8").strip(), "yes")
                self.assertEqual((call / "known_match").read_text(encoding="utf-8").strip(), "yes")
                self.assertFalse((call / "env_leak").exists())
                key_path = Path((call / "key_path").read_text(encoding="utf-8").strip())
                self.assertFalse(key_path.exists())
            self.assertEqual(len(set(remotes)), 2)
            self.assertTrue(any(name.startswith("tapio-havuhattu_2026-10-22_0015.dump.tar.") for name in remotes))
            self.assertTrue(any(name.startswith("tapio-havuhattu_2026-10-22_0015.storage.tar.") for name in remotes))
            self.assertNotIn(KEY_MARKER, result.stdout + result.stderr)
            self.assertNotIn(HOST_MARKER, result.stdout + result.stderr)
            self.assertEqual(list(Path(tmp).glob("tapio-hetzner.*")), [])

    def test_bad_response_fails_and_deletes_key(self):
        result = self._one_file(mode="bad-response")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("vastaus ei täsmää", result.stderr)
        self.assertNotIn(KEY_MARKER, result.stdout + result.stderr)
        self.assertEqual(list(Path(result.tmpdir).glob("tapio-hetzner.*")), [])

    def test_ssh_failure_fails_job(self):
        result = self._one_file(mode="exit-255")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ssh epäonnistui (255)", result.stderr)
        self.assertEqual(list(Path(result.tmpdir).glob("tapio-hetzner.*")), [])

    def test_invalid_filename_is_rejected_before_ssh(self):
        with tempfile.TemporaryDirectory() as tmp:
            age = Path(tmp) / "age"
            age.mkdir()
            (age / "has space.age").write_bytes(b"x")
            capture = Path(tmp) / "ssh"
            capture.mkdir()
            env = base_env()
            env["BACKUP_AGE_DIR"] = str(age)
            env["TMPDIR"] = tmp
            result = run_script(env, ssh=write_fake_ssh(capture, mode="ok"), tmpdir=tmp)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("tiedostonimi ei kelpaa", result.stderr)
            self.assertEqual([p for p in capture.iterdir() if p.is_dir()], [])
            self.assertEqual(list(Path(tmp).glob("tapio-hetzner.*")), [])

    def test_missing_user_fails_without_writing_key(self):
        env = base_env()
        env.pop("BACKUP_SSH_USER")
        result = run_script(env, ssh=fake_ssh_that_fails())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BACKUP_SSH_USER puuttuu", result.stderr)
        self.assertEqual(list(Path(result.tmpdir).glob("tapio-hetzner.*")), [])
        self.assertNotIn(KEY_MARKER, result.stdout + result.stderr)

    def _one_file(self, mode: str):
        tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: subprocess.call(["rm", "-rf", tmp]))
        age = Path(tmp) / "age"
        age.mkdir()
        (age / "tapio-havuhattu_2026-10-22_0015.dump.tar.age").write_bytes(b"abc")
        capture = Path(tmp) / "ssh"
        capture.mkdir()
        env = base_env()
        env["BACKUP_AGE_DIR"] = str(age)
        env["TMPDIR"] = tmp
        return run_script(env, ssh=write_fake_ssh(capture, mode=mode), tmpdir=tmp)


def base_env() -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "BACKUP_SSH_HOST": "backup.example.test",
            "BACKUP_SSH_USER": "backup",
            "BACKUP_SSH_KEY": PRIVATE_KEY,
            "BACKUP_SSH_KNOWN_HOSTS": KNOWN_HOSTS,
            "GITHUB_RUN_ID": "99",
            "GITHUB_RUN_ATTEMPT": "1",
        }
    )
    return env


class Run:
    def __init__(self, completed: subprocess.CompletedProcess[str], tmpdir: str, ssh_dir: str):
        self.returncode = completed.returncode
        self.stdout = completed.stdout
        self.stderr = completed.stderr
        self.tmpdir = tmpdir
        self.ssh_dir = ssh_dir


def run_script(env: dict[str, str], ssh: Path, tmpdir: str | None = None) -> Run:
    own_tmp = tmpdir is None
    if own_tmp:
        tmpdir = tempfile.mkdtemp()
    assert tmpdir is not None
    env = dict(env)
    env["PATH"] = str(ssh.parent) + os.pathsep + env.get("PATH", "")
    env.setdefault("TMPDIR", tmpdir)
    env.setdefault("BACKUP_AGE_DIR", str(Path(tmpdir) / "missing-age"))
    completed = subprocess.run(
        ["bash", str(SCRIPT)],
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    return Run(completed, tmpdir, str(ssh.parent))


def fake_ssh_that_fails() -> Path:
    directory = Path(tempfile.mkdtemp())
    path = directory / "ssh"
    path.write_text("#!/bin/sh\necho fake-ssh-should-not-run >&2\nexit 99\n", encoding="utf-8")
    path.chmod(0o755)
    return path


def write_fake_ssh(capture: Path, mode: str) -> Path:
    directory = capture.parent / f"bin-{mode}"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "ssh"
    expected_key = directory / "expected-key"
    expected_known = directory / "expected-known"
    key_text = PRIVATE_KEY if PRIVATE_KEY.endswith("\n") else PRIVATE_KEY + "\n"
    known_text = KNOWN_HOSTS if KNOWN_HOSTS.endswith("\n") else KNOWN_HOSTS + "\n"
    expected_key.write_text(key_text, encoding="utf-8")
    expected_known.write_text(known_text, encoding="utf-8")
    expected_key.chmod(0o600)
    expected_known.chmod(0o600)
    script = textwrap.dedent(
        f"""\
        #!/bin/bash
        set -euo pipefail
        n=$(find {capture} -mindepth 1 -maxdepth 1 -type d | wc -l)
        dir={capture}/$n
        mkdir -p "$dir"
        printf '%s\\n' "$@" > "$dir/argv"
        cat > "$dir/stdin"
        key=""
        known=""
        prev=""
        for arg in "$@"; do
          case "$prev" in
            -i) key="$arg" ;;
          esac
          case "$arg" in
            UserKnownHostsFile=*) known="${{arg#UserKnownHostsFile=}}" ;;
          esac
          prev="$arg"
        done
        printf '%s\\n' "$key" > "$dir/key_path"
        printf '%s\\n' "$known" > "$dir/known_path"
        stat -c '%a' "$key" > "$dir/key_mode"
        if cmp -s "$key" {expected_key}; then echo yes > "$dir/key_match"; else echo no > "$dir/key_match"; fi
        if cmp -s "$known" {expected_known}; then echo yes > "$dir/known_match"; else echo no > "$dir/known_match"; fi
        if tr '\\0' '\\n' < /proc/self/environ | grep -q '{KEY_MARKER}'; then
          echo leak > "$dir/env_leak"
        fi
        if tr '\\0' '\\n' < /proc/self/environ | grep -q '{HOST_MARKER}'; then
          echo leak-host >> "$dir/env_leak"
        fi
        bytes=$(wc -c < "$dir/stdin" | tr -d '[:space:]')
        mode={mode}
        if [[ "$mode" == "exit-255" ]]; then
          echo fail >&2
          exit 255
        fi
        if [[ "$mode" == "bad-response" ]]; then
          echo "ei-ok"
          exit 0
        fi
        echo "ok $bytes"
        """
    )
    path.write_text(script, encoding="utf-8")
    path.chmod(0o755)
    return path


if __name__ == "__main__":
    unittest.main()

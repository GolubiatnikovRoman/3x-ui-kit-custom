"""Test CUSTOM sources and signed update verification without a VPS."""

import hashlib
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "scripts/3x-ui.sh"
KIT = (ROOT / "scripts/kit.sh").read_text()


def shell_function(source, name):
    return re.search(rf"^{name}\(\) \{{.*?^\}}", source, re.M | re.S).group()


class InstallSources(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.scripts = Path(tmp.name) / "KIT CUSTOM" / "scripts"
        shutil.copytree(INSTALLER.parent, self.scripts)
        self.installer = self.scripts / INSTALLER.name

    def run_installer(self, *args):
        return subprocess.run(
            ["bash", str(self.installer), *args], capture_output=True, text=True
        )

    def test_help(self):
        self.assertEqual(self.run_installer("--help").returncode, 0)

    def test_accepts_local_components(self):
        source = self.installer.read_text()
        script = self.scripts / "check-sources.sh"
        script.write_text(
            'set -eu\ndie() { echo "$*" >&2; exit 1; }\n'
            + shell_function(source, "check_kit_sources")
            + '\ncheck_kit_sources\nprintf "%s\\n" "$KIT_SCRIPTS_DIR"\n'
        )
        result = subprocess.run(
            ["bash", script], capture_output=True, text=True, cwd=self.scripts.parent
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.scripts.resolve()))

    def test_missing_local_component_stops_preflight(self):
        for name in ("kit.sh", "kit-sub.py"):
            with self.subTest(name=name):
                path = self.scripts / name
                original = path.read_bytes()
                path.unlink()
                result = self.run_installer()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("из того же коммита", result.stderr)
                path.write_bytes(original)

    def test_invalid_python_stops_preflight(self):
        (self.scripts / "kit-sub.py").write_text("def bad(:\n")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("не прошли проверку синтаксиса", result.stderr)


class Updates(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.temp = Path(tmp.name)
        self.release = self.temp / "release"
        (self.release / "scripts").mkdir(parents=True)
        self.download = self.temp / "download"
        self.download.mkdir()
        self.key = self.temp / "test-signing-key"

    def write_release(self, version):
        subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", self.key],
            check=True,
        )
        lines = [f"# 3X-UI KIT {version}"]
        for name in ("scripts/kit.sh", "scripts/kit-sub.py"):
            payload = (ROOT / name).read_bytes()
            (self.release / name).write_bytes(payload)
            lines.append(f"{hashlib.sha256(payload).hexdigest()}  {name}")
        manifest = self.release / "SHA256SUMS"
        manifest.write_text("\n".join(lines) + "\n")
        subprocess.run(
            ["ssh-keygen", "-Y", "sign", "-f", self.key, "-n", "3x-ui-kit-release", manifest],
            check=True,
            capture_output=True,
        )

    def verify(self, version, pubkey):
        config = re.search(
            r'^KIT_REPO_RAW=.*\nKIT_RAW=.*\n.*\nkit_ref_raw\(\).*\n', KIT, re.M
        ).group()
        config += "\n".join(
            re.search(rf"^{key}=.*", KIT, re.M).group()
            for key in ("KIT_SIG_NS", "KIT_SIG_ID")
        )
        script = config + "\n" + shell_function(KIT, "fetch_release") + """
warn() { echo "$*" >&2; }
curl() {
  local dest=${@: -2:1} url=${@: -1}
  local base="https://raw.githubusercontent.com/GolubiatnikovRoman/3x-ui-kit-custom/v$expected"
  [[ $url == "$base/"* ]] || return 1
  cp -- "$fixture/${url#"$base/"}" "$dest"
}
expected=$1
fixture=$2
KIT_SIGNERS=()
[[ -z $4 ]] || KIT_SIGNERS=("$4")
fetch_release "$1" "$3"
"""
        return subprocess.run(
            ["bash", "-eu", "-c", script, "test", version, self.release, self.download, pubkey],
            capture_output=True,
            text=True,
        )

    def test_without_trusted_key(self):
        result = self.verify("1.2.1", "")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("нет ключа подписи", result.stderr)
        self.assertFalse(list(self.download.iterdir()))

    def test_signed_release(self):
        self.write_release("1.2.1")
        result = self.verify("1.2.1", self.key.with_suffix(".pub").read_text().strip())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            (self.download / "kit-sub.py").read_bytes(),
            (self.release / "scripts/kit-sub.py").read_bytes(),
        )

    def test_tampered_payload(self):
        self.write_release("1.2.1")
        (self.release / "scripts/kit.sh").write_text("changed")
        result = self.verify("1.2.1", self.key.with_suffix(".pub").read_text().strip())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("не совпал с подписанным SHA256", result.stderr)

    def test_wrong_manifest_version(self):
        self.write_release("1.2.0")
        result = self.verify("1.2.1", self.key.with_suffix(".pub").read_text().strip())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Подписанный релиз не той версии", result.stderr)

    def test_invalid_signature(self):
        self.write_release("1.2.1")
        with (self.release / "SHA256SUMS").open("a") as manifest:
            manifest.write("# changed after signing\n")
        result = self.verify("1.2.1", self.key.with_suffix(".pub").read_text().strip())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Подпись релиза 1.2.1 не сошлась", result.stderr)

    def test_missing_signature(self):
        self.write_release("1.2.1")
        (self.release / "SHA256SUMS.sig").unlink()
        result = self.verify("1.2.1", self.key.with_suffix(".pub").read_text().strip())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Не удалось скачать подпись", result.stderr)


if __name__ == "__main__":
    unittest.main()

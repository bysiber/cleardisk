"""Exercise bundle preservation with fake macOS tools; runnable on Linux and macOS."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class StagingTests(unittest.TestCase):
    def check_staging(self, failure):
        script = Path(__file__).with_name("stage_sign_app.sh").resolve()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "ClearDisk.app"
            app.mkdir()
            (app / "original").write_text("preserve me")
            (app / "link").symlink_to("original")
            bin_dir = root / "bin"
            bin_dir.mkdir()
            mock = '''#!/usr/bin/env python3
import os, pathlib, shutil, sys
tool = pathlib.Path(sys.argv[0]).name
failure = os.environ.get("FAILURE", "")
target = sys.argv[-1]
if tool == "ditto":
    if failure == "copy-back" and ".cleardisk-replace." in target:
        pathlib.Path(target).mkdir()
        sys.exit(1)
    shutil.copytree(sys.argv[1], target, symlinks=True)
elif tool == "codesign":
    signing = "--force" in sys.argv
    if signing and failure == "sign": sys.exit(1)
    if not signing and failure == "verify-candidate" and ".cleardisk-replace." in target: sys.exit(1)
    if not signing and failure == "verify-final" and target == os.environ["APP"]: sys.exit(1)
    if signing: pathlib.Path(target, "signed").write_text("yes")
elif tool == "xattr" and failure == "xattr":
    sys.exit(1)
'''
            for tool in ["ditto", "codesign", "xattr"]:
                executable = bin_dir / tool
                executable.write_text(mock)
                executable.chmod(0o755)
            environment = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", FAILURE=failure, APP=str(app))
            result = subprocess.run(["bash", str(script), str(app)], env=environment,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, not failure, result.stderr)
            self.assertEqual((app / "original").read_text(), "preserve me")
            self.assertTrue((app / "link").is_symlink())
            self.assertEqual((app / "signed").exists(), not failure)
            self.assertEqual(list(root.glob(".cleardisk-*")), [])

    def test_success(self):
        self.check_staging("")

    def test_signing_failure_preserves_bundle(self):
        self.check_staging("sign")

    def test_xattr_failure_preserves_bundle(self):
        self.check_staging("xattr")

    def test_partial_copy_back_preserves_bundle(self):
        self.check_staging("copy-back")

    def test_candidate_verification_failure_preserves_bundle(self):
        self.check_staging("verify-candidate")

    def test_final_verification_failure_rolls_back(self):
        self.check_staging("verify-final")


if __name__ == "__main__":
    unittest.main()

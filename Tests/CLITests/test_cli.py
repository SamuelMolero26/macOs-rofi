import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ROFI = ROOT / ".build" / "debug" / "rofi"


class CLIContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not ROFI.is_file():
            raise RuntimeError(f"build the rofi executable before running {Path(__file__).name}")

    def run_rofi(self, argv0, *arguments, input=b""):
        return subprocess.run(
            [argv0, *arguments],
            executable=ROFI,
            input=input,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_exact_dmenu_basename_starts_dmenu_mode(self):
        result = self.run_rofi("bin/dmenu", "-dump")

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"")

    def test_other_basenames_do_not_start_dmenu_mode(self):
        for argv0 in ("bin/Dmenu", "rofi"):
            with self.subTest(argv0=argv0):
                result = self.run_rofi(argv0, "-dump")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr, b"rofi: not implemented yet\n")

    def test_invalid_matching_diagnoses_and_exits_dataerr(self):
        result = self.run_rofi("rofi", "-dmenu", "-dump", "-matching", "bogus,fuzzy,nope")

        self.assertEqual(result.returncode, 65)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(
            result.stderr,
            b"rofi: The configuration failed to validate:\n"
            b"\tconfig.matching=bogus is not a valid matching strategy.\n"
            b"Valid options are: glob, regex, fuzzy, prefix or normal.\n"
            b"\tconfig.matching=nope is not a valid matching strategy.\n"
            b"Valid options are: glob, regex, fuzzy, prefix or normal.\n"
            b"Please update your configuration.\n",
        )

    def test_too_many_matching_methods_diagnoses_and_exits_dataerr(self):
        value = "normal,regex,glob,fuzzy,prefix"
        result = self.run_rofi("rofi", "-dmenu", "-dump", "-matching", value)

        self.assertEqual(result.returncode, 65)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(
            result.stderr,
            b"rofi: The configuration failed to validate:\n"
            b"\tconfig.matching = " + value.encode() + b" to many matching options enabled.\n"
            b"Please update your configuration.\n",
        )

    def test_separator_preserves_a_non_utf8_argv_byte(self):
        result = self.run_rofi(
            b"rofi",
            b"-dmenu",
            b"-dump",
            b"-sep",
            b"\xff",
            b"-format",
            b"s",
            input=b"alpha\xffbeta",
        )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"alpha\nbeta\n")
        self.assertEqual(result.stderr, b"")

    def test_input_opens_the_raw_argument_bytes(self):
        # APFS refuses non-UTF-8 names, so prove the bytes reach open() by
        # planting the U+FFFD name a lossy decode of b"\xff" would open.
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "\ufffd").write_bytes(b"wrong\n")
            path = directory.encode() + b"/\xff"
            result = self.run_rofi(b"rofi", b"-dmenu", b"-dump", b"-input", path)

        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(
            result.stderr,
            b"rofi: Failed to open file: " + directory.encode()
            + b"/\xef\xbf\xbd: No such file or directory\n",
        )


if __name__ == "__main__":
    unittest.main()

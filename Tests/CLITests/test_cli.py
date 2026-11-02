import subprocess
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
        result = self.run_rofi("rofi", "-dmenu", "-dump", "-matching", "bogus")

        self.assertEqual(result.returncode, 65)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(
            result.stderr,
            b"rofi: config.matching=bogus is not a valid matching strategy.\n"
            b"Valid options are: glob, regex, fuzzy, prefix or normal.\n",
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


if __name__ == "__main__":
    unittest.main()

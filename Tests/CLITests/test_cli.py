import os
import pty
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
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertTrue(result.stderr.startswith(b"rofi: Rofi is unsure what to show.\n"))

    # source/rofi.c:564-595, 956-958: no -show explains itself and exits 0.
    def test_no_show_is_unsure_what_to_show_and_exits_zero(self):
        result = self.run_rofi("rofi", "-modes", "a:/bin/echo")

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(
            result.stderr,
            b"rofi: Rofi is unsure what to show.\n\n"
            b"Please specify the mode you want to show.\n\n"
            b"    rofi -show {mode}\n\n"
            b"The following modes are enabled:\n"
            b"    \xe2\x80\xa2 a\n"
            b"\nThe following modes can be enabled:\n"
            b"    \xe2\x80\xa2 drun\n"
            b"    \xe2\x80\xa2 filebrowser\n"
            b"\nTo activate a mode, add it to the list in the modes setting.\n",
        )

    # source/rofi.c:564-595: the built-in filebrowser is accepted in the mode
    # list and shown as enabled.
    def test_filebrowser_is_an_enabled_builtin_mode(self):
        result = self.run_rofi("rofi", "-modes", "filebrowser,a:/bin/echo")

        self.assertEqual(result.returncode, 0)
        self.assertIn(
            b"The following modes are enabled:\n    \xe2\x80\xa2 filebrowser\n    \xe2\x80\xa2 a\n",
            result.stderr,
        )

    # source/rofi.c:832-835, 840-857: an unknown name in the mode list.
    def test_unknown_mode_diagnoses_and_exits_dataerr(self):
        result = self.run_rofi("rofi", "-modes", "a:/bin/echo,nope", "-show", "a")

        self.assertEqual(result.returncode, 65)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(
            result.stderr,
            b"rofi: The following errors were detected when starting rofi:\n\n\n"
            b"Mode nope is not found.\nThe following modes are known:\n"
            b"        * drun\n"
            b"        * filebrowser\n"
            b"        * +a\n\n",
        )

    # source/rofi.c:946-950, 547-562, 732-739: built-in modes such as run do
    # not exist yet; the known list names the built-ins drun and filebrowser,
    # both enabled by default.
    def test_show_unimplemented_builtin_diagnoses_and_exits_dataerr(self):
        result = self.run_rofi("rofi", "-show", "run")

        self.assertEqual(result.returncode, 65)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(
            result.stderr,
            b"rofi: The following errors were detected when starting rofi:\n\n\n"
            b"Mode run is not found.\nThe following modes are known:\n"
            b"        * +drun\n"
            b"        * +filebrowser\n\n",
        )

    # source/rofi.c:564-595: with no mode list, drun and filebrowser are the
    # enabled defaults (upstream's window/run/ssh do not exist here).
    def test_drun_and_filebrowser_are_the_default_enabled_modes(self):
        result = self.run_rofi("rofi")

        self.assertEqual(result.returncode, 0)
        self.assertIn(
            b"The following modes are enabled:\n"
            b"    \xe2\x80\xa2 drun\n    \xe2\x80\xa2 filebrowser\n"
            b"\nThe following modes can be enabled:\n",
            result.stderr,
        )

    # source/rofi.c:869-888, source/helper.c:774-777: the matching error joins
    # the startup error dialog before -show is read.
    def test_show_with_invalid_matching_diagnoses_and_exits_dataerr(self):
        result = self.run_rofi("rofi", "-modes", "a:/bin/echo", "-show", "nope", "-matching", "bogus")

        self.assertEqual(result.returncode, 65)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(
            result.stderr,
            b"rofi: The following errors were detected when starting rofi:\n\n\n"
            b"The configuration failed to validate:\n"
            b"\tconfig.matching=bogus is not a valid matching strategy.\n"
            b"Valid options are: glob, regex, fuzzy, prefix or normal.\n"
            b"Please update your configuration.\n",
        )

    # source/rofi.c:533-545 warns only when stdout is a terminal; then a script
    # that cannot start shows its error instead of the view, and the return
    # code stays 0 (source/rofi.c:201-216, source/modes/script.c:242-246).
    def test_disabled_mode_warning_needs_a_terminal_and_failed_script_exits_zero(self):
        spec = "b:/nonexistent/script"
        failure = (
            b"rofi: Failed to execute: '/nonexistent/script'\n"
            b"Error: 'Failed to execute child process \xe2\x80\x9c/nonexistent/script\xe2\x80\x9d"
            b" (No such file or directory)'\n"
        )
        result = self.run_rofi("rofi", "-show", spec)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, failure)

        controller, terminal = pty.openpty()
        try:
            result = subprocess.run(
                ["rofi", "-show", spec],
                executable=ROFI,
                stdin=subprocess.DEVNULL,
                stdout=terminal,
                stderr=subprocess.PIPE,
                check=False,
            )
        finally:
            os.close(terminal)
            os.close(controller)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(result.stderr.startswith(b"Mode \x1b[0;31m" + spec.encode() + b"\x1b[0m is not enabled."))
        self.assertTrue(result.stderr.endswith(failure))

    # source/keyb.c:450-491, source/rofi.c:1271, 840-857: a binding that does
    # not parse joins the startup error dialog, for dmenu too.
    def test_invalid_key_binding_diagnoses_and_exits_dataerr(self):
        result = self.run_rofi("rofi", "-dmenu", "-dump", "-kb-custom-1", "Alt+bogus")

        self.assertEqual(result.returncode, 65)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(
            result.stderr,
            b"rofi: The following errors were detected when starting rofi:\n\n\n"
            b"Failed to set binding Alt+bogus for: Custom keybinding 1 (kb-custom-1):\n"
            b"\tUnknown key: bogus\n\n",
        )

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

    def test_dump_config(self):
        with tempfile.TemporaryDirectory() as home:
            environment = os.environ.copy()
            environment["HOME"] = home
            environment["XDG_CONFIG_HOME"] = str(Path(home) / "config")
            result = subprocess.run(
                [
                    "rofi",
                    "-dump-config",
                    "-theme-str",
                    "configuration { lines: 4; location: south; } "
                    "window { width: 640px; background-color: #112233; }",
                ],
                executable=ROFI,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(
            result.stdout,
            b"configuration {\n"
            b"    lines: 4;\n"
            b"    location: south;\n"
            b"}\n\n"
            b"window {\n"
            b"    background-color: rgba(17, 34, 51, 1);\n"
            b"    width: 640px;\n"
            b"}\n",
        )
        self.assertEqual(result.stderr, b"")

    # ADR 0001 §2: -dump-config resolves the same sources as a real run, and
    # its warnings, including panel-style ones, still go to stderr.
    def test_dump_config_reports_style_warnings(self):
        with tempfile.TemporaryDirectory() as home:
            environment = os.environ.copy()
            environment["HOME"] = home
            environment["XDG_CONFIG_HOME"] = str(Path(home) / "config")
            result = subprocess.run(
                [
                    "rofi",
                    "-dump-config",
                    "-theme-str",
                    'window { font: "No Such Family Anywhere 12"; }',
                ],
                executable=ROFI,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )

        self.assertEqual(result.returncode, 0)
        self.assertIn(b"window {", result.stdout)
        self.assertEqual(
            result.stderr,
            b"rofi: warning: <theme-str:1>:1:10: font 'No Such Family Anywhere 12' "
            b"is not available; the built-in font is kept\n",
        )

    # ADR 0001 §3-4: the panel style is built before dmenu runs, and a theme
    # value with no native effect warns instead of failing.
    def test_unavailable_theme_font_warns_and_dmenu_still_runs(self):
        with tempfile.TemporaryDirectory() as home:
            environment = os.environ.copy()
            environment["HOME"] = home
            environment["XDG_CONFIG_HOME"] = str(Path(home) / "config")
            result = subprocess.run(
                [
                    "rofi",
                    "-dmenu",
                    "-dump",
                    "-theme-str",
                    'window { font: "No Such Family Anywhere 12"; }',
                ],
                executable=ROFI,
                input=b"a\n",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"a\n")
        self.assertEqual(
            result.stderr,
            b"rofi: warning: <theme-str:1>:1:10: font 'No Such Family Anywhere 12' "
            b"is not available; the built-in font is kept\n",
        )


if __name__ == "__main__":
    unittest.main()

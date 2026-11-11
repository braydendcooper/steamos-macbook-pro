# SPDX-License-Identifier: MIT
import ast
import logging
from pathlib import Path
import subprocess
import unittest
from unittest.mock import Mock, mock_open, patch


class ErrorLogWarningTests(unittest.TestCase):
    def test_both_error_handlers_include_privacy_warning(self):
        source = Path(__file__).resolve().parents[1] / "src/main.py"
        tree = ast.parse(source.read_text())
        # Run the entry point in isolation from platform-specific imports and setup.
        entry_point = tree.body[-1]
        self.assertIsInstance(entry_point, ast.If)
        code = compile(ast.Module(body=entry_point.body, type_ignores=[]), str(source), "exec")
        for error in (RuntimeError("test failure"),
                      subprocess.CalledProcessError(1, ["test-command"])):
            with self.subTest(error=type(error).__name__):
                warning = Mock()
                installer = Mock()
                installer.return_value.main.side_effect = error
                namespace = {
                    "logging": Mock(spec=logging),
                    "os": Mock(),
                    "shlex": Mock(),
                    "subprocess": subprocess,
                    "InstallerMain": installer,
                    "p_error": Mock(),
                    "p_warning": warning,
                }
                namespace["os"].getcwd.return_value = "/installer"
                with patch("builtins.open", mock_open(read_data="test-version")):
                    exec(code, namespace)
                self.assertEqual([call.args[0] for call in warning.call_args_list], [
                    "If you need to file a bug report, please attach the log file:",
                    "  /installer/installer.log",
                    "The log contains your Mac account names and disk identifiers; "
                    "remove those before sharing it publicly.",
                ])


if __name__ == "__main__":
    unittest.main()

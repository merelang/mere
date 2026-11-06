#!/usr/bin/env python3
"""Check mirror changes without touching the host's package configuration."""
from pathlib import Path
import tempfile
import unittest

from ci_apt_setup import configure


class AptSetupTest(unittest.TestCase):
    def test_legacy_and_deb822_sources_preserve_repository_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = root / "sources.list.d"
            sources.mkdir()
            legacy = root / "sources.list"
            legacy.write_text(
                "deb [arch=amd64 signed-by=/keyring.gpg] "
                "http://azure.archive.ubuntu.com/ubuntu/ noble main universe\n")
            modern = sources / "ubuntu.sources"
            modern.write_text(
                "Types: deb\nURIs: https://azure.archive.ubuntu.com/ubuntu\n"
                "Suites: noble noble-updates\nComponents: main universe\n"
                "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n")
            other = sources / "custom.list"
            untouched = (
                "deb https://packages.example.org/ubuntu noble main\n"
                "deb http://security.ubuntu.com/ubuntu noble-security main\n"
                "deb https://azure.archive.ubuntu.com/ubuntu-custom noble main\n")
            other.write_text(untouched)
            self.assertEqual(configure(root), 2)
            self.assertEqual(legacy.read_text(),
                "deb [arch=amd64 signed-by=/keyring.gpg] "
                "https://archive.ubuntu.com/ubuntu/ noble main universe\n")
            self.assertEqual(modern.read_text(),
                "Types: deb\nURIs: https://archive.ubuntu.com/ubuntu\n"
                "Suites: noble noble-updates\nComponents: main universe\n"
                "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n")
            self.assertEqual(other.read_text(), untouched)
            self.assertEqual(configure(root), 0)
            config = (root / "apt.conf.d/80mere-downloads").read_text()
            self.assertIn('Acquire::Retries "2";', config)
            self.assertIn('Acquire::http::Timeout "30";', config)
            self.assertIn('Acquire::https::Timeout "30";', config)

    def test_empty_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(configure(Path(directory)), 0)
            self.assertTrue((Path(directory) / "apt.conf.d/80mere-downloads").is_file())

    def test_missing_directory_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                configure(Path(directory) / "missing")


if __name__ == "__main__":
    unittest.main()

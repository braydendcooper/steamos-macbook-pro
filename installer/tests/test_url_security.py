# SPDX-License-Identifier: MIT
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock, mock_open, patch

from osinstall import OSInstaller
from urlcache import URLCache


class RedirectSecurityTests(unittest.TestCase):
    def redirect(self, source, target, error=None):
        response = Mock()
        response.getheader.side_effect = lambda name, default=None: {
            "Location": target,
        }.get(name, default)
        final_response = Mock()
        final_response.getheader.side_effect = lambda name, default=None: {
            "Content-length": "123",
        }.get(name, default)
        connection = Mock()
        connection.getresponse.side_effect = [response, final_response]
        # Mock both transports so a regression cannot make a network request.
        with patch.dict(os.environ, {}, clear=True), \
                patch("urlcache.HTTPConnection", return_value=connection) as http, \
                patch("urlcache.HTTPSConnection", return_value=connection) as https:
            if error:
                with self.assertRaisesRegex(ValueError, error):
                    URLCache(source)
                self.assertEqual(http.call_count + https.call_count, 1)
            else:
                cache = URLCache(source)
                self.assertEqual(cache.url.geturl(), target)
                self.assertEqual(cache.size, 123)
                self.assertEqual(http.call_count + https.call_count, 2)

    def test_refuses_https_downgrade(self):
        self.redirect("https://example.com/pkg", "http://example.com/pkg",
                      "HTTPS to HTTP")

    def test_refuses_http_redirect_to_different_host(self):
        self.redirect("http://example.com/pkg", "http://other.example/pkg",
                      "different host")

    def test_allows_redirects_to_https(self):
        for scheme in ("http", "https"):
            with self.subTest(scheme=scheme):
                self.redirect(f"{scheme}://example.com/pkg", "https://other.example/pkg")

    def test_allows_http_redirect_on_same_host(self):
        self.redirect("http://EXAMPLE.com/pkg", "http://example.com:8080/new-pkg")


class MetadataURLSecurityTests(unittest.TestCase):
    def make_installer(self, **metadata):
        return OSInstaller(Mock(), {}, {
            "default_os_name": "Test OS", "partitions": [], **metadata,
        })

    def test_rejects_insecure_absolute_package_urls(self):
        for url in ("http://example.com/pkg.zip", "ftp://example.com/pkg.zip",
                    "file:///tmp/pkg.zip", "//example.com/pkg.zip"):
            with self.subTest(url=url), patch("osinstall.urlcache.URLCache") as cache, \
                    patch("osinstall.zipfile.ZipFile") as archive:
                with self.assertRaisesRegex(ValueError, "OS package URL must start with https://"):
                    self.make_installer(package=url).load_package()
                cache.assert_not_called()
                archive.assert_not_called()

    def test_allows_absolute_https_package_url(self):
        url = "https://example.com/pkg.zip"
        with patch("osinstall.urlcache.URLCache") as cache, \
                patch("osinstall.zipfile.ZipFile") as archive, \
                redirect_stdout(io.StringIO()):
            self.make_installer(package=url).load_package()
            cache.assert_called_once_with(url)
            archive.assert_called_once_with(cache.return_value)

    def test_relative_package_keeps_repo_base_behavior(self):
        for repo in ("http://repo.example", "https://repo.example"):
            with self.subTest(repo=repo), patch.dict(os.environ, {"REPO_BASE": repo}), \
                    patch("osinstall.urlcache.URLCache") as cache, \
                    patch("osinstall.zipfile.ZipFile"), redirect_stdout(io.StringIO()):
                self.make_installer(package="pkg.zip").load_package()
                cache.assert_called_once_with(repo + "/os/pkg.zip")

    def test_relative_package_keeps_local_default(self):
        with patch.dict(os.environ, {}, clear=True), \
                patch("builtins.open", mock_open()) as opened, \
                patch("osinstall.zipfile.ZipFile") as archive, \
                patch("osinstall.urlcache.URLCache") as cache, \
                redirect_stdout(io.StringIO()):
            self.make_installer(package="pkg.zip").load_package()
            opened.assert_called_once_with("./os/pkg.zip", "rb")
            archive.assert_called_once_with(opened.return_value)
            cache.assert_not_called()

    def test_extras_require_https_for_absolute_urls(self):
        for url in ("http://example.com/extra", "ftp://example.com/extra",
                    "file:///tmp/extra", "//example.com/extra", "https://example.com/extra"):
            with self.subTest(url=url), tempfile.TemporaryDirectory() as directory, \
                    patch("osinstall.urlcache.URLCache") as cache, \
                    redirect_stdout(io.StringIO()):
                installer = self.make_installer(extras=[url])
                installer.efi_part = SimpleNamespace(name="disk0s1")
                installer.dutil.mount.return_value = directory
                cache.return_value.read.return_value = b"extra contents"
                if url.startswith("https://"):
                    installer.download_extras()
                    cache.assert_called_once_with(url)
                    self.assertEqual(
                        (Path(directory) / "gravity/extras/extra").read_bytes(),
                        b"extra contents",
                    )
                else:
                    with self.assertRaisesRegex(ValueError, "extras URL must start with https://"):
                        installer.download_extras()
                    cache.assert_not_called()
                    self.assertEqual(list((Path(directory) / "gravity/extras").iterdir()), [])


if __name__ == "__main__":
    unittest.main()

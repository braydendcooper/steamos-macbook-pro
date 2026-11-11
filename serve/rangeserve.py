#!/usr/bin/env python3
# Static file server with HTTP Range support, for the installer's urlcache
# (it fetches OS packages in 1 MiB ranges; http.server ignores Range and would
# send the whole multi-GB package for every request).
#
# usage: rangeserve.py <directory> <bind address> <port>
import http.server
import os
import re
import sys
from functools import partial


class RangeHandler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # keep-alive, as urlcache expects

    def send_head(self):
        path = self.translate_path(self.path.split("?", 1)[0])
        if os.path.isdir(path) or "Range" not in self.headers:
            return super().send_head()
        m = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers["Range"].strip())
        try:
            f = open(path, "rb")
        except OSError:
            self.send_error(404, "File not found")
            return None
        size = os.fstat(f.fileno()).st_size
        start = int(m.group(1)) if m else size
        end = min(int(m.group(2)) if m and m.group(2) else size - 1, size - 1)
        if not m or start >= size or start > end:
            f.close()
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        f.seek(start)
        self.range_left = end - start + 1
        return f

    def copyfile(self, source, outputfile):
        left = getattr(self, "range_left", None)
        if left is None:
            return super().copyfile(source, outputfile)
        self.range_left = None
        while left > 0:
            chunk = source.read(min(left, 1 << 20))
            if not chunk:
                break
            outputfile.write(chunk)
            left -= len(chunk)


if __name__ == "__main__":
    directory, addr, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
    handler = partial(RangeHandler, directory=directory)
    http.server.ThreadingHTTPServer((addr, port), handler).serve_forever()

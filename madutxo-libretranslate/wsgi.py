import os
import sys

from libretranslate import main


def _int_env(name, default):
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


_BODY_LIMITS = {
    "/translate": _int_env("LT_MAX_CONTENT_LENGTH", 2000000),
    "/translate_file": _int_env("LT_MAX_CONTENT_LENGTH_FILE", 67108864),
    "/detect": 65536,
    "/suggest": 65536,
}
_DEFAULT_BODY_LIMIT = 1048576
_CORS_ORIGINS = {
    origin.strip()
    for origin in os.environ.get("LT_CORS_ORIGINS", "").split(",")
    if origin.strip()
}


class _TooLarge(Exception):
    pass


class _LimitedInput:
    def __init__(self, stream, limit):
        self.stream = stream
        self.limit = limit
        self.count = 0

    def _count(self, size):
        if self.count + size > self.limit:
            raise _TooLarge()
        self.count += size

    def read(self, size=-1):
        if size is None or size < 0:
            chunks = []
            while True:
                chunk = self.stream.read(65536)
                if not chunk:
                    break
                self._count(len(chunk))
                chunks.append(chunk)
            return b"".join(chunks)
        data = self.stream.read(size)
        self._count(len(data))
        return data

    def readline(self, size=-1):
        if size is None:
            size = -1
        data = self.stream.readline(size)
        self._count(len(data))
        return data

    def readlines(self, hint=-1):
        lines = []
        total = 0
        for line in self:
            lines.append(line)
            total += len(line)
            if hint is not None and hint > 0 and total >= hint:
                break
        return lines

    def readinto(self, buffer):
        data = self.read(len(buffer))
        size = len(data)
        buffer[:size] = data
        return size

    def __iter__(self):
        return self

    def __next__(self):
        line = self.readline()
        if not line:
            raise StopIteration
        return line

    def close(self):
        return self.stream.close()


def _drain(stream, length):
    remaining = length
    while remaining > 0:
        chunk = stream.read(min(65536, remaining))
        if not chunk:
            break
        remaining -= len(chunk)


def _error(start_response, status, message):
    body = ('{"error": "%s"}' % message).encode("utf-8")
    start_response(
        status,
        [
            ("Content-Type", "application/json"),
            ("Content-Length", str(len(body))),
        ],
    )
    return [body]


class _Guard:
    def __init__(self, app):
        self.app = app

    def __call__(self, environ, start_response):
        path = environ.get("PATH_INFO", "")
        method = environ.get("REQUEST_METHOD", "GET").upper()
        limit = _BODY_LIMITS.get(path, _DEFAULT_BODY_LIMIT)

        if method in ("POST", "PUT", "PATCH"):
            raw_length = environ.get("CONTENT_LENGTH", "")
            if raw_length is None or raw_length == "":
                return _error(
                    start_response, "411 Length Required", "Content-Length required"
                )
            try:
                length = int(raw_length)
            except (TypeError, ValueError):
                return _error(
                    start_response, "400 Bad Request", "Invalid Content-Length"
                )
            if length < 0:
                return _error(
                    start_response, "400 Bad Request", "Invalid Content-Length"
                )
            if length > limit:
                try:
                    _drain(environ["wsgi.input"], length)
                except Exception:
                    pass
                return _error(
                    start_response, "413 Request Entity Too Large", "Request too large"
                )
            environ["wsgi.input"] = _LimitedInput(environ["wsgi.input"], limit)

        started = []

        def guarded_start_response(status, headers, exc_info=None):
            if _CORS_ORIGINS:
                origin = environ.get("HTTP_ORIGIN", "")
                if origin in _CORS_ORIGINS:
                    headers = [
                        (name, origin)
                        if name.lower() == "access-control-allow-origin"
                        else (name, value)
                        for name, value in headers
                    ]
                else:
                    headers = [
                        (name, value)
                        for name, value in headers
                        if not name.lower().startswith("access-control-")
                    ]
            else:
                headers = [
                    (name, value)
                    for name, value in headers
                    if not name.lower().startswith("access-control-")
                ]
            started.append(True)
            return start_response(status, headers, exc_info)

        try:
            return self.app(environ, guarded_start_response)
        except _TooLarge:
            if started:
                raise
            return _error(
                start_response, "413 Request Entity Too Large", "Request too large"
            )


def app(*args, **kwargs):
    sys.argv = ["--wsgi"]

    for key in kwargs:
        cli_key = key.replace("_", "-")
        if isinstance(kwargs[key], bool):
            if kwargs[key]:
                sys.argv.append("--" + cli_key)
        else:
            sys.argv.append("--" + cli_key)
            sys.argv.append(kwargs[key])

    return _Guard(main())

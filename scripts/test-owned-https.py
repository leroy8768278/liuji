#!/usr/bin/env python3
"""Loopback TLS integration test for macOS 15+. Uses a temporary CA scoped to the test process."""
import http.server
import os
from pathlib import Path
import select
import socket
import ssl
import subprocess
import tempfile
import threading
import time

PROJECT = Path(__file__).resolve().parents[1]


def openssl(*args):
    subprocess.run(["/usr/bin/openssl", *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def make_certificates():
    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.crt",
            "-days", "2", "-subj", "/CN=Liuji Disposable Test CA")
    Path("ext").write_text("subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n")
    for name in ["leaf", "other"]:
        openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", f"{name}.key",
                "-out", f"{name}.csr", "-subj", "/CN=localhost")
        openssl("x509", "-req", "-in", f"{name}.csr", "-CA", "ca.crt", "-CAkey", "ca.key", "-CAcreateserial",
                "-out", f"{name}.crt", "-days", "1", "-extfile", "ext")
        openssl("pkcs12", "-export", "-inkey", f"{name}.key", "-in", f"{name}.crt", "-certfile", "ca.crt",
                "-out", f"{name}.p12", "-passout", "pass:fixture")
    openssl("x509", "-in", "ca.crt", "-outform", "der", "-out", "ca.der")


def build_probe():
    files = []
    for source in sorted((PROJECT / "Sources/PacketScope").glob("*.swift")):
        if source.name == "PacketScopeApp.swift":
            text = source.read_text().replace("@main\n", "", 1)
        elif source.name == "OwnedHTTPSSettings.swift":
            # Avoid editing the Mac trust store. Only this one invocation of SecTrust
            # receives the throw-away CA; the original hostname and leaf checks still run.
            marker = "let trust = sec_trust_copy_ref(securityTrust).takeRetainedValue()"
            code = source.read_text()
            assert code.count(marker) == 1
            text = code.replace(marker, marker + """
            if CommandLine.arguments.contains("--test-anchor") {
                let der = try! Data(contentsOf: URL(fileURLWithPath: "ca.der"))
                let anchor = SecCertificateCreateWithData(nil, der as CFData)!
                precondition(SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess)
                precondition(SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess)
            }
            """)
        else:
            files.append(str(source))
            continue
        Path(source.name).write_text(text)
        files.append(source.name)
    subprocess.run(["swiftc", "-parse-as-library", *files, str(PROJECT / "Tests/Fixtures/OwnedHTTPSProbe.swift"),
                    "-o", "fixture"], check=True)


class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.received.append((self.path, self.headers.get("X-Debug-Phase")))
        self.send_response(200)
        self.send_header("Content-Length", "12")
        self.end_headers()
        self.wfile.write(b"owned-origin")

    def log_message(self, *_):
        pass


def read_headers(sock):
    header = b""
    while b"\r\n\r\n" not in header:
        chunk = sock.recv(1024)
        if not chunk:
            break
        header += chunk
    return header


def check(origin, case):
    port = origin.server_port
    domain = "wrong.invalid" if case == "wrong SAN" else "localhost"
    p12 = "other.p12" if case == "different leaf" else "leaf.p12"
    args = ["./fixture", str(port), domain, p12]
    if case != "untrusted":
        args.append("--test-anchor")
    with subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True) as app:
        try:
            assert select.select([app.stdout], [], [], 10)[0], "fixture failed to start"
            first = app.stdout.readline().strip()
            if case == "wrong SAN":
                assert first.startswith("CONFIG_ERROR ") and app.wait(timeout=5) == 2
                return
            assert first.startswith("PORT "), first
            initial = len(origin.received)
            authority = f"localhost:{port}"
            with socket.create_connection(("127.0.0.1", int(first.split()[1])), timeout=6) as plain:
                plain.sendall(f"CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n\r\n".encode())
                status = read_headers(plain).splitlines()[0]
                if case in ["different leaf", "untrusted"]:
                    assert b" 502 " in status and len(origin.received) == initial
                    return
                assert b" 200 " in status, status
                client = ssl.create_default_context(cafile="ca.crt")
                client.set_alpn_protocols(["http/1.1"])
                with client.wrap_socket(plain, server_hostname=domain) as tls:
                    host = "other.invalid" if case == "wrong Host" else authority
                    target = "https://other.invalid/escape" if case == "absolute URI" else "/owned-check"
                    tls.sendall(f"GET {target} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
                    response = tls.makefile("rb").read()
            if case in ["wrong Host", "absolute URI"]:
                assert b" 400 " in response.splitlines()[0] and len(origin.received) == initial
            else:
                assert b" 200 " in response.splitlines()[0] and response.endswith(b"owned-origin")
                assert b"X-Debug-Phase: response" in response and origin.received[initial:] == [("/owned-check", "request")]
                expected = f"FINISHED GET https://localhost:{port}/owned-check 200 owned-origin"
                output = b""
                deadline = time.monotonic() + 5
                while expected.encode() not in output:
                    timeout = max(0, deadline - time.monotonic())
                    assert select.select([app.stdout], [], [], timeout)[0], output
                    chunk = os.read(app.stdout.fileno(), 8192)
                    assert chunk, output
                    output += chunk
        finally:
            if app.poll() is None:
                app.terminate()


def run():
    make_certificates()
    build_probe()
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Origin) as server:
        server.received = []
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain("leaf.crt", "leaf.key")
        ctx.set_alpn_protocols(["http/1.1"])
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            for case in ["wrong SAN", "untrusted", "different leaf", "verified HTTPS", "wrong Host", "absolute URI"]:
                check(server, case)
                print("PASS", case, flush=True)
        finally:
            server.shutdown()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="liuji-tls-") as directory:
        previous = os.getcwd()
        os.chdir(directory)
        try:
            run()
        finally:
            os.chdir(previous)

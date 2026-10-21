"""Probe unchanged Nginx with unsuppressed UBSan before assigning blame."""
from pathlib import Path
import os, socket, subprocess, sys, time

binary = Path(sys.argv[1]).resolve()
root = Path(sys.argv[2]).resolve()
root.mkdir(parents=True, exist_ok=True)
(root / "logs").mkdir(exist_ok=True)
(root / "nginx.conf").write_text("""daemon off;
master_process off;
error_log stderr notice;
pid nginx.pid;
events {}
http {
    access_log off;
    server {
        listen 127.0.0.1:18080;
        http2 on;
    }
}
""")
logfile = root / "baseline-ubsan.log"
with logfile.open("wb") as log:
    process = subprocess.Popen([str(binary), "-p", str(root) + "/", "-c", "nginx.conf", "-e", "stderr"],
                               stdout=log, stderr=log)
    try:
        for _ in range(100):
            try:
                connection = socket.create_connection(("127.0.0.1", 18080), timeout=1)
                break
            except OSError:
                if process.poll() is not None:
                    raise AssertionError("Server exited before protocol probe")
                time.sleep(0.05)
        else:
            raise AssertionError("Server did not listen")
        with connection:
            connection.sendall(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + bytes.fromhex("000000040000000000"))
            try:
                connection.recv(1024)
            except OSError:
                pass
        status = process.wait(timeout=10)
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
text = logfile.read_text(errors="replace")
assert status != 0, (status, text)
assert "runtime error:" in text and "misaligned" in text, text
assert "src/http/v2/ngx_http_v2.c" in text, text
print("Unchanged upstream reproduces an unsuppressed misaligned-access UBSan failure.")
print(text)

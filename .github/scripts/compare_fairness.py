#!/usr/bin/env python3
"""Same-runner, immutable-input comparison; baseline test failures are evidence."""
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tarfile

BASE = "148c75678cd4171338c31d4ed4c02411736d5fe9"
VARIANTS = ("stock", "fifo", "incremental", "final", "without-posted-barrier")
TESTS = ("h2_fair_scheduling.t", "h2_fair_scheduling_proxy.t")
COMPARATOR = "    return s->node->id <= stream->node->id;"
BARRIER = "(fc->write->posted || stream->queued)"


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"Expected exactly one occurrence: {old!r}; got {text.count(old)}")
    return text.replace(old, new, 1)


def source_mutation(variant, text):
    if variant == "fifo":
        return replace_once(text, COMPARATOR, "    return 1;")
    if variant == "incremental":
        return replace_once(text, COMPARATOR,
                            "    return a->incremental || s->node->id <= stream->node->id;")
    if variant == "without-posted-barrier":
        return replace_once(text, BARRIER, "stream->queued")
    return text


def private_test(text, filename, baseline):
    if baseline:
        expected = 3 if filename == TESTS[0] else 1
        text, count = re.subn(r"^[ \t]*http2_fair_scheduling (?:on|off);\n", "", text,
                             flags=re.M)
        if count != expected:
            raise ValueError(f"Unexpected literal directive count in {filename}: {count}")
    if filename == TESTS[0]:
        anchor = "\tmy @bytes = sort { $a <=> $b } map { $bytes{$_} || 0 } @$ids;"
        diagnostic = '\n\tdiag "FAIRNESS_BYTES static label=$name budget=$budget bytes=" . join(\',\', @bytes);'
    else:
        anchor = "\tmy @bytes = sort { $a <=> $b } map { $bytes{$_} || 0 } @ids;"
        diagnostic = '\n\tdiag "FAIRNESS_BYTES proxy label=$kind budget=196608 bytes=" . join(\',\', @bytes);'
    return replace_once(text, anchor, anchor + diagnostic)


def mutant_killed(text):
    return bool(re.search(r"^not ok (?:4|10) - (?:length|chunked) "
                          r"synchronous producer bounded service\s*$", text, re.M))


def run(argv, log, cwd=None, env=None, timeout=600):
    with log.open("wb") as output:
        output.write(("COMMAND: " + json.dumps(argv) + "\n").encode())
        output.flush()
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Kill only this command's private process group, including test daemons.
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            output.write(b"\nCOMPARISON COMMAND TIMED OUT\n")
            return 124


def checked(argv, log, cwd=None):
    status = run(argv, log, cwd=cwd)
    if status:
        raise RuntimeError(f"Command failed ({status}); see {log}: {argv}")


def git_output(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args])


def archive(repo, sha, destination):
    destination.mkdir(parents=True)
    archive_path = destination.with_suffix(".tar")
    with archive_path.open("wb") as output:
        subprocess.run(["git", "-C", str(repo), "archive", sha], stdout=output, check=True)
    with tarfile.open(archive_path) as source:
        source.extractall(destination, filter="data")
    archive_path.unlink()


def write_change(old, new, filename, output):
    output.write_text("".join(difflib.unified_diff(
        old.splitlines(True), new.splitlines(True), "a/" + filename, "b/" + filename)))


def main():
    root = Path.cwd()
    results = root / "comparison-results"
    results.mkdir()
    script_dir = Path(__file__).resolve().parent
    checked(["python3", "-B", str(script_dir / "test_compare_fairness.py"), "-v"],
            results / "transform-unit-tests.log")
    source_sha, tests_sha = os.environ["SOURCE_SHA"], os.environ["TESTS_SHA"]
    for sha in (source_sha, tests_sha):
        if not re.fullmatch("[0-9a-f]{40}", sha):
            raise ValueError("Candidate SHAs must be immutable full hexadecimal hashes")
    source, tests = root / "nginx", root / "tests"
    assert git_output(source, "rev-parse", "HEAD").decode().strip() == source_sha
    assert git_output(tests, "rev-parse", "HEAD").decode().strip() == tests_sha
    subprocess.run(["git", "-C", str(source), "merge-base", "--is-ancestor", BASE,
                    source_sha], check=True)
    (results / "source-candidate.patch").write_bytes(git_output(source, "diff", "--binary",
                                                                BASE, source_sha))
    metadata = {"base": BASE, "source_candidate": source_sha,
                "tests_candidate": tests_sha,
                "ci_commit": git_output(root / "ci", "rev-parse", "HEAD").decode().strip(),
                "variants": {}}
    (results / "inputs.json").write_text(json.dumps(metadata, indent=2) + "\n")
    checked(["sh", "-c", "uname -a; gcc --version; openssl version -a; perl -V; "
             "dpkg-query -W libpcre2-dev libssl-dev zlib1g-dev"], results / "environment.txt")
    work = root / "comparison-work"
    work.mkdir()
    final_ok = True
    killed = False
    for variant in VARIANTS:
        out = results / variant
        out.mkdir()
        variant_root = work / variant
        source_tree, test_tree = variant_root / "nginx", variant_root / "tests"
        sha = source_sha if variant in ("final", "without-posted-barrier") else BASE
        archive(source, sha, source_tree)
        archive(tests, tests_sha, test_tree)
        relative = ("src/http/v2/ngx_http_v2_filter_module.c" if
                    variant == "without-posted-barrier" else "src/http/v2/ngx_http_v2.h")
        target = source_tree / relative
        before = target.read_text()
        after = source_mutation(variant, before)
        target.write_text(after)
        write_change(before, after, relative, out / "source-mutation.patch")
        baseline = variant in ("stock", "fifo", "incremental")
        hashes = {}
        for filename in TESTS:
            target = test_tree / filename
            before = target.read_text()
            after = private_test(before, filename, baseline)
            target.write_text(after)
            write_change(before, after, filename, out / (filename + ".private.patch"))
            hashes[filename] = {"original_sha256": hashlib.sha256(before.encode()).hexdigest(),
                                "private_sha256": hashlib.sha256(after.encode()).hexdigest()}
        (out / "test-copy-hashes.json").write_text(json.dumps(hashes, indent=2) + "\n")
        checked(["auto/configure", "--with-cc=gcc", "--with-http_v2_module",
                 "--with-http_ssl_module", "--with-http_realip_module",
                 "--with-http_auth_request_module", "--with-debug"],
                out / "configure.log", cwd=source_tree)
        checked(["make", "-j2"], out / "build.log", cwd=source_tree)
        binary = source_tree / "objs/nginx"
        checked([str(binary), "-V"], out / "nginx-version.txt")
        environment = dict(os.environ, TEST_NGINX_BINARY=str(binary), LC_ALL="C")
        row = {"source_archive_sha": sha, "tests": {}, "credit_diagnostics": []}
        for filename in TESTS:
            log = out / (filename + ".log")
            status = run(["prove", "-v", filename], log, cwd=test_tree, env=environment,
                         timeout=240)
            text = log.read_text(errors="replace")
            row["tests"][filename] = {"command": ["prove", "-v", filename],
                                      "exit_code": status}
            row["credit_diagnostics"].extend(re.findall(r"^# FAIRNESS_BYTES .*", text, re.M))
            if variant == "final" and (status != 0 or "Result: PASS" not in text):
                final_ok = False
            if variant == "without-posted-barrier" and filename == TESTS[1]:
                killed = status != 0 and mutant_killed(text)
        if os.environ.get("RUN_SOCKET") == "true" and variant in ("stock", "fifo", "final"):
            fixture = script_dir / "comparison_socket_backpressure.t"
            before = fixture.read_text()
            after = before
            if baseline:
                after = replace_once(after, "        http2_fair_scheduling FAIR_MODE;\n", "")
            private_fixture = test_tree / fixture.name
            private_fixture.write_text(after)
            write_change(before, after, fixture.name, out / "socket-private.patch")
            row["socket_copy_hashes"] = {
                "original_sha256": hashlib.sha256(before.encode()).hexdigest(),
                "private_sha256": hashlib.sha256(after.encode()).hexdigest()}
            environment["FAIRNESS_TEST_LIB"] = str(test_tree / "lib")
            row["socket_exit_code"] = run(
                ["perl", str(private_fixture), "--fair=" + ("off" if baseline else "on"),
                 "--flow=socket", "--size=1048576",
                 "--output=" + str(out / "socket.ndjson")], out / "socket.log",
                cwd=test_tree, env=environment, timeout=240)
            if variant == "final" and row["socket_exit_code"] != 0:
                final_ok = False
        metadata["variants"][variant] = row
        (results / "comparison.json").write_text(json.dumps(metadata, indent=2) + "\n")
    metadata.update(final_passed=final_ok, posted_barrier_mutant_killed=killed,
                    measurement_limits="No bulk throughput or CPU experiment; socket timing "
                    "is diagnostic and does not define a universal fairness bound.")
    (results / "comparison.json").write_text(json.dumps(metadata, indent=2) + "\n")
    if not final_ok or not killed:
        raise SystemExit("Final candidate failed or the proxy assertions did not kill the mutant")


if __name__ == "__main__":
    main()

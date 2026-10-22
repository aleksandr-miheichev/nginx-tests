#!/usr/bin/env bash
# Run from GITHUB_WORKSPACE. CI helpers live in ci/.github/scripts/.
set -euo pipefail

mkdir -p results
results="$PWD/results"
source_dir="$PWD/nginx"
tests_dir="$PWD/tests"
ci_dir="$PWD/ci"

# Preserve partial application/conflict evidence even if a cherry-pick fails.
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
capture_trees() {
    for tree in nginx tests; do
        directory="$source_dir"
        if [[ "$tree" == tests ]]; then directory="$tests_dir"; fi
        git -C "$directory" rev-parse HEAD > "$results/$tree-final-sha.txt"
        git -C "$directory" status --short > "$results/$tree-status.txt"
        git -C "$directory" diff --binary > "$results/$tree-uncommitted.patch"
        git -C "$directory" ls-files --unmerged > "$results/$tree-conflict-stages.txt"
    done
    git -C "$source_dir" diff --binary "$SOURCE_SHA" > "$results/source-integration.patch"
    git -C "$tests_dir" diff --binary "$TESTS_SHA" > "$results/tests-integration.patch"
}
trap capture_trees EXIT

test "$(git -C nginx rev-parse HEAD)" = "$SOURCE_SHA"
test "$(git -C tests rev-parse HEAD)" = "$TESTS_SHA"
test -z "$(git -C nginx status --porcelain)"
test -z "$(git -C tests status --porcelain)"
git -C nginx diff --binary 148c75678cd4171338c31d4ed4c02411736d5fe9 \
    "$SOURCE_SHA" > "$results/source-candidate.patch"
git -C tests show --format=fuller --binary "$TESTS_SHA" > "$results/tests-candidate-commit.patch"
{
    printf 'source_candidate=%s\ntests_candidate=%s\n' "$SOURCE_SHA" "$TESTS_SHA"
    printf 'ci_commit=%s\n' "$(git -C ci rev-parse HEAD)"
    printf 'mode=%s\nintegration=%s\n' "$BUILD_MODE" "$INTEGRATION"
    printf 'source_base=148c75678cd4171338c31d4ed4c02411736d5fe9\n'
    printf 'asan_options=%s\n' "$ASAN_OPTIONS"
    uname -a
    gcc --version
    clang --version
    openssl version -a
    perl -V
    dpkg-query -W libpcre2-dev libssl-dev zlib1g-dev
} > "$results/environment.txt" 2>&1

apply_commit() {
    local directory=$1 repository=$2 commit=$3
    git -C "$directory" fetch --no-tags "$repository" "$commit"
    if git -C "$directory" merge-base --is-ancestor "$commit" HEAD; then
        printf 'Already present: %s\n' "$commit"
        return
    fi
    # A conflict, including queue_position API conflicts, is a failed job.
    # Do not resolve with -Xours/-Xtheirs or remove candidate scheduling code.
    git -C "$directory" -c user.name='CI integration' \
        -c user.email='ci@example.invalid' cherry-pick "$commit"
}

case "$INTEGRATION" in
    standalone) ;;
    pending-prs)
        {
            apply_commit nginx https://github.com/nginx/nginx.git \
                a8593591f9051f7cd4c5029d7d60108358301562
            apply_commit nginx https://github.com/nginx/nginx.git \
                240fa7a5f3ac6482242fa442c42ebd05160f6311
            apply_commit tests https://github.com/nginx/nginx-tests.git \
                c5e8e872dafa89c87c1e242d56df27e2a949d10a
        } > "$results/integration-apply.log" 2>&1
        ;;
    *) printf 'Unknown integration: %s\n' "$INTEGRATION" >&2; exit 2 ;;
esac

for test_file in h2_fair_scheduling.t h2_fair_scheduling_proxy.t \
    h2_fair_scheduling_lifecycle.t h2_priority_incremental.t; do
    test -f "$tests_dir/$test_file"
done

extra=()
case "$BUILD_MODE" in
    gcc-full) extra+=(--with-cc=gcc) ;;
    clang-asan-h2)
        extra+=(--with-cc=clang
            '--with-cc-opt=-O1 -g -fsanitize=address -fno-omit-frame-pointer'
            '--with-ld-opt=-fsanitize=address')
        ;;
    *) printf 'Unknown build mode: %s\n' "$BUILD_MODE" >&2; exit 2 ;;
esac

cd "$source_dir"
auto/configure --with-debug --with-http_ssl_module --with-http_v2_module \
    --with-http_v3_module --with-http_realip_module --with-http_addition_module \
    --with-http_sub_module --with-http_dav_module --with-http_flv_module \
    --with-http_mp4_module --with-http_gunzip_module --with-http_gzip_static_module \
    --with-http_auth_request_module --with-http_random_index_module \
    --with-http_secure_link_module --with-http_degradation_module \
    --with-http_stub_status_module --with-stream --with-stream_ssl_module \
    --with-stream_ssl_preread_module --with-stream_realip_module \
    --with-mail --with-mail_ssl_module --with-threads --with-file-aio \
    "${extra[@]}" > "$results/configure.log" 2>&1
make -j2 > "$results/build.log" 2>&1
objs/nginx -V > "$results/nginx-version.txt" 2>&1

cd "$tests_dir"
export TEST_NGINX_BINARY="$source_dir/objs/nginx"
if [[ "$BUILD_MODE" == gcc-full ]]; then
    command=(prove -v .)
    printf '%s\n' ./*.t > "$results/selected-tests.txt"
else
    # ASan memory-access checks only: no leak or undefined-behavior claim.
    shopt -s nullglob
    files=(h2*.t grpc*.t proxy_h2*.t worker_shutdown_timeout_h2.t)
    test "${#files[@]}" -gt 0
    for file in "${files[@]}"; do test -f "$file"; done
    printf '%s\n' "${files[@]}" > "$results/selected-tests.txt"
    command=(prove -v "${files[@]}")
fi
wc -l < "$results/selected-tests.txt" > "$results/selected-test-count.txt"
printf '%q ' "${command[@]}" > "$results/test-command.txt"
printf '\n' >> "$results/test-command.txt"
set +e
"${command[@]}" > "$results/suite.log" 2>&1
suite_status=$?
set -e
printf '%s\n' "$suite_status" > "$results/suite-exit-code.txt"
summary_status=0
python3 "$ci_dir/.github/scripts/summarize_prove.py" \
    "$results/suite.log" "$results/per-test-results.json" || summary_status=$?
cd "$GITHUB_WORKSPACE"
if (( suite_status != 0 )); then
    exit "$suite_status"
fi
exit "$summary_status"

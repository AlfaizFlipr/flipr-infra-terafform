#!/usr/bin/env bash
set -Eeuo pipefail

image_file=${1:?usage: smoke-test.sh <image-file>}
image=$(<"$image_file")

test -n "$image"
docker run --rm "$image" | tee smoke-test.log
grep -qx 'test-image-ready' smoke-test.log

mkdir -p test-results
cat > test-results/test-image-smoke.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="test-image-smoke" tests="1" failures="0"><testcase name="image-starts"/></testsuite>
EOF

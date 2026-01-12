#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

for test_file in "${ROOT_DIR}/tests"/test_*.sh; do
    echo "-- running ${test_file}"
    /usr/bin/env bash "${test_file}"
done

echo "-- tests complete"

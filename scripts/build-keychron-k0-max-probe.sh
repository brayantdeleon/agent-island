#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPOSITORY_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
readonly SOURCE="${REPOSITORY_ROOT}/Hardware/KeychronK0Max/Probe/k0max_probe.c"
readonly OUTPUT_DIR="${OUTPUT_DIR:-/private/tmp/agent-island-k0-max-artifacts}"
readonly OUTPUT="${OUTPUT_DIR}/k0max-probe"

mkdir -p "${OUTPUT_DIR}"

clang \
    -std=c17 \
    -Wall \
    -Wextra \
    -Werror \
    -O2 \
    -framework IOKit \
    -framework CoreFoundation \
    "${SOURCE}" \
    -o "${OUTPUT}"

"${OUTPUT}" --self-test
print "Probe built at ${OUTPUT}"

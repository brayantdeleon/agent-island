#!/bin/zsh

set -euo pipefail

readonly PINNED_COMMIT="07bfc38a4b11b8dac7ab758dfc5868b4229499ca"
readonly KEYBOARD="keychron/k0_max"
readonly STOCK_KEYMAP="keychron"
readonly CUSTOM_KEYMAP="agent_island"

readonly SCRIPT_DIR="${0:A:h}"
readonly REPOSITORY_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
readonly OVERLAY_DIR="${REPOSITORY_ROOT}/Hardware/KeychronK0Max/Firmware/keymaps/${CUSTOM_KEYMAP}"
readonly PATCH_FILE="${REPOSITORY_ROOT}/Hardware/KeychronK0Max/Firmware/patches/keychron-raw-hid-user-hook.patch"
readonly QMK_SOURCE="${QMK_SOURCE:-/private/tmp/agent-island-keychron-qmk}"
readonly OUTPUT_DIR="${OUTPUT_DIR:-/private/tmp/agent-island-k0-max-artifacts}"
readonly QMK_CLI_BIN="${QMK_CLI_BIN:-/private/tmp/agent-island-qmk-uv-bin/qmk}"
readonly QMK_TOOLCHAIN_BIN="${QMK_TOOLCHAIN_BIN:-/private/tmp/agent-island-qmk-distrib/bin}"
readonly TARGET_KEYMAP_DIR="${QMK_SOURCE}/keyboards/keychron/k0_max/keymaps/${CUSTOM_KEYMAP}"

if [[ ! -x "${QMK_CLI_BIN}" ]]; then
    print -u2 "QMK CLI not found at ${QMK_CLI_BIN}."
    print -u2 "Install QMK or set QMK_CLI_BIN to an executable qmk path."
    exit 1
fi

if [[ ! -d "${QMK_SOURCE}/.git" ]]; then
    print -u2 "Keychron QMK source not found at ${QMK_SOURCE}."
    print -u2 "Clone https://github.com/Keychron/qmk_firmware.git at ${PINNED_COMMIT}, or set QMK_SOURCE."
    exit 1
fi

actual_commit="$(git -C "${QMK_SOURCE}" rev-parse HEAD)"
if [[ "${actual_commit}" != "${PINNED_COMMIT}" ]]; then
    print -u2 "Expected Keychron QMK ${PINNED_COMMIT}; found ${actual_commit}."
    exit 1
fi

if ! git -C "${QMK_SOURCE}" diff --quiet || ! git -C "${QMK_SOURCE}" diff --cached --quiet; then
    print -u2 "The supplied QMK source has tracked changes. Use a clean pinned checkout."
    exit 1
fi

if [[ -e "${TARGET_KEYMAP_DIR}" ]]; then
    print -u2 "Temporary keymap destination already exists: ${TARGET_KEYMAP_DIR}"
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

source_digest="$(
    cd "${REPOSITORY_ROOT}"
    {
        print -r -- "${PINNED_COMMIT}"
        for file in \
            "Hardware/KeychronK0Max/Firmware/patches/keychron-raw-hid-user-hook.patch" \
            "Hardware/KeychronK0Max/Firmware/keymaps/agent_island/config.h" \
            "Hardware/KeychronK0Max/Firmware/keymaps/agent_island/keymap.c" \
            "Hardware/KeychronK0Max/Firmware/keymaps/agent_island/rules.mk"; do
            print -r -- "${file}"
            shasum -a 256 "${file}" | awk '{print $1}'
        done
    } | shasum -a 256 | awk '{print $1}'
)"
readonly source_digest
readonly build_id="${source_digest[1,8]}"

patch_applied=false
overlay_installed=false
cleanup() {
    if [[ "${overlay_installed}" == true && -d "${TARGET_KEYMAP_DIR}" ]]; then
        rm -rf "${TARGET_KEYMAP_DIR}"
    fi
    if [[ "${patch_applied}" == true ]]; then
        git -C "${QMK_SOURCE}" apply --reverse "${PATCH_FILE}"
    fi
}
trap cleanup EXIT INT TERM

export PATH="${QMK_TOOLCHAIN_BIN}:${QMK_CLI_BIN:h}:${PATH}"
export QMK_HOME="${QMK_SOURCE}"

print "Building unchanged stock recovery image..."
(
    cd "${QMK_SOURCE}"
    "${QMK_CLI_BIN}" compile -kb "${KEYBOARD}" -km "${STOCK_KEYMAP}"
)
cp "${QMK_SOURCE}/keychron_k0_max_keychron.bin" "${OUTPUT_DIR}/keychron_k0_max_stock_${PINNED_COMMIT[1,12]}.bin"

git -C "${QMK_SOURCE}" apply --check "${PATCH_FILE}"
git -C "${QMK_SOURCE}" apply "${PATCH_FILE}"
patch_applied=true

mkdir -p "${TARGET_KEYMAP_DIR}"
cp "${OVERLAY_DIR}/config.h" "${TARGET_KEYMAP_DIR}/config.h"
cp "${OVERLAY_DIR}/keymap.c" "${TARGET_KEYMAP_DIR}/keymap.c"
cp "${OVERLAY_DIR}/rules.mk" "${TARGET_KEYMAP_DIR}/rules.mk"
printf '#pragma once\n#define AGENT_ISLAND_BUILD_ID 0x%su\n' "${build_id}" > "${TARGET_KEYMAP_DIR}/agent_island_build_id.h"
overlay_installed=true

print "Building Agent Island diagnostic firmware (build ID 0x${build_id})..."
(
    cd "${QMK_SOURCE}"
    "${QMK_CLI_BIN}" compile -kb "${KEYBOARD}" -km "${CUSTOM_KEYMAP}"
)
cp "${QMK_SOURCE}/keychron_k0_max_agent_island.bin" "${OUTPUT_DIR}/keychron_k0_max_agent_island_${build_id}.bin"

stock_path="${OUTPUT_DIR}/keychron_k0_max_stock_${PINNED_COMMIT[1,12]}.bin"
custom_path="${OUTPUT_DIR}/keychron_k0_max_agent_island_${build_id}.bin"
stock_sha="$(shasum -a 256 "${stock_path}" | awk '{print $1}')"
custom_sha="$(shasum -a 256 "${custom_path}" | awk '{print $1}')"
compiler_version="$(arm-none-eabi-gcc --version | head -n 1)"

cat > "${OUTPUT_DIR}/manifest.txt" <<MANIFEST
Keychron QMK source: https://github.com/Keychron/qmk_firmware.git
Keychron QMK commit: ${PINNED_COMMIT}
QMK target: ${KEYBOARD}
QMK CLI: $("${QMK_CLI_BIN}" --version)
Compiler: ${compiler_version}
Agent Island source digest (SHA-256): ${source_digest}
Agent Island build ID (first 32 digest bits): 0x${build_id}
Stock firmware: ${stock_path}
Stock firmware SHA-256: ${stock_sha}
Diagnostic firmware: ${custom_path}
Diagnostic firmware SHA-256: ${custom_sha}
MANIFEST

print
print "Firmware artifacts:"
print "  ${stock_path}"
print "  ${custom_path}"
print "  ${OUTPUT_DIR}/manifest.txt"

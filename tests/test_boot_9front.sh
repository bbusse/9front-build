#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: Björn Busse <bj.rn@baerlin.eu>
# SPDX-License-Identifier: BSD-3-Clause
#

QEMU_ARCH="${QEMU_ARCH:-amd64}"
DISK_IMAGE="${DISK_IMAGE:-9front-${QEMU_ARCH}.img}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
SHELL_TIMEOUT="${SHELL_TIMEOUT:-30}"
BOOT_LOG_DIR="${BOOT_LOG_DIR:-}"

WORK=""
ROOT_DISK=sdE0
SHELL_PROMPT='term% '
if [ arm64 = "${QEMU_ARCH}" ]; then
    ROOT_DISK=sdF0
    SHELL_PROMPT='^% '
fi

# shellcheck source=lib/qemu.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/qemu.sh"

run_on_console() {
    local from
    from="$(serial_size)"
    send_line "${1}"
    wait_for "${2}" "${SHELL_TIMEOUT}" "${from}"
}

setup_suite() {
    if [ ! -f "${DISK_IMAGE}" ]; then
        fail "Disk image not found: ${DISK_IMAGE} (set DISK_IMAGE to override)"
    fi

    WORK="$(mktemp -d)"

    local disks=()
    mapfile -t disks < <(qemu_disk 0 "${DISK_IMAGE}" snapshot)
    qemu_start "${WORK}" "${disks[@]}"
}

test_01_image_boots_to_a_shell() {
    assert "wait_for '${SHELL_PROMPT}' ${BOOT_TIMEOUT}" \
        "the console should reach a shell prompt within ${BOOT_TIMEOUT}s"
}

test_02_shell_runs_commands() {
    assert "run_on_console 'echo BOOT_TEST_OK | sed s/OK/PASSED/' BOOT_TEST_PASSED" \
        "the shell should run a command sent over the console"
}

test_03_root_is_gefs() {
    assert "run_on_console 'fstype /dev/${ROOT_DISK}/fs | sed s/gefs/ROOT_IS_GEFS/' ROOT_IS_GEFS" \
        "the root file system should be gefs"
}

teardown_suite() {
    qemu_stop
    if [ -n "${SERIAL_LOG}" ] && [ -f "${SERIAL_LOG}" ]; then
        echo "----- 9front console -----"
        serial_text
        echo "----- end 9front console -----"
        if [ -n "${BOOT_LOG_DIR}" ]; then
            mkdir -p "${BOOT_LOG_DIR}"
            cp "${SERIAL_LOG}" "${WORK}/qemu.log" "${BOOT_LOG_DIR}/" 2>/dev/null || true
        fi
    fi
    [ -n "${WORK}" ] && rm -rf "${WORK}"
}

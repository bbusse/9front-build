#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: Björn Busse <bj.rn@baerlin.eu>
# SPDX-License-Identifier: BSD-3-Clause
#

QEMU_PID=""
READER_PID=""
SERIAL_LOG=""

qemu_accel() {
    if [ "${QEMU_ACCEL:-kvm}" = kvm ] &&
        [ "$(uname -m)" = x86_64 ] &&
        [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        echo kvm
    else
        echo tcg
    fi
}

ovmf_paths() {
    if [ -n "${OVMF_CODE:-}" ] && [ -n "${OVMF_VARS:-}" ]; then
        echo "${OVMF_CODE} ${OVMF_VARS}"
        return 0
    fi

    local pair
    for pair in \
        /usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd \
        /usr/share/qemu/edk2-x86_64-code.fd:/usr/share/qemu/edk2-i386-vars.fd; do
        if [ -f "${pair%%:*}" ] && [ -f "${pair##*:}" ]; then
            echo "${pair%%:*} ${pair##*:}"
            return 0
        fi
    done
    return 1
}

qemu_disk() {
    local bus
    bus="${1}"
    local file
    file="${2}"
    local kind
    kind="${3:-hd}"

    local opts
    opts="if=none,id=disk${bus},format=raw,file=${file}"
    case "${kind}" in
    cd) opts="${opts},readonly=on" ;;
    snapshot) opts="${opts},snapshot=on" kind=hd ;;
    esac

    printf '%s\n' -drive "${opts}" -device "ide-${kind},drive=disk${bus},bus=ide.${bus},bootindex=${bus}"
}

qemu_start() {
    local work
    work="${1}"
    shift

    local fw
    if ! fw="$(ovmf_paths)"; then
        echo "No OVMF firmware found, install ovmf or set OVMF_CODE and OVMF_VARS" >&2
        return 1
    fi
    local code
    local vars
    read -r code vars <<<"${fw}"

    mkdir -p "${work}"
    cp "${vars}" "${work}/vars.fd"
    rm -f "${work}/serial.in" "${work}/serial.out"
    mkfifo "${work}/serial.in" "${work}/serial.out"
    SERIAL_LOG="${work}/serial.log"
    : >"${SERIAL_LOG}"

    exec 3<>"${work}/serial.in"
    exec 4<>"${work}/serial.out"
    cat <&4 >>"${SERIAL_LOG}" &
    READER_PID=$!

    local accel
    accel="$(qemu_accel)"
    local cpu
    cpu=max
    if [ kvm = "${accel}" ]; then
        cpu=host
    fi

    qemu-system-x86_64 -nodefaults \
        -machine "q35,accel=${accel}" -cpu "${cpu}" -smp 2 -m "${QEMU_MEM:-2048}" \
        -display none -monitor none -no-reboot -nic none \
        -serial "pipe:${work}/serial" \
        -drive "if=pflash,format=raw,unit=0,file=${code},readonly=on" \
        -drive "if=pflash,format=raw,unit=1,file=${work}/vars.fd" \
        "$@" >"${work}/qemu.log" 2>&1 &
    QEMU_PID=$!
}

qemu_running() {
    [ -n "${QEMU_PID}" ] && kill -0 "${QEMU_PID}" 2>/dev/null
}

serial_size() {
    wc -c <"${SERIAL_LOG}" | tr -d ' '
}

wait_for() {
    local pattern
    pattern="${1}"
    local timeout
    timeout="${2}"
    local from
    from="${3:-0}"

    local waited
    waited=0
    while [ "${waited}" -lt "${timeout}" ]; do
        if tail -c "+$((from + 1))" "${SERIAL_LOG}" | grep -aqE "${pattern}"; then
            return 0
        fi
        if ! qemu_running; then
            return 2
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

wait_for_exit() {
    local timeout
    timeout="${1}"

    local waited
    waited=0
    while qemu_running && [ "${waited}" -lt "${timeout}" ]; do
        sleep 1
        waited=$((waited + 1))
    done
    ! qemu_running
}

send_line() {
    printf '%s\r' "${1}" >&3
}

serial_text() {
    sed 's/\x1b\[[0-9;=?]*[A-Za-z]//g' "${SERIAL_LOG}" | tr -d '\r'
}

qemu_stop() {
    if qemu_running; then
        kill "${QEMU_PID}" 2>/dev/null || true
        wait "${QEMU_PID}" 2>/dev/null || true
    fi
    if [ -n "${READER_PID}" ]; then
        kill "${READER_PID}" 2>/dev/null || true
        wait "${READER_PID}" 2>/dev/null || true
    fi
    exec 3>&- 4>&-
    QEMU_PID=""
    READER_PID=""
}

#!/bin/bash

set -e 

usage() {
    local code="$1"
    >&2 echo "usage: $0 HUB_CODE_PATH"
    exit $code
}

error() {
    local code="$1"
    local msg="$2"
    >&2 echo "error: $msg"
    usage $code
}

ROOT="$(cd $(dirname "$0"); pwd)"
HOSTNAME="$(hostname -s)"
FQDN="$(hostname)"
IP="$(ping -c 1 $(hostname) | head -n 1 | awk -F'[()]' '{print $2}')"

HUB_CODE_PATH="$1"

if [ -z "${HUB_CODE_PATH}" ]; then
    error 1 "HUB_CODE_PATH is required"
fi

if [ ! -x "${HUB_CODE_PATH}" ]; then
    error 1 "HUB_CODE_PATH not found: ${HUB_CODE_PATH}"
fi


HUB_ROOT="$(cd $HUB_CODE_PATH; pwd)"
HUB_CA_CERT="${HUB_ROOT}/local/local.CA.pem"
HUB_CA_KEY="${HUB_ROOT}/local/local.CA.key"
HUB_CA_SRL="${HUB_ROOT}/local/local.CA.srl"

if [ -z "${HUB_CA_CERT}" ]; then
    error 1 "HUB CA certificate not found: ${HUB_CA_CERT}"
fi

if [ -z "${HUB_CA_KEY}" ]; then
    error 1 "HUB CA private key not found: ${HUB_CA_KEY}"
fi

for file in "local_v3_ext.cfg" "local.cfg" "ssl_dist_opts.rel"; do
    eval "echo \"$(< ${ROOT}/${file}.template)\"" > "${ROOT}/${file}"
done

openssl genrsa -out "${ROOT}/local.key" 2048
openssl req -new -config "${ROOT}/local.cfg" -key "${ROOT}/local.key" -out "${ROOT}/local.csr"
openssl x509 -req -extfile "${ROOT}/local_v3_ext.cfg" \
        -in "${ROOT}/local.csr" -CA "${HUB_CA_CERT}" -CAkey "${HUB_CA_KEY}" \
        -CAserial "${HUB_CA_SRL}" -out "${ROOT}/local.pem" -days 36500
openssl verify -CAfile "${HUB_CA_CERT}" "${ROOT}/local.pem" || error $? "Failed to verify generated certificate"

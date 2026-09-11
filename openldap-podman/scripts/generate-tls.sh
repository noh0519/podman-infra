#!/bin/sh
set -eu

: "${LDAP_HOSTNAME:?LDAP_HOSTNAME must be set}"
: "${LDAP_ORGANIZATION:?LDAP_ORGANIZATION must be set}"

tls_dir=/etc/ldap/tls
ca_cert="$tls_dir/ca.crt"
ca_key="$tls_dir/ca.key"
server_cert="$tls_dir/server.crt"
server_key="$tls_dir/server.key"

if [ -s "$ca_cert" ] && [ -s "$server_cert" ] && [ -s "$server_key" ]; then
    openssl x509 -checkend 0 -noout -in "$server_cert" >/dev/null
    openssl verify -CAfile "$ca_cert" "$server_cert" >/dev/null
    cert_modulus=$(openssl x509 -noout -modulus -in "$server_cert")
    key_modulus=$(openssl rsa -noout -modulus -in "$server_key" 2>/dev/null)
    if [ "$cert_modulus" != "$key_modulus" ]; then
        echo "ERROR: TLS certificate and private key do not match" >&2
        exit 1
    fi
    exit 0
fi

tls_work_dir=$(mktemp -d)
trap 'rm -rf "$tls_work_dir"' EXIT

openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -subj "/CN=$LDAP_HOSTNAME Local CA/O=$LDAP_ORGANIZATION" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "$tls_work_dir/ca.key" \
    -out "$tls_work_dir/ca.crt"

openssl req -new -newkey rsa:4096 -sha256 -nodes \
    -subj "/CN=$LDAP_HOSTNAME/O=$LDAP_ORGANIZATION" \
    -addext "subjectAltName=DNS:$LDAP_HOSTNAME,DNS:openldap" \
    -keyout "$tls_work_dir/server.key" \
    -out "$tls_work_dir/server.csr"

cat > "$tls_work_dir/server.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$LDAP_HOSTNAME,DNS:openldap
EOF

openssl x509 -req -sha256 -days 825 \
    -in "$tls_work_dir/server.csr" \
    -CA "$tls_work_dir/ca.crt" \
    -CAkey "$tls_work_dir/ca.key" \
    -CAcreateserial \
    -extfile "$tls_work_dir/server.ext" \
    -out "$tls_work_dir/server.crt"

openssl verify -CAfile "$tls_work_dir/ca.crt" "$tls_work_dir/server.crt"

cp "$tls_work_dir/ca.crt" "$ca_cert"
cp "$tls_work_dir/ca.key" "$ca_key"
cp "$tls_work_dir/server.crt" "$server_cert"
cp "$tls_work_dir/server.key" "$server_key"

chown openldap:openldap "$ca_cert" "$server_cert" "$server_key"
chown root:root "$ca_key"
chmod 0644 "$ca_cert" "$server_cert"
chmod 0600 "$ca_key" "$server_key"

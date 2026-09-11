#!/bin/sh
set -eu

require_value() {
    eval "value=\${$1:-}"
    if [ -z "$value" ]; then
        echo "ERROR: $1 must be set" >&2
        exit 1
    fi
}

for variable in LDAP_BASE_DN LDAP_ORGANIZATION LDAP_ADMIN_DN LDAP_ADMIN_PASSWORD \
    LDAP_USER_UID LDAP_USER_CN LDAP_USER_SN LDAP_USER_MAIL LDAP_USER_PASSWORD LDAP_HOSTNAME; do
    require_value "$variable"
done

case "$LDAP_BASE_DN" in
    dc=*,dc=*) ;;
    *) echo "ERROR: LDAP_BASE_DN must look like dc=example,dc=com" >&2; exit 1 ;;
esac

if [ "$LDAP_ADMIN_DN" != "cn=admin,$LDAP_BASE_DN" ]; then
    echo "ERROR: LDAP_ADMIN_DN must be cn=admin,$LDAP_BASE_DN" >&2
    exit 1
fi

install -d -o openldap -g openldap -m 0700 \
    /var/lib/ldap /etc/ldap/slapd.d /etc/ldap/tls

if [ ! -s /etc/ldap/tls/ca.crt ] || [ ! -s /etc/ldap/tls/server.crt ] || [ ! -s /etc/ldap/tls/server.key ]; then
    tls_work_dir=$(mktemp -d)
    trap 'rm -rf "$tls_work_dir"' EXIT
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -subj "/CN=$LDAP_HOSTNAME/O=$LDAP_ORGANIZATION" \
        -addext "subjectAltName=DNS:$LDAP_HOSTNAME,DNS:openldap" \
        -keyout "$tls_work_dir/server.key" -out "$tls_work_dir/server.crt"
    cp "$tls_work_dir/server.crt" /etc/ldap/tls/ca.crt
    cp "$tls_work_dir/server.crt" /etc/ldap/tls/server.crt
    cp "$tls_work_dir/server.key" /etc/ldap/tls/server.key
    chown openldap:openldap /etc/ldap/tls/*
    chmod 0600 /etc/ldap/tls/server.key
    chmod 0644 /etc/ldap/tls/ca.crt /etc/ldap/tls/server.crt
fi

password_hash() {
    case "$1" in
        '{SSHA}'*) printf '%s\n' "$1" ;;
        *) slappasswd -s "$1" ;;
    esac
}

write_bootstrap_ldif() {
    user_hash=$(password_hash "$LDAP_USER_PASSWORD")
    first_dc=${LDAP_BASE_DN%%,*}
    first_dc=${first_dc#dc=}
    cat > /run/bootstrap.ldif <<EOF
dn: $LDAP_BASE_DN
objectClass: top
objectClass: dcObject
objectClass: organization
o: $LDAP_ORGANIZATION
dc: $first_dc

dn: uid=$LDAP_USER_UID,$LDAP_BASE_DN
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
uid: $LDAP_USER_UID
cn: $LDAP_USER_CN
sn: $LDAP_USER_SN
mail: $LDAP_USER_MAIL
userPassword: $user_hash
EOF
}

install -d -o openldap -g openldap -m 0755 /run/slapd

if [ ! -f /etc/ldap/slapd.d/cn=config.ldif ]; then
    if [ -n "$(find /etc/ldap/slapd.d -mindepth 1 -maxdepth 1 -print -quit)" ]; then
        echo "ERROR: /etc/ldap/slapd.d is not empty but has no cn=config.ldif" >&2
        exit 1
    fi

    admin_hash=$(password_hash "$LDAP_ADMIN_PASSWORD")
    cat > /run/bootstrap-slapd.conf <<EOF
include         /etc/ldap/schema/core.schema
include         /etc/ldap/schema/cosine.schema
include         /etc/ldap/schema/nis.schema
include         /etc/ldap/schema/inetorgperson.schema
pidfile         /run/slapd/slapd.pid
argsfile        /run/slapd/slapd.args
loglevel        stats

TLSCertificateFile      /etc/ldap/tls/server.crt
TLSCertificateKeyFile   /etc/ldap/tls/server.key
TLSCACertificateFile    /etc/ldap/tls/ca.crt
TLSProtocolMin          3.3

modulepath      /usr/lib/ldap
moduleload      back_mdb

database        config
access to *
    by dn.exact="gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth" manage
    by * none

database        mdb
maxsize         1073741824
suffix          "$LDAP_BASE_DN"
rootdn          "$LDAP_ADMIN_DN"
rootpw          $admin_hash
directory       /var/lib/ldap
index           objectClass eq
index           uid,mail eq

access to attrs=userPassword
    by dn.exact="gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth" manage
    by dn.exact="$LDAP_ADMIN_DN" write
    by self write
    by anonymous auth
    by * none
access to *
    by dn.exact="gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth" manage
    by dn.exact="$LDAP_ADMIN_DN" manage
    by users read
    by anonymous auth
EOF

    if [ ! -f /var/lib/ldap/data.mdb ]; then
        write_bootstrap_ldif
        slapadd -f /run/bootstrap-slapd.conf -l /run/bootstrap.ldif
        chown -R openldap:openldap /var/lib/ldap
    fi

    slaptest -f /run/bootstrap-slapd.conf -F /etc/ldap/slapd.d
    chown -R openldap:openldap /etc/ldap/slapd.d
fi

if [ ! -f /var/lib/ldap/data.mdb ]; then
    write_bootstrap_ldif
    slapadd -F /etc/ldap/slapd.d -b "$LDAP_BASE_DN" -l /run/bootstrap.ldif
    chown -R openldap:openldap /var/lib/ldap
fi

exec /usr/sbin/slapd -d 0 -u openldap -g openldap -F /etc/ldap/slapd.d \
    -h "ldap:/// ldaps:/// ldapi:///"

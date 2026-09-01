#!/bin/sh
set -eu

require_value() {
    eval "value=\${$1:-}"
    if [ -z "$value" ]; then
        echo "ERROR: $1 must be set" >&2
        exit 1
    fi
}

require_value MAIL_HOSTNAME
require_value MAIL_DOMAINS
require_value MAILBOXES
require_value MAIL_USERS

: "${MYNETWORKS:=127.0.0.0/8 [::1]/128}"
: "${MESSAGE_SIZE_LIMIT:=26214400}"
: "${MAIL_ALIASES:=}"
: "${RELAYHOST:=}"
: "${RELAY_USERNAME:=}"
: "${RELAY_PASSWORD:=}"
: "${TLS_CERT_FILE:=/etc/postfix/tls/fullchain.pem}"
: "${TLS_KEY_FILE:=/etc/postfix/tls/privkey.pem}"

: > /etc/postfix/virtual_domains
for domain in $MAIL_DOMAINS; do
    printf '%s OK\n' "$domain" >> /etc/postfix/virtual_domains
done

: > /etc/postfix/virtual_mailboxes
for address in $MAILBOXES; do
    domain=${address#*@}
    localpart=${address%@*}
    if [ "$domain" = "$address" ] || [ -z "$localpart" ]; then
        echo "ERROR: invalid mailbox address: $address" >&2
        exit 1
    fi
    printf '%s %s/%s/Maildir/\n' "$address" "$domain" "$localpart" >> /etc/postfix/virtual_mailboxes
done

: > /etc/postfix/virtual_aliases
for mapping in $MAIL_ALIASES; do
    source=${mapping%%=*}
    destination=${mapping#*=}
    if [ "$source" = "$mapping" ] || [ -z "$destination" ]; then
        echo "ERROR: invalid alias (expected source=destination): $mapping" >&2
        exit 1
    fi
    printf '%s %s\n' "$source" "$destination" >> /etc/postfix/virtual_aliases
done

postmap /etc/postfix/virtual_domains
postmap /etc/postfix/virtual_mailboxes
postmap /etc/postfix/virtual_aliases

install -d -m 0755 /etc/dovecot
: > /etc/dovecot/users
for account in $MAIL_USERS; do
    address=${account%%=*}
    password_hash=${account#*=}
    if [ "$address" = "$account" ] || [ -z "$password_hash" ]; then
        echo "ERROR: invalid mail user (expected address={SCHEME}hash): $account" >&2
        exit 1
    fi
    case "$password_hash" in
        "{SHA512-CRYPT}"*) ;;
        *)
            echo "ERROR: MAIL_USERS must contain SHA512-CRYPT hashes, not plaintext passwords" >&2
            exit 1
            ;;
    esac
    if ! awk -v address="$address" '$1 == address { found = 1 } END { exit !found }' /etc/postfix/virtual_mailboxes; then
        echo "ERROR: Dovecot user is not listed in MAILBOXES: $address" >&2
        exit 1
    fi
    printf '%s:%s\n' "$address" "$password_hash" >> /etc/dovecot/users
done
chown root:dovecot /etc/dovecot/users
chmod 0640 /etc/dovecot/users

postconf -e "myhostname = $MAIL_HOSTNAME"
postconf -e "myorigin = \$myhostname"
postconf -e "mydestination = localhost.localdomain, localhost"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = all"
postconf -e "mynetworks = $MYNETWORKS"
postconf -e "smtpd_banner = \$myhostname ESMTP"
postconf -e "maillog_file = /dev/stdout"
postconf -e "disable_vrfy_command = yes"
postconf -e "smtpd_helo_required = yes"
postconf -e "message_size_limit = $MESSAGE_SIZE_LIMIT"
postconf -e "mailbox_size_limit = 0"
postconf -e "virtual_mailbox_domains = hash:/etc/postfix/virtual_domains"
postconf -e "virtual_mailbox_maps = hash:/etc/postfix/virtual_mailboxes"
postconf -e "virtual_alias_maps = hash:/etc/postfix/virtual_aliases"
postconf -e "virtual_mailbox_base = /var/mail/vhosts"
postconf -e "virtual_uid_maps = static:5000"
postconf -e "virtual_gid_maps = static:5000"
postconf -e "virtual_minimum_uid = 5000"
postconf -e "smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination"
postconf -e "smtpd_recipient_restrictions = reject_unknown_recipient_domain, reject_unauth_destination"
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = no"
postconf -e "smtpd_tls_auth_only = yes"

if [ -f "$TLS_CERT_FILE" ] && [ -f "$TLS_KEY_FILE" ]; then
    postconf -e "smtpd_tls_cert_file = $TLS_CERT_FILE"
    postconf -e "smtpd_tls_key_file = $TLS_KEY_FILE"
    postconf -e "smtpd_tls_security_level = may"
    postconf -e "smtp_tls_security_level = may"
    postconf -e "smtpd_tls_loglevel = 1"
    DOVECOT_SSL=yes
    DOVECOT_IMAPS_PORT=993
else
    postconf -e "smtpd_tls_security_level = none"
    postconf -e "smtp_tls_security_level = may"
    DOVECOT_SSL=no
    DOVECOT_IMAPS_PORT=0
    echo "WARNING: TLS certificate/key not found; STARTTLS, IMAPS and authenticated submission are unavailable" >&2
fi

cat > /etc/dovecot/dovecot.conf <<EOF
protocols = imap
listen = *, ::
mail_location = maildir:/var/mail/vhosts/%d/%n/Maildir
first_valid_uid = 5000
last_valid_uid = 5000
disable_plaintext_auth = yes
auth_mechanisms = plain login
auth_username_format = %Lu
ssl = $DOVECOT_SSL
log_path = /dev/stdout
info_log_path = /dev/stdout

passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT username_format=%u /etc/dovecot/users
}

userdb {
  driver = static
  args = uid=5000 gid=5000 home=/var/mail/vhosts/%d/%n
}

service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = $DOVECOT_IMAPS_PORT
    ssl = yes
  }
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
EOF

if [ "$DOVECOT_SSL" = yes ]; then
    {
        printf 'ssl_cert = <%s\n' "$TLS_CERT_FILE"
        printf 'ssl_key = <%s\n' "$TLS_KEY_FILE"
    } >> /etc/dovecot/dovecot.conf
fi

if [ -n "$RELAYHOST" ]; then
    postconf -e "relayhost = $RELAYHOST"
    if [ -n "$RELAY_USERNAME" ] && [ -n "$RELAY_PASSWORD" ]; then
        printf '%s %s:%s\n' "$RELAYHOST" "$RELAY_USERNAME" "$RELAY_PASSWORD" > /etc/postfix/sasl_passwd
        chmod 0600 /etc/postfix/sasl_passwd
        postmap /etc/postfix/sasl_passwd
        postconf -e "smtp_sasl_auth_enable = yes"
        postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
        postconf -e "smtp_sasl_security_options = noanonymous"
        postconf -e "smtp_tls_security_level = encrypt"
    fi
else
    postconf -X relayhost 2>/dev/null || true
fi

mkdir -p /var/mail/vhosts
chown -R 5000:5000 /var/mail/vhosts

postfix check
dovecot -c /etc/dovecot/dovecot.conf
exec postfix start-fg

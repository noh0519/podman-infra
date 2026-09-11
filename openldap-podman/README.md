# Podman OpenLDAP 서버

운영용 OpenLDAP을 Podman Compose로 실행하는 구성입니다.

## 구성

- Base DN: `dc=bonohbh,dc=com`
- 관리자 DN: `cn=admin,dc=bonohbh,dc=com`
- 초기 사용자 DN: `uid=user1,dc=bonohbh,dc=com`
- `slapd-config` (`cn=config`) 동적 설정 사용
- LDAP/STARTTLS: TCP 389
- LDAPS: TCP 636
- `ldapi:///`와 SASL EXTERNAL을 통한 로컬 설정 관리
- LDAP DB, `cn=config`, 전용 로컬 CA와 서버 인증서를 Podman 볼륨에 영속화
- 익명 디렉터리 조회 차단
- 관리자 및 사용자 비밀번호는 SSHA 해시로 LDAP DB에 저장

## 환경 설정

실제 비밀번호가 들어 있는 `.env`는 Git에서 제외되며 권한을 `0600`으로 유지합니다.

```sh
cp .env.example .env
chmod 600 .env
```

주요 값은 다음과 같습니다. 디렉터리 및 관리자 관련 값은 `ldap-config` 볼륨을
처음 초기화할 때 사용됩니다.

- `LDAP_BASE_DN`: 디렉터리 suffix
- `LDAP_ADMIN_DN`, `LDAP_ADMIN_PASSWORD`: 관리자 로그인 정보
- `LDAP_USER_*`: 빈 데이터 볼륨의 첫 기동 때 생성할 사용자 정보
- `LDAP_HOSTNAME`: 서버 인증서의 CN과 SAN

`LDAP_ADMIN_PASSWORD`와 `LDAP_USER_PASSWORD`에는 평문 또는 `slappasswd`로 생성한
`{SSHA}` 값을 사용할 수 있습니다. `{SSHA}` 값을 사용하면 컨테이너는 이를 다시
해싱하지 않고 그대로 OpenLDAP 설정 및 초기 데이터에 적용합니다.

초기 사용자 항목은 LDAP 데이터 볼륨이 비어 있을 때만 생성됩니다. 운영 중
`.env`에서 관리자나 초기 사용자 값을 바꾸는 것만으로 기존 `cn=config` 또는 LDAP
항목은 변경되지 않습니다. 운영 중 설정은 LDAP 연산으로 변경하십시오.

## TLS 인증서

빈 `ldap-tls` 볼륨으로 처음 실행하면 다음 인증서를 자동 생성합니다.

- 4096비트 RSA 로컬 CA: 유효기간 10년
- CA가 서명한 4096비트 RSA 서버 인증서: 유효기간 825일
- 서버 인증서 SAN: `LDAP_HOSTNAME`, `openldap`
- 서버 인증서 용도: TLS Web Server Authentication

볼륨의 파일과 권한은 다음과 같습니다.

```text
/etc/ldap/tls/ca.crt       0644  OpenLDAP과 클라이언트에 배포할 CA 인증서
/etc/ldap/tls/ca.key       0600  root 전용 CA 개인키
/etc/ldap/tls/server.crt   0644  OpenLDAP 서버 인증서
/etc/ldap/tls/server.key   0600  OpenLDAP 서버 개인키
```

기동할 때 인증서 유효기간, CA 서명 및 서버 인증서/개인키 일치 여부를 검사합니다.
필수 파일이 이미 있는 기존 TLS 볼륨은 자동 교체하지 않습니다.

## 동적 설정 구조

첫 기동 때 엔트리포인트가 임시 설정을 만들고 `slaptest`로
`/etc/ldap/slapd.d`의 `cn=config` 데이터베이스로 변환합니다. 이후 `slapd`는 항상
다음과 같이 동적 설정 디렉터리에서 실행됩니다.

```sh
slapd -F /etc/ldap/slapd.d -h "ldap:/// ldaps:/// ldapi:///"
```

`slapd.d` 안의 LDIF 파일을 직접 편집하지 마십시오. 실행 중에는 컨테이너 내부
root만 `ldapi:///`와 SASL EXTERNAL을 통해 `cn=config`를 관리할 수 있습니다.

현재 설정을 조회하는 예시는 다음과 같습니다.

```sh
podman exec openldap-server ldapsearch -LLL -Q \
  -Y EXTERNAL -H ldapi:/// -b cn=config
```

예를 들어 로그 수준을 변경하면 서버를 재시작하지 않아도 적용되고 `ldap-config`
볼륨에 영속화됩니다.

```sh
podman exec -i openldap-server ldapmodify -Q \
  -Y EXTERNAL -H ldapi:/// <<'LDIF'
dn: cn=config
changetype: modify
replace: olcLogLevel
olcLogLevel: stats
LDIF
```

## 실행

```sh
podman compose up -d --build
podman compose ps
podman compose logs -f openldap
```

## 연결 확인

운영 클라이언트에는 `/etc/ldap/tls/ca.crt`를 신뢰 CA로 배포하십시오. 다음 명령은
클라이언트가 `ldap.bonohbh.com`을 올바른 서버 주소로 해석할 수 있을 때 인증서와
호스트 이름을 모두 검증합니다.

```sh
podman cp openldap-server:/etc/ldap/tls/ca.crt ./ldap-ca.crt
LDAPTLS_CACERT="$PWD/ldap-ca.crt" LDAPTLS_REQCERT=demand ldapwhoami \
  -x -H ldaps://ldap.bonohbh.com:636 \
  -D 'cn=admin,dc=bonohbh,dc=com' -W
```

Compose 헬스체크도 동일한 CA로 `ldaps://openldap:636`을 검증합니다. 운영 환경에서는
`LDAPTLS_REQCERT=never` 같은 검증 완화 옵션을 사용하지 마십시오.

## 비밀번호 변경

관리자 비밀번호도 `cn=config`에서 변경합니다. 먼저 새 SSHA 해시를 생성하십시오.

```sh
podman exec -it openldap-server slappasswd
```

MDB 설정 DN을 조회합니다.

```sh
podman exec openldap-server ldapsearch -LLL -Q \
  -Y EXTERNAL -H ldapi:/// -b cn=config \
  '(&(objectClass=olcMdbConfig)(olcSuffix=dc=bonohbh,dc=com))' dn
```

조회된 DN과 `slappasswd` 출력값으로 `olcRootPW`를 교체합니다. 기본 초기화 결과의
MDB 설정 DN은 `olcDatabase={1}mdb,cn=config`입니다.

```sh
podman exec -i openldap-server ldapmodify -Q \
  -Y EXTERNAL -H ldapi:/// <<'LDIF'
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: {SSHA}<slappasswd-output>
LDIF
```

`user1` 등 일반 사용자의 비밀번호는 `ldappasswd`로 변경합니다.

```sh
podman exec -it openldap-server ldappasswd \
  -x -H ldap://127.0.0.1:389 \
  -D 'cn=admin,dc=bonohbh,dc=com' -W -S \
  'uid=user1,dc=bonohbh,dc=com'
```

## 백업 및 복구

디렉터리 데이터와 동적 설정을 모두 백업합니다.

```sh
mkdir -p backup
podman exec openldap-server sh -c \
  'ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b "$LDAP_BASE_DN"' \
  > backup/ldap-$(date +%F).ldif
podman exec openldap-server ldapsearch -LLL -Q \
  -Y EXTERNAL -H ldapi:/// -b cn=config \
  > backup/ldap-config-$(date +%F).ldif
```

두 LDIF 모두 비밀번호 해시와 운영 정보가 포함될 수 있으므로 백업 파일 접근 권한을
제한하십시오. 복구 전에는 별도 환경에서 LDIF를 검증하고 서비스를 중지한 뒤
수행하는 것을 권장합니다.

## 기존 정적 구성에서 전환

기존 `ldap-data`와 `ldap-tls` 볼륨은 그대로 사용합니다. 새 `ldap-config` 볼륨이
비어 있으면 현재 `.env`를 기준으로 `cn=config`를 한 번 생성하며, 기존
`data.mdb`가 있으면 디렉터리 데이터와 초기 사용자는 다시 만들지 않습니다.

전환 전에 LDAP 데이터 백업을 만들고 다음 명령으로 이미지를 다시 빌드해 컨테이너를
재생성하십시오.

```sh
podman compose up -d --build --force-recreate
podman compose exec openldap ldapsearch -LLL -Q \
  -Y EXTERNAL -H ldapi:/// -b cn=config -s base dn
```

## 중지 및 삭제

```sh
podman compose stop
podman compose start
podman compose down
```

다음 명령은 LDAP DB, 동적 설정, CA 개인키 및 서버 인증서를 포함한 볼륨까지
삭제합니다.

```sh
podman compose down -v
```

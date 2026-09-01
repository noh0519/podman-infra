# Podman OpenLDAP 서버

운영용 OpenLDAP을 Podman Compose로 실행하는 구성입니다.

## 구성

- Base DN: `dc=bonohbh,dc=com`
- 관리자 DN: `cn=admin,dc=bonohbh,dc=com`
- 초기 사용자 DN: `uid=user1,dc=bonohbh,dc=com`
- LDAP/STARTTLS: TCP 389
- LDAPS: TCP 636
- LDAP DB 및 자체 서명 인증서를 Podman 볼륨에 영속화
- 익명 디렉터리 조회 차단
- 관리자 및 사용자 비밀번호는 SSHA 해시로 LDAP DB에 저장

## 환경 설정

실제 비밀번호가 들어 있는 `.env`는 Git에서 제외되며 권한을 `0600`으로 유지합니다.

```sh
cp .env.example .env
chmod 600 .env
```

주요 값은 다음과 같습니다.

- `LDAP_BASE_DN`: 디렉터리 suffix
- `LDAP_ADMIN_DN`, `LDAP_ADMIN_PASSWORD`: 관리자 로그인 정보
- `LDAP_USER_*`: 빈 데이터 볼륨의 첫 기동 때 생성할 사용자 정보
- `LDAP_HOSTNAME`: 자체 서명 인증서의 CN과 SAN

`LDAP_ADMIN_PASSWORD`와 `LDAP_USER_PASSWORD`에는 평문 또는 `slappasswd`로 생성한
`{SSHA}` 값을 사용할 수 있습니다. `{SSHA}` 값을 사용하면 컨테이너는 이를 다시
해싱하지 않고 그대로 OpenLDAP 설정 및 초기 데이터에 적용합니다.

초기 사용자 항목은 LDAP 데이터 볼륨이 비어 있을 때만 생성됩니다. 운영 중 `.env`에서 초기 사용자 값을 바꾸는 것만으로 기존 LDAP 항목은 변경되지 않습니다.

## 실행

```sh
podman compose up -d --build
podman compose ps
podman compose logs -f openldap
```

## 연결 확인

자체 서명 인증서이므로 테스트할 때 CA 검증을 명시적으로 완화할 수 있습니다.

```sh
LDAPTLS_REQCERT=never ldapwhoami \
  -x -H ldaps://127.0.0.1:636 \
  -D 'cn=admin,dc=bonohbh,dc=com' -W
```

운영 클라이언트에는 컨테이너의 `/etc/ldap/tls/ca.crt`를 신뢰 CA로 배포하고 검증 완화 옵션을 사용하지 마십시오.

## 비밀번호 변경

관리자 비밀번호는 `slapd.conf`를 기동 때 다시 생성하므로 `.env` 변경 후 컨테이너를 재생성하면 적용됩니다.

```sh
podman compose up -d --force-recreate
```

`user1` 등 일반 사용자의 비밀번호는 `ldappasswd`로 변경합니다.

```sh
podman exec -it openldap-server ldappasswd \
  -x -H ldap://127.0.0.1:389 \
  -D 'cn=admin,dc=bonohbh,dc=com' -W -S \
  'uid=user1,dc=bonohbh,dc=com'
```

## 백업 및 복구

일관된 온라인 백업은 관리자 인증을 사용한 LDIF 내보내기로 수행합니다.

```sh
mkdir -p backup
podman exec openldap-server sh -c \
  'ldapsearch -LLL -x -H ldap://127.0.0.1:389 -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" -b "$LDAP_BASE_DN"' \
  > backup/ldap-$(date +%F).ldif
```

LDIF에는 비밀번호 해시와 개인정보가 포함되므로 백업 파일 접근 권한을 제한하십시오. 복구 전에는 별도 환경에서 LDIF를 검증하고 서비스를 중지한 뒤 수행하는 것을 권장합니다.

## 중지 및 삭제

```sh
podman compose stop
podman compose start
podman compose down
```

다음 명령은 LDAP DB와 자체 서명 인증서를 포함한 볼륨까지 삭제합니다.

```sh
podman compose down -v
```

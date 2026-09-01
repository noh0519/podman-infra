# Podman Postfix·Dovecot 메일 서버

## 구성 개요

- Podman 기반 Postfix SMTP 및 Dovecot IMAP 서버
- 지정 도메인 및 수신자만 허용
- 인증되지 않은 외부 릴레이 차단
- Maildir 방식 메일 저장
- Podman 볼륨을 이용한 메일 영속화
- TLS 및 외부 SMTP 릴레이 선택 지원

## 제공 범위

- SMTP 메일 수신 및 발신
- IMAP/IMAPS 메일 열람
- SMTP 587 사용자 인증
- 수신자 존재 여부 검사
- 가상 도메인 및 가상 메일함
- 메일 주소 별칭
- 컨테이너 상태 검사
- 표준 출력 기반 Postfix 로그

## 미제공 기능

- POP3 메일 열람
- DKIM 서명
- 스팸 및 바이러스 검사
- 웹메일
- 필요 시 Rspamd 또는 OpenDKIM 별도 연동

## 사전 준비

- Podman 설치
- Compose provider 설치
  - `podman-compose` 또는 Docker Compose
- 서버 TCP 25, 143, 587, 993 포트 개방
- 기존 SMTP 데몬의 25 포트 사용 여부 확인
- 클라우드 또는 ISP의 outbound TCP 25 차단 여부 확인
- 차단 환경에서는 외부 SMTP 릴레이 사용

## DNS 설정

- `mail.bonohbh.com` A/AAAA 레코드
  - 서버 공인 IP 지정
- 서버 IP PTR 레코드
  - `mail.bonohbh.com` 지정
- `mail.bonohbh.com` MX 레코드
  - `mail.bonohbh.com` 지정
- 정방향 DNS와 역방향 DNS의 호스트명 일치 권장

## 환경 설정

```sh
cd /root/podman-infra/postfix-podman
cp .env.example .env
chmod 600 .env
```

`.env` 주요 항목:

- `MAIL_HOSTNAME`
  - 공개 SMTP 호스트명
  - 예: `mail.bonohbh.com`
- `MAIL_DOMAINS`
  - 수신할 도메인 목록
  - 공백으로 구분
- `MAILBOXES`
  - 실제 수신할 전체 메일 주소 목록
  - 공백으로 구분
- `MAIL_ALIASES`
  - `원본주소=목적지주소` 형식의 별칭
  - 공백으로 구분
- `MYNETWORKS`
  - 릴레이를 허용할 신뢰 네트워크
  - 외부 전체 대역 지정 금지
- `MESSAGE_SIZE_LIMIT`
  - 최대 메시지 크기
  - 바이트 단위
- `RELAYHOST`
  - 선택 사항
  - 외부 SMTP 릴레이 주소
- `RELAY_USERNAME`, `RELAY_PASSWORD`
  - 외부 SMTP 릴레이 인증 정보

## 메일 로그인 계정

- `.env`에 평문 대신 SHA512-CRYPT 해시 저장
- 계정 주소를 `MAILBOXES`에도 등록
- 비밀번호 해시 생성

```sh
openssl passwd -6
```

- 프롬프트에서 비밀번호 및 확인값 입력
- 출력되는 `$6$...` 전체 문자열 복사
- `.env`의 `MAIL_USERS`에 `{SHA512-CRYPT}` 접두사와 함께 입력
- 해시의 `$`를 Compose가 해석하지 않도록 전체 값에 작은따옴표 사용

```env
MAIL_USERS='admin@mail.bonohbh.com={SHA512-CRYPT}$6$...'
```

- 여러 계정은 작은따옴표 안에서 공백으로 구분

```env
MAIL_USERS='admin@mail.bonohbh.com={SHA512-CRYPT}$6$... user@mail.bonohbh.com={SHA512-CRYPT}$6$...'
```

- 원래 비밀번호에 공백 및 특수문자 사용 가능
- 해시는 비밀번호와 동일한 민감정보로 취급
- `.env` 권한 `0600` 유지

## TLS 인증서

- 인증서 배치 경로

```text
tls/fullchain.pem
tls/privkey.pem
```

- 인증서 존재 시 SMTP STARTTLS 및 IMAPS 활성화
- 인증서 미존재 시 SMTP 25와 IMAP 143만 실행
- 인증서 미존재 시 외부 IMAP 로그인 및 SMTP 587 인증 사용 불가
- Let's Encrypt 직접 사용 시 `compose.yaml`의 TLS 볼륨 경로 변경
- 컨테이너에 인증서 읽기 권한 부여
- 인증서 갱신 후 컨테이너 재시작

```sh
podman compose restart postfix
```

## Podman Compose 컨테이너 제어

- 모든 명령은 `compose.yaml`이 있는 프로젝트 디렉터리에서 실행

```sh
cd /root/podman-infra/postfix-podman
```

- 이미지가 없으면 빌드 후 컨테이너 생성 및 실행
- 이미지가 있으면 기존 이미지 사용

```sh
podman compose up -d
```

- 실행 중인 컨테이너 중지
- 컨테이너와 메일 볼륨 유지

```sh
podman compose stop
```

- 중지된 컨테이너 시작

```sh
podman compose start
```

- 실행 중인 컨테이너 재시작

```sh
podman compose restart
```

- `.env` 변경 후 컨테이너 재생성
- 기존 이미지 사용

```sh
podman compose up -d --force-recreate
```

- `Containerfile` 또는 컨테이너 내부 파일 변경 후 이미지 재빌드 및 실행

```sh
podman compose up -d --build --force-recreate
```

- 이미지만 재빌드

```sh
podman compose build
```

- 상태 확인

```sh
podman compose ps
```

- 로그 실시간 확인

```sh
podman compose logs -f postfix
```

- 컨테이너와 Compose 네트워크 제거
- 이미지와 메일 볼륨 유지

```sh
podman compose down
```

- 컨테이너, Compose 네트워크 및 메일 볼륨 제거

```sh
podman compose down -v
```

- `down -v` 실행 시 저장된 모든 메일 삭제
- 필요한 메일 백업 후 실행

## SMTP 연결 확인

- TLS 인증서가 설정된 경우

```sh
openssl s_client \
  -starttls smtp \
  -connect 127.0.0.1:25 \
  -servername mail.bonohbh.com
```

- 확인 항목
  - SMTP 배너의 호스트명
  - `STARTTLS` 기능 표시
  - 인증서 도메인 및 만료일
  - SMTP 응답 오류 여부

## 메일 클라이언트 설정

- 사용자 이름
  - `MAIL_USERS`에 등록한 전체 메일 주소
- 비밀번호
  - 해시 생성에 사용한 원래 비밀번호
- 받는 메일
  - 프로토콜: IMAP
  - 서버: `MAIL_HOSTNAME` 값
  - 포트: 993
  - 보안: SSL/TLS
- 보내는 메일
  - 프로토콜: SMTP
  - 서버: `MAIL_HOSTNAME` 값
  - 포트: 587
  - 보안: STARTTLS
  - 인증: 필수
- 운영 환경
  - TLS 인증서 설치 필수
- 평문 IMAP 143 포트
  - STARTTLS 협상 가능
  - TLS 없는 원격 비밀번호 인증 차단

## 저장 메일 및 큐 확인

- 수신 메일 파일

```sh
podman exec postfix-mail find /var/mail/vhosts -type f
```

- 발송 대기 큐

```sh
podman exec postfix-mail postqueue -p
```

- 메일 저장 구조

```text
/var/mail/vhosts/<domain>/<localpart>/Maildir/
```

## 발신 인증 DNS

- SPF
  - 발신 서버 허용 범위 지정
  - 예: `mail.bonohbh.com TXT "v=spf1 mx -all"`
- DKIM
  - 현재 구성에 서명기 미포함
  - Rspamd 또는 OpenDKIM 연동
  - 공개키 DNS 게시
- DMARC
  - SPF/DKIM 검증 실패 정책 지정
  - 예: `_dmarc.mail.bonohbh.com TXT "v=DMARC1; p=quarantine; rua=mailto:dmarc@mail.bonohbh.com"`
- 외부 SMTP 릴레이 사용 시
  - 릴레이 사업자의 SPF/DKIM 지침 우선 적용

## 보안 주의사항

- `MYNETWORKS`에 신뢰하는 내부 IP만 등록
- `0.0.0.0/0` 등록 금지
  - 오픈 릴레이 발생 위험
- `MAILBOXES`에 없는 주소는 SMTP 단계에서 거부
- 별칭 목적지 주소의 `MAILBOXES` 등록 권장
- `.env` 파일의 외부 공개 및 버전 관리 금지
- 운영 환경에서 TLS 사용 권장
- DKIM 및 DMARC 구성 권장
- 방화벽, 로그 순환, 모니터링 별도 구성
- `mail-data` 볼륨 정기 백업

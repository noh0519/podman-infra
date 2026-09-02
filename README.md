# Podman Infra

- Podman 기반 인프라 서비스 구성 저장소
- 서비스별 독립 디렉토리와 `compose.yaml` 사용
- IPv4·IPv6 dual-stack 네트워크 구성
- 컨테이너 데이터는 Podman volume에 영구 보관

## 서비스

- `openldap-podman`: LDAP 디렉토리 서비스
- `postfix-podman`: SMTP·IMAP 메일 서비스

## 운영

- 각 서비스 디렉토리에서 `podman compose` 명령 실행
- 환경별 설정과 인증 정보는 `.env`로 관리
- 서비스 추가 시 별도 하위 디렉토리로 구성

# LOG000 — 프로젝트 셋업

## 배경 / 목표

쿼리 성능 학습 프로젝트(Olist 이커머스 스키마 기반)에 들어가기 전, 패키지 구조 / 빌드 설정 /
로컬 개발 DB 환경을 정리한다. Phase 1(EXPLAIN ANALYZE) 실습을 시작하기 위한 기반 다지기 단계.

## 진행 내용

### 1. 패키지 구조

hexagonal 기본 컨셉은 유지하되 불필요한 depth는 만들지 않는 것으로 결정.

```
io.hkarling.practice
├── Application.java
├── domain    # 엔티티, 핵심 비즈니스 규칙 (아직 없음, 다음 단계)
├── app       # 유스케이스, 서비스
└── infra
    └── repository
```

- domain 밑에 애그리게잇별 서브패키지를 나누지 않고 flat하게 시작 — 테이블 8개, 복잡한 비즈니스
  규칙이 없는 단계에서 미리 나누는 건 불필요한 depth로 판단.
- port/adapter 인터페이스, `common` 패키지는 도입하지 않음 — 실제로 필요해질 때 추가.

### 2. build.gradle

Spring Initializr가 생성한 기본 의존성(`data-jpa`, `webmvc`, `postgresql` driver, `testcontainers`
계열)으로 Phase 1은 충분히 커버되어 이 단계에서는 변경하지 않음. 유일하게 추가한 것은
docker compose 자동 기동을 위한 `developmentOnly 'org.springframework.boot:spring-boot-docker-compose'`.

QueryDSL은 Phase 2(챕터 8)에서 추가 예정이라 지금은 넣지 않음.

### 3. 로컬 Postgres — docker compose

`spring-boot-docker-compose` 모듈을 이용해 `bootRun` 시점에 `compose.yaml`을 자동 감지 →
컨테이너 기동 → `ConnectionDetails` 자동 구성(=`spring.datasource.*`를 직접 안 써도 됨) 흐름으로 구성.

`DB 환경 전략`상 로컬 Postgres는 "고정" — 100만~1500만 row급 시드를 한 번만 적재하고 계속
재사용해야 하므로:
- named volume(`postgres-data`)으로 데이터 영속화
- `spring.docker.compose.lifecycle-management: start-only`로 앱이 꺼져도 컨테이너는 유지
  (기본값인 `start-and-stop`이면 앱 종료 시 컨테이너가 stop되어 매번 시드를 다시 넣어야 함)

## 시행착오 / Q&A

**Q. 여러 프로젝트(다른 디렉터리)가 Postgres 컨테이너 하나를 공유할 수 있을까?**

`compose.yaml`에 `container_name: practice-postgres`를 고정해서 다른 practice 프로젝트에서도
같은 이름으로 붙게 시도했으나 "이름이 안 먹는다"는 증상 발생.

원인: Docker Compose는 컨테이너 소유권을 **compose project 단위**(기본값 = 디렉터리명)로 관리한다.
`container_name`은 Docker 데몬 전역에서 유일해야 하는데, 다른 디렉터리에서 같은 compose.yaml을
띄우면 그 프로젝트는 자기 project 이름(다른 디렉터리명) 기준으로 "내 소유의 컨테이너가 없다"고
판단해 새로 만들려다 이미 다른 프로젝트가 그 이름을 선점하고 있어 충돌한다.

해결 방향은 두 가지였음:
1. 한 프로젝트만 compose로 컨테이너를 소유/관리하고, 나머지 프로젝트는 `spring-boot-docker-compose`
   없이 `application.yaml`에 `localhost:15432` 같은 접속 정보만 넣어 기존 DB에 붙는 방식
2. 모든 compose.yaml에 동일한 top-level `name:`을 줘서 같은 compose project로 인식시키는 방식
   (다만 프로젝트마다 compose 설정이 조금이라도 다르면 `up` 시점에 재생성/충돌 위험이 남음)

→ 컨테이너는 기동 시점에만 리소스를 먹기 때문에 공유의 이점이 크지 않다고 판단, **공유하지 않고
프로젝트별 독립 컨테이너**로 최종 결정. `container_name` 제거, 포트도 다시 기본값(`5432:5432`)으로
되돌림.

## 최종 구성

**compose.yaml**
```yaml
services:
  postgres:
    image: postgres:17
    environment:
      POSTGRES_DB: practice_db_performance
      POSTGRES_USER: practice
      POSTGRES_PASSWORD: practice
    ports:
      - "5432:5432"
    volumes:
      - postgres-data:/var/lib/postgresql/data

volumes:
  postgres-data:
```

**application.yaml**
```yaml
spring:
  application:
    name: practice-db-performance
  docker:
    compose:
      lifecycle-management: start-only
  jpa:
    hibernate:
      ddl-auto: validate
    open-in-view: false
    show-sql: true
    properties:
      hibernate:
        format_sql: true
```

**build.gradle (변경분만)**
```groovy
developmentOnly 'org.springframework.boot:spring-boot-docker-compose'
```

`./gradlew bootRun`으로 로컬 Postgres 자동 기동 + 앱 정상 기동 확인 완료.

## ADR

### Decision
1. 패키지 구조: `domain` / `app` / `infra` 3분할, port/adapter 없음, flat entity 배치
2. 스키마 관리: SQL DDL 스크립트(`db/schema.sql`)가 소유, Hibernate는 `ddl-auto: validate`로
   매핑만 검증 (엔티티가 스키마를 생성/변경하지 않음)
3. 로컬 DB: docker compose 기반, **프로젝트별 독립 컨테이너**(공유 안 함), named volume으로
   영속화, `lifecycle-management: start-only`

### Drivers
- 인덱스 추가/삭제, 파티셔닝 같은 실습을 SQL로 자유롭게 다뤄야 하는데 Hibernate가 스키마를
  소유하면(`update`/`create`) 실습 중 의도치 않은 스키마 변경이 섞일 위험이 있음
- 100만~1500만 row 시드는 한 번만 적재해서 계속 재사용해야 함 — 컨테이너/데이터가 재기동마다
  초기화되면 안 됨
- Windows 로컬 환경에서 Postgres를 네이티브로 설치하는 것보다 docker compose가 재현성이 좋고
  프로젝트 삭제 시 정리도 깔끔함

### Alternatives considered
- **Hibernate `ddl-auto: update`**: 기각. 엔티티가 source of truth가 되면 인덱스/파티셔닝 실습과
  충돌하고, 의도치 않은 스키마 변경이 섞일 수 있음
- **여러 프로젝트가 Postgres 컨테이너 하나를 공유**: 기각. Docker Compose의 project 스코프 때문에
  `container_name` 통일만으로는 안 되고(위 Q&A 참고), 별도 설정(top-level `name:` 통일 등)이
  필요한데 그 복잡도 대비 리소스 절감 효과가 작다고 판단
- **Flyway/Liquibase 마이그레이션 도구**: 도입 안 함. 이 프로젝트 규모(개인 학습용, 스키마 변경
  빈도 낮음)에서는 오버엔지니어링

### Consequences
- 스키마 변경 시 마이그레이션 도구 없이 `db/schema.sql`을 수동으로 재적용해야 함 (버전 이력 관리 없음)
- 프로젝트마다 별도 Postgres 컨테이너가 뜨므로 로컬 리소스(메모리)를 프로젝트 수만큼 씀 —
  다만 상시 부담이 아니라 기동 시점 부담이라 수용 가능하다고 판단
- Testcontainers(테스트용, ephemeral)와 docker compose(개발용, persistent) 두 개의 Postgres
  파이프라인이 공존 — 역할이 명확히 분리되어 있어 혼동 소지는 적음

### Follow-ups
- 엔티티 + `db/schema.sql` 작성 (다음 단계, LOG001 예정)
- 시드 데이터 생성기(`seed/`, Python + Faker) 작성

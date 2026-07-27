# 지식 계층 — 무엇을 어디서 얻는가

이 프로젝트의 지식은 두 계층으로 나뉜다. **어느 계층에 물어야 하는지 먼저 판단하고 움직인다.**
잘못된 계층에 물으면 낡은 답을 얻거나, 얻을 수 없는 답을 지어내게 된다.

| | 구조 (Structure) | 의미 (Semantics) |
|---|---|---|
| 질문 | 어디에 있나 / 무엇이 부르나 / 바꾸면 어디가 깨지나 | 무슨 뜻인가 / 왜 이런가 / 언제 전이하나 |
| 출처 | **codegraph** (실시간 인덱스) | **DOMAIN.md** (사람이 쓴 문서) |
| 갱신 | 파일 저장 시 자동 (증분 수백 ms) | 사람·에이전트가 직접, 게이트가 강제 |
| 신뢰도 | 코드가 곧 진실 | 문서가 낡았을 수 있음 → 신선도 경고 확인 |

## 구조 질문 → codegraph

파일을 훑어서 구조를 재구성하지 마라. 한 번에 물어보면 된다.

```bash
codegraph explore "<자연어 질문>"   # 관련 심볼 + 소스 + 호출 경로 + 영향 범위
codegraph node <심볼>               # 한 심볼의 소스와 호출 관계
codegraph callers <심볼>            # 누가 호출하나
codegraph callees <심볼>            # 무엇을 호출하나
codegraph impact <심볼>             # 이걸 바꾸면 어디가 영향받나
codegraph affected <파일...>        # 이 파일이 바뀌면 어떤 테스트가 영향받나
codegraph query <검색어>            # 심볼 이름 검색
```

MCP 도구 `codegraph_explore` 로도 같은 결과를 얻는다.

**codegraph가 없으면** Grep/Read로 폴백한다. 하네스는 codegraph 없이도 동작한다.
`codegraph --version` 이 실패하면 폴백 경로다.

## 의미 질문 → DOMAIN.md

루트 `DOMAIN.md` 와 각 도메인의 `{app}/DOMAIN.md` 를 읽는다.
여기에만 있는 것:

- 상태값·Choices가 **각각 무슨 뜻이고 언제 전이하는가**
- 시그널·훅이 **무슨 부수효과를 내는가**
- 도메인 용어와 팀 내부 슬랭
- 여러 모듈에 흩어진 비즈니스 규칙
- 과거 사고 지점 (변경 시 주의사항)

## codegraph가 못 보는 것 — 실측 확인됨

측정 대상: Django 레포 2,741파일 / 33,483노드 / 90,903엣지 (2026-07-27)

| 항목 | codegraph 결과 | 대응 |
|------|---------------|------|
| 모델 필드 선언 (`ForeignKey` 등) | 심볼로 취급 안 함 — **0건** | 소스를 직접 읽는다 |
| `Meta.db_table` 문자열 | FTS 검색 불가 — **0건** | DOMAIN.md의 테이블 매핑 표 |
| `@receiver(post_save, ...)` 배선 | 호출 그래프에 엣지 없음 — **0건** | DOMAIN.md의 시그널 표 |

세 번째가 가장 위험하다. `MatchApply.save()` 를 호출하면 `add_matchapply` 핸들러가
따라 실행되어 정원·프로모션·소진 시각을 바꾸지만, **codegraph의 영향 범위 분석에는
그 연결이 전혀 나타나지 않는다.** 모델을 건드릴 때는 codegraph의 `impact` 결과만 믿지 말고
DOMAIN.md의 시그널 표를 반드시 함께 확인한다.

## 자동 가드레일

개발자가 신경 쓰지 않아도 돌아가도록 세 지점에 게이트가 걸려 있다.

| 시점 | 장치 | 동작 |
|------|------|------|
| 세션 시작 | `session-knowledge.sh` | codegraph 인덱스 동기화 + 낡은 DOMAIN.md 경고 주입 |
| 파일 편집 직후 | `domain-guard.sh` | 의미 변화 감지 시 exit 2 로 갱신 지시 |
| 커밋 직전 | `domain-gate` (pre-commit) | DOMAIN.md 미갱신이면 커밋 차단 |

감지 대상은 **의미가 실제로 바뀐 경우로 한정**된다. AST 지문을 변경 전후로 비교하므로
주석 추가나 리팩토링에는 발화하지 않는다. 발화했다면 진짜 바뀐 것이다.

게이트가 `domain-gate: ... 로딩 실패` 로 커밋을 막으면 도메인 위반이 아니라
**판정기 자체가 고장난 것**이다. `.claude/scripts/` 에 `domain-extract.py` 와
`domain-gate.py` 가 함께 있는지 확인한다. 우회하지 말고 고쳐야 한다. 판정기가 죽은 채로
넘기면 의미 변화가 조용히 통과한다.

```bash
# 지금 무엇이 걸리는지 직접 확인
python3 .claude/scripts/domain-gate.py --staged

# 스켈레톤 다시 뽑아보기 (참고용 출력, 문서를 덮어쓰지 않음)
python3 .claude/scripts/domain-extract.py . --app <앱경로> --format md

# 문서 신선도 점검
python3 .claude/scripts/domain-freshness.py .
```

## 게이트 우회

`git commit --no-verify` 로 넘길 수 있지만 **표면화 대상**이다.
우회했으면 PR 설명에 사유를 남긴다. 게이트를 조용히 낮추는 것은 해결이 아니다.

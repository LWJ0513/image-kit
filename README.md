# image

Ubuntu 에서 SD 카드 마스터를 `.img` 로 덤프하고, 여러 USB 카드리더에 동시에 굽고, 검증하는 bash 스크립트.

검증 환경: Ubuntu 22.04. bash 4 이상, GNU coreutils/diffutils, util-linux, mbuffer R2021 이상 필요

```
image/
├── dump.sh        # 마스터 카드 -> .img + .md5
├── burn.sh        # .img -> 여러 장치 동시 굽기 + 검증
├── dd_burn.sh     # .img -> 여러 장치 독립 굽기 + 검증
├── verify.sh      # 이미 구운 장치 검수만
├── *.img          # 이미지 (git 제외)
└── *.img.md5      # md5sum 형식 해시 (git 포함)
```

<br>

## 사전 준비

```bash
# dump.sh, burn.sh 용. 없으면 스크립트가 자동 설치 시도
sudo apt install mbuffer

# 대상 장치 확인. TRAN 이 usb 인 것만 대상
lsblk -o NAME,SIZE,TRAN,MODEL,SERIAL,MOUNTPOINTS | grep -v loop
```

- USB 카드리더 전용. 내장 SD 슬롯(`mmcblk0`), WSL2, 컨테이너는 장치 검사에서 거부됨
- 모든 스크립트 sudo 필요, `-h` 로 사용법 출력
- 장치는 `sda`, `/dev/sda` 둘 다 가능
- 카드 용량 >= 이미지 크기

<br>

## 1. dump.sh

이미지 파일 `.img` 와 `.md5` 를 만드는 스크립트

```bash
sudo ./dump.sh [-n] [-f] <장치> [출력.img]

sudo ./dump.sh sdb my_image.img
sudo ./dump.sh sdb                          # 출력 이름 생략 시 sbc_<날짜>.img
```

| 옵션                    | 내용                                                       |
| ----------------------- | ---------------------------------------------------------- |
| (기본)                  | 쓰기 검증. 저장한`.img` 를 디스크에서 다시 읽어 MD5 대조 |
| `-n`, `--no-verify` | 쓰기 검증 생략                                             |
| `-f`, `--force`     | 기존 출력 파일 덮어씀                                      |

출력 예:

```
  [ 34%] 20.3GiB / 59.5GiB · 41MiB/s · 남은 시간 약 16분 12초

════════════════ Dumping 완료 ════════════════

  소요 시간 : 24분 10초  (읽기 23분 50초 + sync 20초)
  평균 속도 : 42MiB/s
  이미지    : my_image.img (60GiB)
  CRC32     : ...
  MD5       : 96f262f691cc57f3c05505b8a7b00844
  MD5 파일  : my_image.img.md5
```

결과:

- `<출력>.img`, `<출력>.img.md5` 생성 (sudo 실행한 사용자 소유)
- `.md5` 는 `md5sum -c <출력>.img.md5` 로 바로 검사 가능

<br>

## 2. burn.sh

이미지를 여러 장치에 동시에 굽고 검증하는 스크립트

- `mbuffer` 하나가 모든 장치에 같이 쓰므로 전체가 가장 느린 카드 속도로 진행
- 카드 속도가 비슷할 때 사용

```bash
sudo ./burn.sh [-q|-f|-n] <이미지> <장치...>

sudo ./burn.sh my_image.img sda sdb sdc sdd sde sdf
```

| 옵션                       | 내용                      |
| -------------------------- | ------------------------- |
| `-q`, `--quick` (기본) | 샘플 검증 1.5GiB. 수십 초 |
| `-f`, `--full`         | 이미지 전체 비교. 수십 분 |
| `-n`, `--no-verify`    | 검증 생략                 |

- 여유 RAM 2GB 필요 (`mbuffer -m 2G`)
- 굽기 후 `sync 중...` 에서 수십 초 이상 멈출 수 있음. 정상, Ctrl-C 금지

출력 예:

```
════════════════ Flashing — 6개 동시 ════════════════

in @ 10.5 MiB/s, out @ 10.5 MiB/s, 20.3 GiB total, buffer  90% full, 34% done

  sync 중...

════════════════ Flashing 완료 ════════════════

  소요 시간 : 1시간 41분 20초  (쓰기 1시간 40분 50초 + sync 30초)
  평균 속도 : 10MiB/s (장치당) · 60MiB/s (합계)

════════════════ 검증 중 — quick, 장치당 1.5GiB (66구간), 6개 병렬 ════════════════

    sda    PASS
    sdb    PASS
    sdc    PASS
    sdd    PASS
    sde    PASS
    sdf    PASS

  검증 소요 : 52초
  결과      : PASS 6개 / FAIL 0개

  전체 통과 — 6개 모두 이미지와 일치합니다.
```

<br>

## 3. dd_burn.sh

이미지를 여러 장치에 동시에 굽고 검증하는 스크립트

- 카드마다 자기 속도로 굽고, 굽기가 끝난 장치부터 바로 검증
- 속도가 다른 카드(다른 lot)가 섞여 있을 때 사용
- 전체 완료 시간은 `burn.sh` 와 동일 (가장 느린 카드가 정함).
- PASS 뜬 카드를 먼저 뽑을 수 있음

```bash
sudo ./dd_burn.sh [-q|-f|-n] <이미지> <장치...>

sudo ./dd_burn.sh my_image.img sda sdb sdc sdd sde sdf
```

| 옵션                       | 내용             |
| -------------------------- | ---------------- |
| `-q`, `--quick` (기본) | 샘플 검증 1.5GiB |
| `-f`, `--full`         | 이미지 전체 비교 |
| `-n`, `--no-verify`    | 검증 생략        |

출력 예 (진행 중):

```
════════════════ Flashing — 6개 독립 실행 ════════════════

    sda    USB포트 6.4.3    굽는 중  34%  20.3GiB / 60.0GiB  10.5MiB/s  남은 1시간 4분 12초
    sdb    USB포트 6.4.2    굽는 중  41%  24.6GiB / 60.0GiB  12.7MiB/s  남은 47분 30초
    sdc    USB포트 6.4.4    굽는 중  33%  19.8GiB / 60.0GiB  10.3MiB/s  남은 1시간 6분 5초
    sdd    USB포트 5        검증 중  45%  (quick)
    sde    USB포트 6.4.1    PASS  1시간 12분 40초
    sdf    USB포트 6.3      PASS  1시간 11분 58초
```

출력 예 (완료):

```
════════════════ 결과 ════════════════

    sda    쓰기 1시간 40분 50초  평균 10.1MiB/s
    sdb    쓰기 1시간 20분 12초  평균 12.7MiB/s
    sdc    쓰기 1시간 42분 3초  평균 10.0MiB/s
    sdd    쓰기 1시간 11분 25초  평균 14.3MiB/s
    sde    쓰기 1시간 11분 50초  평균 14.2MiB/s
    sdf    쓰기 1시간 11분 8초  평균 14.4MiB/s

  전체 소요 : 1시간 43분 10초
  결과      : PASS 6개 / FAIL 0개

  전체 통과 — 6개 모두 완료.
```

<br>

## 4. verify.sh

이미 구운 장치가 이미지와 같은지 대조하는 스크립트

```bash
sudo ./verify.sh [-q|-f] <이미지> <장치...>

sudo ./verify.sh my_image.img sda sdb sdc
sudo ./verify.sh -f my_image.img sda      # 납품 전 전체 검수
```

| 옵션                       | 내용                      |
| -------------------------- | ------------------------- |
| `-q`, `--quick` (기본) | 샘플 검증 1.5GiB. 수십 초 |
| `-f`, `--full`         | 이미지 전체 비교. 수십 분 |

- 사용처: `burn.sh -n` 으로 굽고 나중에 몰아서 검수, 회수한 카드 확인, quick 통과분 납품 전 `-f` 재검수
- 시스템 디스크, USB 여부는 검사하지 않음. 장치 이름 직접 확인할 것

출력 예 (불일치 1장 포함):

```
════════════════ 검증 중 — quick, 장치당 1.5GiB (66구간), 3개 병렬 ════════════════

    sda    PASS
    sdb    PASS
    sdc    FAIL  ← 이미지와 다릅니다

  검증 소요 : 48초
  결과      : PASS 2개 / FAIL 1개
  불일치    : sdc

  검증 실패 — 위 장치는 다시 flashing 해야 합니다.
```

### quick 검증 범위

`burn.sh`, `dd_burn.sh`, `verify.sh` 공통. 앞 256MiB + 뒤 256MiB + 중간 16MiB x 64개 = 1.5GiB (60GiB 이미지의 약 2.5%).

- 잡는 것: 장치 오지정, 이미지 절단, 죽은 카드, 쓰기 실패
- 놓치는 것: 표본 밖 산발적 불량 섹터. 납품 전 최종 검수, 새 카드 lot 첫 사용 시 `-f`

<br>

## 관련 명령어

### 허브 구조

```bash
lsusb -t
```

- 들여쓰기 = 허브 단계. 같은 허브 아래 장치들은 그 허브의 대역을 나눠 씀
- 장치당 속도는 나오는데 합계가 안 오르면 루트 허브 직결 포트로 분산
- `480M` 버스에 꽂힌 장치는 전부 USB 2.0 속도

### 느린 카드 찾기

```bash
# 굽는 중 다른 터미널에서 실행 (sysstat 패키지)
iostat -dx sda sdb sdc sdd sde sdf 2
```

- 보는 값: `wkB/s`(쓰기 속도), `%util`(장치 사용률)
- 전 장치 `wkB/s` 가 같고 일부만 `%util` 90% 이상이면 그 장치가 느린 카드
- 2026-10-13 실측: 6장 모두 약 10.5MB/s, sda/sdc 만 `%util` 90% 이상 (나머지 25%). sda/sdc 만 용량이 `63998787584` 바이트로 다른 lot

### 장치 이름, 포트, 링크 속도 대조

`sdX` 이름은 인식 순서대로 붙어서 카드를 바꿔 끼우면 달라진다. 굽기 전에 포트와 대조 필요

```bash
for d in /sys/block/sd*; do
  n=${d##*/}
  p=$(readlink -f "$d/device" 2>/dev/null) || continue
  while [ -n "$p" ] && [ "$p" != / ] && [ ! -e "$p/speed" ]; do p=$(dirname "$p"); done
  [ -e "$p/speed" ] || { printf '%-5s  (USB 아님)\n' "$n"; continue; }
  bypath=""
  for l in /dev/disk/by-path/*-usb-*; do
    [ -e "$l" ] || continue
    if [ "$(readlink -f "$l")" = "/dev/$n" ]; then bypath=${l##*/}; break; fi
  done
  printf '%-5s %8s  %-20s %6s Mb/s  %-6s %s\n' \
    "$n" "$(lsblk -dno SIZE /dev/$n 2>/dev/null | tr -d ' ')" \
    "$(tr -d '\n' < "$p/product" 2>/dev/null)" \
    "$(cat "$p/speed" 2>/dev/null)" \
    "$(echo "$p" | grep -o 'usb[0-9]*' | head -1)" \
    "$(printf '%s' "$bypath" | sed -n 's/.*-usb-0:\([0-9.]*\):.*/포트 \1/p')"
done
```

```
sda      59.5G  USB3.0 Card Reader      480 Mb/s  usb1   포트 6.4.3
sdb      59.5G  USB3.0 Card Reader     5000 Mb/s  usb2   포트 6.4.2
sdc      59.5G  USB3.0 Card Reader     5000 Mb/s  usb2   포트 6.4.4
sdd      59.5G  USB3.0 Card Reader     5000 Mb/s  usb2   포트 5
```

| 링크 속도 | 규격               | 판단                            |
| --------- | ------------------ | ------------------------------- |
| `480`   | USB 2.0            | 잘못 꽂힘. 링크가 카드보다 느림 |
| `5000`  | USB 3.0 / 3.1 Gen1 | 정상                            |
| `10000` | USB 3.1 Gen2       | 정상                            |

<br>

## 주의 사항

- `burn.sh`, `dd_burn.sh` 는 되돌릴 수 없음. 확인 화면의 장치, 크기, 모델, 포트 대조 후 `Y`
- 굽는 중 다른 USB 저장장치 연결 금지. `sdX` 이름이 밀림
- `dump.sh`, `burn.sh`, `verify.sh` 는 시스템 전체 page cache 를 비움 (`drop_caches`). 같은 장비의 다른 작업이 잠깐 느려짐

#!/usr/bin/env bash
#
# dump.sh - 마스터 카드를 읽어 .img 파일과 .md5 를 만든다. (카드에 쓰지 않음)
#
#   sudo ./dump.sh [옵션] <장치> [출력.img]
#
#   sudo ./dump.sh sdb OPi5Plus_dxas2.3.0_sbc1.0.img
#   sudo ./dump.sh -n sdb OPi5Plus_dxas2.3.0_sbc1.0.img
#   sudo ./dump.sh sdb                       # 출력 이름 생략 시 sbc_<날짜>.img
#
# 읽는 김에 CRC32 와 MD5 를 같이 계산하므로 md5sum 을 따로 돌리지 않아도 된다.
# <출력.img>.md5 는 md5sum 형식이라 `md5sum -c` 로 바로 검사할 수 있다.
#
# 옵션:
#   (기본)               쓰기 검증 수행. sync 후 캐시를 비우고 .img 를 디스크에서
#                        다시 읽어, 카드에서 읽은 MD5 와 같은지 확인한다.
#                        이미지 크기만큼 한 번 더 읽으므로 수 분 더 걸린다.
#          -n, --no-verify  쓰기 검증 생략. 읽으면서 계산한 MD5 를 그대로 신뢰한다.
#          -f, --force   출력 파일이 이미 있어도 덮어쓴다.
#
set -euo pipefail

BUF=1G              ## mbuffer 버퍼 크기
PROGRESS_INTERVAL=60 ## 진행률 한 줄을 남기는 주기(초)

## --- 화면 표시 ---
## 터미널일 때만 색을 쓴다 (파이프/로그로 넘길 때는 제어문자 없이)
if [ -t 1 ]; then
	B=$'\033[1m' R=$'\033[1;31m' G=$'\033[1;32m' Y=$'\033[1;33m' N=$'\033[0m'
else
	B='' R='' G='' Y='' N=''
fi

## 단계 구분선. 앞뒤로 빈 줄을 넣어 출력이 뭉치지 않게 한다.
section() {
	echo
	echo "${B}════════════════ $1 ════════════════${N}"
	echo
}

## 초 -> "3분 21초" 처럼 읽기 쉬운 형태로
fmt_dur() {
	local s=$1
	if [ "$s" -ge 3600 ]; then
		printf '%d시간 %d분 %d초' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
	elif [ "$s" -ge 60 ]; then
		printf '%d분 %d초' $((s / 60)) $((s % 60))
	else
		printf '%d초' "$s"
	fi
}

## mbuffer 는 입력 크기를 알 때만 "% done" 을 찍는다. 일반 파일은 알 수 있지만
## 블록 장치는 모르므로, 카드를 읽는 동안에는 진행률도 남은 시간도 안 나온다.
## (-D 는 출력 장치 크기 가정이라 이 경우엔 도움이 되지 않는다. 확인함)
##
## 그래서 출력 파일 크기를 지켜보며 주기적으로 한 줄씩 남긴다. mbuffer 의 표시는
## \r 로 한 줄을 갱신하는 방식이라, 줄바꿈으로 찍으면 서로 지우지 않고
## 이 줄은 스크롤백에 남고 mbuffer 줄은 그 아래에서 계속 갱신된다.
progress_reporter() {
	local done_b pct elapsed rate eta

	while sleep "$PROGRESS_INTERVAL"; do
		done_b=$(stat -c %s "$IMAGE" 2>/dev/null) || continue
		[ "${done_b:-0}" -gt 0 ] || continue

		elapsed=$((SECONDS - t0))
		[ "$elapsed" -gt 0 ] || continue

		rate=$((done_b / elapsed))
		[ "$rate" -gt 0 ] || continue

		pct=$((done_b * 100 / SZ))
		eta=$(((SZ - done_b) / rate))

		printf '\n  [%3d%%] %s / %s · %s/s · 남은 시간 약 %s\n' \
			"$pct" \
			"$(numfmt --to=iec-i --suffix=B "$done_b")" \
			"$(numfmt --to=iec-i --suffix=B "$SZ")" \
			"$(numfmt --to=iec-i --suffix=B "$rate")" \
			"$(fmt_dur "$eta")"
	done
}

## 장치가 꽂힌 USB 포트 위치. sda/sdb 같은 이름은 인식 순서대로 붙어서
## 카드를 바꿔 끼우면 달라지므로, 물리 포트를 같이 보여준다.
port_of() {
	local l
	for l in /dev/disk/by-path/*-usb-*; do
		[ -e "$l" ] || continue
		[ "$(readlink -f "$l")" = "/dev/$1" ] || continue
		echo "${l##*/}" | sed -n 's/.*-usb-0:\([0-9.]*\):.*/USB포트 \1/p'
		return 0
	done
	return 0
}

VERIFY=yes
FORCE=0
ARGS=()
for a in "$@"; do
	case "$a" in
	-n | --no-verify) VERIFY=no ;;
	-f | --force) FORCE=1 ;;
	-h | --help)
		## 3행부터 주석이 끝나는 곳까지 (행 번호를 박지 않는다)
		sed -n '3,${/^#/!q; s/^# \{0,1\}//p;}' "$0"
		exit 0
		;;
	-*)
		echo "unknown option: $a" >&2
		exit 2
		;;
	*) ARGS+=("$a") ;;
	esac
done
set -- "${ARGS[@]}"

[ "$(id -u)" -eq 0 ] || {
	echo "sudo 로 실행하세요. (블록 장치 원본 읽기 권한 필요)"
	exit 1
}

[ $# -ge 1 ] || {
	echo "사용법: sudo $0 [-n] [-f] <장치> [출력.img]"
	exit 1
}

if ! command -v mbuffer >/dev/null; then
	echo "mbuffer 가 없습니다. 설치를 시도합니다..."
	apt-get update -qq && apt-get install -y mbuffer ||
		{
			echo "설치 실패. 수동으로:  sudo apt install mbuffer"
			exit 1
		}
	command -v mbuffer >/dev/null || {
		echo "설치 후에도 mbuffer 를 찾을 수 없습니다."
		exit 1
	}
	echo "mbuffer 설치 완료."
fi

DEV="${1#/dev/}"
IMAGE="${2:-sbc_$(date +%Y%m%d_%H%M).img}"
MD5FILE="${IMAGE}.md5"

## 시스템 디스크 이름. 판별에 실패해도 스크립트가 조용히 죽지 않도록 한다.
## (set -e + pipefail 이라 || true 가 없으면 여기서 메시지 없이 종료된다)
ROOT=$(lsblk -no PKNAME "$(findmnt -no SOURCE / 2>/dev/null)" 2>/dev/null |
	head -1 | tr -d ' ' || true)
[ -n "$ROOT" ] || echo "${Y}참고: 시스템 디스크를 판별하지 못했습니다. USB 검사로만 걸러집니다.${N}" >&2

# --- 안전 검사 ---
[ -b "/dev/$DEV" ] || {
	echo "없는 장치: $DEV"
	exit 1
}
[ "$DEV" != "$ROOT" ] || {
	echo "시스템 디스크: $DEV"
	exit 1
}
[ "$(lsblk -dno TRAN "/dev/$DEV" | tr -d ' ')" = usb ] || {
	echo "USB 아님: $DEV"
	exit 1
}

SZ=$(blockdev --getsize64 "/dev/$DEV")

## 카드가 안 꽂힌 리더도 /dev/sdX 로는 존재한다. 이때 크기가 0 이라, 막지 않으면
## 0 바이트 이미지를 만들고 "MD5 일치" 로 성공까지 해버린다.
[ "$SZ" -gt 0 ] || {
	echo "장치 크기가 0 입니다: $DEV"
	echo "  카드가 꽂혀 있는지 확인하세요. (리더만 꽂혀 있으면 이렇게 나옵니다)"
	exit 1
}

## 이미 만들어 둔 이미지를 실수로 날리는 사고가 제일 아프다. 25분을 다시 쓰는
## 것보다 여기서 막는 게 낫다.
if [ -e "$IMAGE" ] && [ "$FORCE" -eq 0 ]; then
	echo "${R}출력 파일이 이미 있습니다: $IMAGE${N}"
	echo "  덮어쓰려면 -f 를 주세요. (기존 파일은 복구되지 않습니다)"
	exit 1
fi

## 60GB 를 다 쓰고 나서 No space left 로 죽으면 그때까지의 시간이 통째로 날아간다.
OUTDIR=$(dirname -- "$IMAGE")
[ -d "$OUTDIR" ] || {
	echo "출력 폴더가 없습니다: $OUTDIR"
	exit 1
}
[ -w "$OUTDIR" ] || {
	echo "출력 폴더에 쓸 수 없습니다: $OUTDIR"
	exit 1
}
## df 가 실패하면 pipefail 때문에 여기서 메시지도 없이 종료된다. 공간 확인은
## 못 해도 진행할 수 있으니 || true 로 받아 넘긴다.
AVAIL=$(df -B1 --output=avail "$OUTDIR" 2>/dev/null | tail -1 | tr -d ' ' || true)
if [ -n "$AVAIL" ] && [ "$AVAIL" -lt "$SZ" ]; then
	echo "${R}저장 공간 부족: $OUTDIR${N}"
	echo "  필요 $(numfmt --to=iec-i --suffix=B "$SZ") / 여유 $(numfmt --to=iec-i --suffix=B "$AVAIL")"
	exit 1
fi

echo
echo "${B}═══════════════════════════════════════════════════════════${N}"
printf '  읽을 장치 : /dev/%-8s %8s  %-18s %s\n' \
	"$DEV" \
	"$(lsblk -dno SIZE "/dev/$DEV" | tr -d ' ')" \
	"$(lsblk -dno MODEL "/dev/$DEV" | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//')" \
	"$(port_of "$DEV")"
echo "  출력      : $IMAGE ($(numfmt --to=iec-i --suffix=B "$SZ"))"
echo "  해시      : CRC32 + MD5 (읽으면서 동시 계산) → $MD5FILE"
if [ "$VERIFY" = yes ]; then
	echo "  쓰기 검증 : 수행 — .img 를 디스크에서 다시 읽어 MD5 대조"
else
	echo "  쓰기 검증 : ${Y}생략 (-n)${N}"
fi
echo "───────────────────────────────────────────────────────────"
echo "  ${Y}카드는 읽기만 합니다. 카드 내용은 바뀌지 않습니다."
if [ -e "$IMAGE" ]; then
	echo "  단, 기존 출력 파일 '$IMAGE' 은 덮어씁니다. (-f)${N}"
else
	echo "  다만 위 장치가 마스터 카드인지 반드시 확인하세요.${N}"
fi
echo "${B}═══════════════════════════════════════════════════════════${N}"
echo
read -r -p "  작업을 진행하시겠습니까? [Y/N]: " a
case "$a" in
y | Y | yes | YES) ;;
*)
	echo
	echo "취소되었습니다."
	exit 1
	;;
esac

# --- 마운트 해제 ---
## 마운트된 채로 읽으면 읽는 도중 파일시스템이 바뀔 수 있어 이미지가
## 어긋난다. 자동 마운트를 떼고 캐시를 비운 다음 카드에서 직접 읽는다.
for p in $(lsblk -rno NAME "/dev/$DEV" | tail -n +2); do
	umount "/dev/$p" 2>/dev/null || true
done
sync
blockdev --flushbufs "/dev/$DEV" 2>/dev/null || true
echo 3 >/proc/sys/vm/drop_caches 2>/dev/null || true

# --- 읽기 ---
section "Dumping — /dev/$DEV → $IMAGE"
LOG=$(mktemp)
VLOG=""
PROG_PID=""
## 스크립트가 어떻게 끝나든 진행률 표시 프로세스를 남기지 않는다.
cleanup() {
	rm -f "$LOG" "$VLOG"
	[ -n "$PROG_PID" ] && kill "$PROG_PID" 2>/dev/null
	return 0
}
trap cleanup EXIT
## EXIT 트랩은 신호로 죽을 때는 안 돌 수 있다. 25분짜리 작업이라 중간에 끊는
## 일이 흔하므로 INT/TERM 도 직접 받아 정리하고 나간다.
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

## mbuffer 는 기존 파일을 열지 않고 "File exists" 로 죽는다. 덮어쓰기는
## 위에서 이미 -f 로 확인받았으므로 여기서 mbuffer 에도 -f 를 넘긴다.
## (조건부로 넘겨, 위 검사에 구멍이 있어도 mbuffer 가 한 번 더 막게 둔다)
MB_OPT=()
[ "$FORCE" -eq 1 ] && MB_OPT+=(-f)

t0=$SECONDS
progress_reporter &
PROG_PID=$!

## 로그는 tee 가 아니라 mbuffer 의 -l 로 받는다. mbuffer 는 제어 터미널이
## 있으면 상태와 해시 요약을 stderr 가 아니라 /dev/tty 에 직접 쓴다. 그래서
## `2>&1 | tee` 로 받으면 터미널에서 실행했을 때만 로그가 0 바이트가 되고,
## 화면에는 해시가 멀쩡히 보이는데 스크립트는 "MD5 해시를 얻지 못했습니다" 로
## 죽는다. -l 은 화면 표시를 유지한 채로 같은 내용을 파일에도 남긴다.
set +e
mbuffer ${MB_OPT[@]+"${MB_OPT[@]}"} -i "/dev/$DEV" -o "$IMAGE" -m "$BUF" \
	--hash CRC32 --hash MD5 -l "$LOG"
rc=$?
set -e

kill "$PROG_PID" 2>/dev/null || true
wait "$PROG_PID" 2>/dev/null || true
PROG_PID=""
[ "$rc" -eq 0 ] || {
	echo
	echo "${R}mbuffer 실패 (종료코드 $rc). 이미지가 불완전합니다: $IMAGE${N}"
	exit 1
}
READ_SEC=$((SECONDS - t0))

echo
## mbuffer 가 끝나도 커널 page cache 에 아직 안 내려간 데이터가 남아 있다.
## 여기서 한참 멈출 수 있어 미리 한 줄 남긴다.
echo "  sync 중..."
sync
DUMP_SEC=$((SECONDS - t0))

## 읽으면서 계산한 해시 뽑기
CRC=$(sed -n 's/^CRC32 hash: \([0-9a-fA-F]*\).*/\1/p' "$LOG" | tail -1)
MD5=$(sed -n 's/^MD5 hash: \([0-9a-fA-F]*\).*/\1/p' "$LOG" | tail -1)

[ -n "$MD5" ] || {
	echo "${R}MD5 해시를 얻지 못했습니다. mbuffer 출력을 확인하세요.${N}"
	exit 1
}

## 크기 확인 — 카드 용량과 이미지 크기가 다르면 중간에 끊긴 것이다.
IMGSZ=$(stat -c %s "$IMAGE")
[ "$IMGSZ" -eq "$SZ" ] || {
	echo "${R}크기 불일치: 장치 ${SZ}B / 이미지 ${IMGSZ}B — 이미지가 잘렸습니다.${N}"
	exit 1
}

## md5sum -c 로 바로 검사할 수 있게 basename 으로 기록한다.
printf '%s  %s\n' "$MD5" "$(basename -- "$IMAGE")" >"$MD5FILE"

## sudo 로 만들면 root 소유가 되어 이후 작업마다 sudo 가 붙는다. 호출한
## 사용자에게 넘겨준다.
if [ -n "${SUDO_USER:-}" ]; then
	chown "$SUDO_USER" "$IMAGE" "$MD5FILE" 2>/dev/null || true
fi

section "Dumping 완료"
printf '  소요 시간 : %s  (읽기 %s + sync %s)\n' \
	"$(fmt_dur "$DUMP_SEC")" \
	"$(fmt_dur "$READ_SEC")" \
	"$(fmt_dur "$((DUMP_SEC - READ_SEC))")"
if [ "$DUMP_SEC" -gt 0 ]; then
	printf '  평균 속도 : %s/s\n' "$(numfmt --to=iec-i --suffix=B $((SZ / DUMP_SEC)))"
fi
printf '  이미지    : %s (%s)\n' "$IMAGE" "$(numfmt --to=iec-i --suffix=B "$IMGSZ")"
printf '  CRC32     : %s\n' "${CRC:-(없음)}"
printf '  MD5       : %s\n' "$MD5"
printf '  MD5 파일  : %s\n' "$MD5FILE"
echo

# --- 쓰기 검증 ---
if [ "$VERIFY" = no ]; then
	echo "  쓰기 검증 생략 (-n). 완료."
	echo
	exit 0
fi

## 방금 쓴 내용이 page cache 에서 읽히면 "디스크에 제대로 내려갔는가"를
## 확인할 수 없으므로 캐시를 비우고 다시 읽는다.
echo 3 >/proc/sys/vm/drop_caches 2>/dev/null || true

section "쓰기 검증 — $IMAGE 을 디스크에서 다시 읽어 MD5 대조"

## md5sum 으로도 되지만 60GiB 를 읽는 동안 화면이 완전히 멈춘다. mbuffer 는
## 같은 MD5 를 내면서 진행 상황을 보여주므로 이쪽을 쓴다.
VLOG=$(mktemp)
v0=$SECONDS
set +e
mbuffer -i "$IMAGE" -o /dev/null -m "$BUF" --hash MD5 -l "$VLOG"
vrc=$?
set -e
[ "$vrc" -eq 0 ] || {
	echo
	echo "${R}검증용 읽기에 실패했습니다 (종료코드 $vrc): $IMAGE${N}"
	exit 1
}
DISK_MD5=$(sed -n 's/^MD5 hash: \([0-9a-fA-F]*\).*/\1/p' "$VLOG" | tail -1)
[ -n "$DISK_MD5" ] || {
	echo "${R}검증용 MD5 를 얻지 못했습니다.${N}"
	exit 1
}

echo
printf '  소요 시간 : %s\n' "$(fmt_dur "$((SECONDS - v0))")"
printf '  카드 읽기 : %s\n' "$MD5"
printf '  파일 읽기 : %s\n' "$DISK_MD5"
echo

if [ "$MD5" = "$DISK_MD5" ]; then
	echo "  ${G}일치 — 이미지가 정상적으로 저장되었습니다.${N}"
	echo
	echo "  이후 검사:  md5sum -c $MD5FILE"
	echo
	exit 0
fi

echo "  ${R}불일치 — 저장된 이미지가 카드에서 읽은 내용과 다릅니다.${N}"
echo "  ${R}이 이미지는 쓰지 마세요. 저장 디스크를 점검하고 다시 만드세요.${N}"
echo
exit 1

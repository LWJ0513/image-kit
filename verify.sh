#!/usr/bin/env bash
#
# verify.sh - 이미 구운 장치들이 이미지와 일치하는지 검수만 한다. (쓰기 없음)
#
#   sudo ./verify.sh [옵션] <이미지> <장치...>
#
#   sudo ./verify.sh OPi5Plus_dxas2.3.0_sbc1.0.img sda sdb sdc sdd sde sdf
#   sudo ./verify.sh -f OPi5Plus_dxas2.3.0_sbc1.0.img sdg
#
# 검증 모드 (장치별로 병렬 수행):
#   (기본) -q, --quick   샘플 검증. 앞/뒤 256MiB + 균등 분포 64개 x 16MiB = 1.5GiB.
#                        장치 오지정/절단/죽은 카드/쓰기 실패를 잡는다. 수십 초.
#          -f, --full    전체 비교. 확실하지만 장치당 이미지 전체를 읽는다. 수십 분.
#
set -euo pipefail

## --- 샘플 검증 파라미터 (burn.sh 와 동일) ---
Q_EDGE=$((256 * 1024 * 1024)) ## 앞/뒤로 통째 비교할 길이
Q_CHUNKS=64                   ## 중간에 흩어 볼 chunk 개수
Q_CHUNK=$((16 * 1024 * 1024)) ## chunk 하나의 길이
ALIGN=$((4 * 1024 * 1024))    ## offset 정렬 (USB 순차 읽기 효율)

## --- 화면 표시 ---
## 터미널일 때만 색을 쓴다 (파이프/로그로 넘길 때는 제어문자 없이)
if [ -t 1 ]; then
	B=$'\033[1m' R=$'\033[1;31m' G=$'\033[1;32m' N=$'\033[0m'
else
	B='' R='' G='' N=''
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

VERIFY=quick
ARGS=()
for a in "$@"; do
	case "$a" in
	-q | --quick) VERIFY=quick ;;
	-f | --full) VERIFY=full ;;
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

[ $# -ge 2 ] || {
	echo "사용법: sudo $0 [-q|-f] <이미지> <장치...>"
	exit 1
}

IMAGE="$1"
shift
[ -r "$IMAGE" ] || {
	echo "이미지를 읽을 수 없음: $IMAGE"
	exit 1
}

SZ=$(stat -c %s "$IMAGE")

## 장치 이름 정규화 (/dev/ 접두어 제거)
DEVS=()
for d in "$@"; do
	[ -n "$d" ] || {
		echo "빈 장치 이름이 인자로 들어왔습니다."
		exit 1
	}
	DEVS+=("${d#/dev/}")
done

# --- 사전 검사 (읽기 전용이라 굽기만큼 엄격하지 않다) ---
for d in "${DEVS[@]}"; do
	[ -b "/dev/$d" ] || {
		echo "없는 장치: $d"
		exit 1
	}
	[ "$(blockdev --getsize64 "/dev/$d")" -ge "$SZ" ] || {
		echo "용량 부족: $d (이미지보다 작으므로 일치할 수 없음)"
		exit 1
	}
done

echo
echo "${B}═══════════════════════════════════════════════════════════${N}"
echo "  이미지 : $IMAGE ($(numfmt --to=iec-i --suffix=B "$SZ"))"
echo "  검증   : $VERIFY  (읽기만 합니다. 쓰기 없음)"
echo "───────────────────────────────────────────────────────────"
for d in "${DEVS[@]}"; do
	printf '    %-6s %8s  %-18s %s\n' \
		"$d" \
		"$(lsblk -dno SIZE "/dev/$d" | tr -d ' ')" \
		"$(lsblk -dno MODEL "/dev/$d" | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//')" \
		"$(port_of "$d")"
done
echo "${B}═══════════════════════════════════════════════════════════${N}"

## 비교할 구간 목록 만들기 ("offset:length")
SAMPLES=()
if [ "$VERIFY" = quick ]; then
	SAMPLES+=("0:$Q_EDGE")
	span=$((SZ - 2 * Q_EDGE))
	if [ "$span" -gt "$((Q_CHUNK * Q_CHUNKS))" ]; then
		step=$((span / (Q_CHUNKS + 1)))
		for i in $(seq 1 "$Q_CHUNKS"); do
			off=$((Q_EDGE + step * i))
			off=$((off / ALIGN * ALIGN)) ## 정렬
			SAMPLES+=("$off:$Q_CHUNK")
		done
	fi
	SAMPLES+=("$((SZ - Q_EDGE)):$Q_EDGE")
fi

## 장치 하나를 검증. 성공 0, 불일치 1.
verify_dev() {
	local d=$1 spec off len
	if [ "$VERIFY" = full ]; then
		cmp -s -n "$SZ" "$IMAGE" "/dev/$d"
		return
	fi
	for spec in "${SAMPLES[@]}"; do
		off=${spec%%:*}
		len=${spec##*:}
		## -i SKIP1:SKIP2 로 양쪽 같은 offset 부터 len 바이트만 비교
		cmp -s -i "$off:$off" -n "$len" "$IMAGE" "/dev/$d" || return 1
	done
}

## page cache 에서 읽히면 검증 의미가 없으므로 비운다
for d in "${DEVS[@]}"; do blockdev --flushbufs "/dev/$d" 2>/dev/null || true; done
echo 3 >/proc/sys/vm/drop_caches 2>/dev/null || true

if [ "$VERIFY" = quick ]; then
	total=0
	for spec in "${SAMPLES[@]}"; do total=$((total + ${spec##*:})); done
	section "검증 중 — quick, 장치당 $(numfmt --to=iec-i --suffix=B $total) (${#SAMPLES[@]}구간), ${#DEVS[@]}개 병렬"
else
	section "검증 중 — full, 장치당 $(numfmt --to=iec-i --suffix=B "$SZ"), ${#DEVS[@]}개 병렬"
fi

declare -A PID
v0=$SECONDS
for d in "${DEVS[@]}"; do
	verify_dev "$d" &
	PID[$d]=$!
done

fail=0
FAILED=()
for d in "${DEVS[@]}"; do
	if wait "${PID[$d]}"; then
		printf '    %-6s %s\n' "$d" "${G}PASS${N}"
	else
		printf '    %-6s %s\n' "$d" "${R}FAIL${N}  ← 이미지와 다릅니다"
		FAILED+=("$d")
		fail=1
	fi
done

echo
printf '  검증 소요 : %s\n' "$(fmt_dur "$((SECONDS - v0))")"
printf '  결과      : PASS %d개 / FAIL %d개\n' \
	"$((${#DEVS[@]} - ${#FAILED[@]}))" "${#FAILED[@]}"
if [ "$fail" -eq 0 ]; then
	echo
	echo "  ${G}전체 통과 — ${#DEVS[@]}개 모두 이미지와 일치합니다.${N}"
else
	printf '  불일치    : %s\n' "${FAILED[*]}"
	echo
	echo "  ${R}검증 실패 — 위 장치는 다시 flashing 해야 합니다.${N}"
fi
echo

exit "$fail"

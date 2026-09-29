"""Validate node user-data MIME. Does not create cloud/Kubernetes resources.

노드가 실제로 받는 셸 스크립트가 파일 내용과 바이트 단위로 같은지 확인한다.

cloud-init 22.2.2 는 user-data 를 아래 순서로 처리한다.

  user_data.py:385        email.message_from_string(bdata.decode("utf-8"))
  handlers/__init__.py    fully_decoded_payload(part)
                            = part.get_payload(decode=True)
                                  .decode(charset, errors="surrogateescape")
  handlers/shell_script.py  util.write_file(path, payload)
  util.py:123               text.encode("utf-8")

문제는 두 번째 줄이다. Python email 의 get_payload(decode=True) 는 본문을
ASCII 로 인코딩하려 시도하고, 실패하면 raw-unicode-escape 로 대체한다.

  한글 U+B178  ->  "\\ub178"  (ASCII 6 글자로 이스케이프)      내용이 망가짐
  가운뎃점 U+00B7 -> 0xB7     (Latin-1 범위라 단일 바이트로 남음)  UTF-8 로 깨짐

그래서 셸 스크립트 파트에 비ASCII 문자가 있으면 둘 중 하나가 일어난다.

  1. Latin-1 범위(U+0080~U+00FF) 가 있으면 -> UnicodeEncodeError 로
     cloud-init 이 파트를 통째로 버린다. 스크립트가 아예 실행되지 않고
     /var/lib/cloud/instance/scripts/ 가 빈 채로 남는다.
  2. 그 밖의 비ASCII 는 에러 없이 \\uXXXX 텍스트로 바뀐다. 스크립트는 돌지만
     노드에 남는 파일의 주석을 사람이 읽을 수 없다.

Content-Type 의 charset 선언은 이 경로에 관여하지 않는다. 2026-09-28 에
charset 을 us-ascii 에서 utf-8 로 고쳤으나 노드 10 대에서 결과가 같았다
(sshd -T 실측 3 종 전부 미적용, SSM CommandId 40528aac).

따라서 규칙은 하나다. **셸 스크립트 파트는 순수 ASCII 여야 한다.**
한글 설명은 modules/eks_nodes/main.tf 의 주석에 둔다.

사용법
  python3 scripts/check_node_user_data.py \\
      terraform/modules/eks_nodes/templates/node_user_data.mime
"""
import argparse
import email
import sys
import unicodedata
from pathlib import Path

SHELL = "text/x-shellscript"


def source_parts(raw):
    """파일에서 셸 스크립트 파트의 원본 바이트를 꺼낸다."""
    msg = email.message_from_string(raw.decode("utf-8"))
    out = []
    for part in msg.walk():
        if part.get_content_type() != SHELL:
            continue
        # 원본 문자열을 그대로 UTF-8 로 인코딩한 것이 '노드에 있어야 할' 바이트
        out.append(part.get_payload(decode=False).encode("utf-8"))
    return out


def rendered_parts(raw):
    """cloud-init 이 노드에 실제로 쓰는 바이트를 재현한다."""
    msg = email.message_from_string(raw.decode("utf-8"))
    out = []
    for part in msg.walk():
        if part.get_content_type() != SHELL:
            continue
        cte = part.get_payload(decode=True)
        charset = part.get_content_charset() or "utf-8"
        text = cte.decode(charset, errors="surrogateescape")
        out.append(text.encode("utf-8"))  # 여기서 UnicodeEncodeError 가 난다
    return out


def non_ascii(text):
    return [(i, c) for i, c in enumerate(text) if ord(c) > 127]


def check(path):
    raw = Path(path).read_bytes()
    problems = []

    try:
        raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        return ["파일이 UTF-8 이 아닙니다: %s" % exc]

    msg = email.message_from_string(raw.decode("utf-8"))
    shell = [p for p in msg.walk() if p.get_content_type() == SHELL]
    if not shell:
        return ["%s 파트를 찾지 못했습니다." % SHELL]

    # 1) 비ASCII 문자 점검 — 이것이 근본 원인이다
    for idx, part in enumerate(shell, 1):
        text = part.get_payload(decode=False)
        bad = non_ascii(text)
        if not bad:
            continue
        latin1 = [(i, c) for i, c in bad if 0x80 <= ord(c) <= 0xFF]
        kinds = sorted({c for _, c in bad}, key=ord)
        problems.append(
            "파트 %d: 비ASCII 문자 %d 개 (%d 종). 셸 스크립트 파트는 순수 ASCII 여야 합니다."
            % (idx, len(bad), len(kinds))
        )
        for ch in kinds[:8]:
            mark = " <- Latin-1 범위, cloud-init 이 죽습니다" if 0x80 <= ord(ch) <= 0xFF else ""
            problems.append(
                "    %r U+%04X %s%s"
                % (ch, ord(ch), unicodedata.name(ch, "이름 없음"), mark)
            )
        if latin1:
            for i, ch in latin1[:5]:
                line = text[:i].count("\n") + 1
                problems.append("    파트 기준 %d 행에 %r" % (line, ch))

    # 2) cloud-init 재현 — 실제로 터지는지
    try:
        got = rendered_parts(raw)
    except UnicodeEncodeError as exc:
        problems.append(
            "cloud-init 재현 실패: %s" % exc
        )
        problems.append(
            "    -> 노드에서 스크립트가 실행되지 않고 "
            "/var/lib/cloud/instance/scripts/ 가 빕니다."
        )
        return problems

    # 3) 바이트 동일성 — 에러가 없어도 내용이 망가질 수 있다
    want = source_parts(raw)
    for idx, (w, g) in enumerate(zip(want, got), 1):
        if w != g:
            problems.append(
                "파트 %d: 노드에 쓰이는 내용이 파일과 다릅니다 (%d -> %d 바이트)."
                % (idx, len(w), len(g))
            )
    return problems


def main():
    ap = argparse.ArgumentParser(description="노드 user-data MIME 검증")
    ap.add_argument("path", nargs="?",
                    default="terraform/modules/eks_nodes/templates/node_user_data.mime")
    args = ap.parse_args()

    problems = check(args.path)
    if problems:
        print("FAIL  %s" % args.path)
        for p in problems:
            print("  %s" % p)
        return 1
    print("PASS  %s — 노드가 받는 스크립트가 파일과 바이트 단위로 같습니다." % args.path)
    return 0


if __name__ == "__main__":
    sys.exit(main())

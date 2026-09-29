import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    'check_node_user_data', ROOT / 'scripts/check_node_user_data.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

MIME = ROOT / 'terraform/modules/eks_nodes/templates/node_user_data.mime'

HEAD = ('MIME-Version: 1.0\n'
        'Content-Type: multipart/mixed; boundary="//"\n\n'
        '--//\nContent-Type: text/x-shellscript; charset="utf-8"\n\n')
TAIL = '\n--//--\n'


def doc(body):
    """주어진 스크립트 본문으로 MIME 문서를 만들어 임시 파일 경로를 돌려준다."""
    fh = tempfile.NamedTemporaryFile('w', suffix='.mime', delete=False,
                                     encoding='utf-8', newline='')
    fh.write(HEAD + body + TAIL)
    fh.close()
    return fh.name


class NodeUserDataTests(unittest.TestCase):
    def test_repo_file_passes(self):
        """실제 파일은 언제나 통과해야 한다. 이 테스트가 apply 전 마지막 방어선이다."""
        self.assertEqual(checker.check(MIME), [])

    def test_middle_dot_breaks_cloud_init(self):
        """U+00B7 은 Latin-1 범위라 단일 바이트로 남아 cloud-init 이 파트를 버린다.

        2026-09-28 에 실제로 일어난 일이다. LT v2 와 v3 두 번 모두 노드 10 대에서
        sshd -T 실측 3 종이 미적용이었다 (SSM CommandId 40528aac).
        """
        problems = checker.check(doc('#!/bin/bash\n# team A · team B\nexit 0\n'))
        self.assertTrue(problems)
        joined = '\n'.join(problems)
        self.assertIn('U+00B7', joined)
        self.assertIn('Latin-1', joined)

    def test_charset_declaration_does_not_help(self):
        """charset 을 무엇으로 선언하든 결과가 같다.

        PR #94 가 us-ascii 를 utf-8 로 바꿨으나 노드에서 결과가 같았던 이유다.
        cloud-init 은 get_payload(decode=True) 단계에서 이미 망가진 바이트를 받는다.
        """
        body = '#!/bin/bash\n# a · b\nexit 0\n'
        for charset in ('us-ascii', 'utf-8'):
            head = HEAD.replace('charset="utf-8"', 'charset="%s"' % charset)
            fh = tempfile.NamedTemporaryFile('w', suffix='.mime', delete=False,
                                             encoding='utf-8', newline='')
            fh.write(head + body + TAIL)
            fh.close()
            self.assertTrue(checker.check(fh.name),
                            'charset=%s 인데 통과했습니다' % charset)

    def test_hangul_mangles_content(self):
        """한글은 에러를 내지 않지만 \\uXXXX 텍스트로 바뀌어 주석을 읽을 수 없게 된다."""
        problems = checker.check(doc('#!/bin/bash\n# 한글 주석\nexit 0\n'))
        self.assertTrue(problems)
        self.assertIn('ASCII', '\n'.join(problems))

    def test_ascii_only_passes(self):
        problems = checker.check(doc('#!/bin/bash\n# plain ascii comment\nexit 0\n'))
        self.assertEqual(problems, [])

    def test_hardening_values_present(self):
        """검증기가 통과해도 정작 설정이 빠지면 의미가 없다."""
        text = MIME.read_text(encoding='utf-8')
        for want in ('PermitRootLogin no', 'MaxAuthTries 4', 'X11Forwarding no'):
            self.assertIn(want, text)
        # 접두사 00- 은 sshd 의 first-obtained-value-wins 때문에 의도된 것이다
        self.assertIn('00-jangin-hardening.conf', text)
        # reload 가 아니라 restart 여야 Ansible SSH-009 가 PASS 를 유지한다
        self.assertIn('systemctl restart sshd', text)
        self.assertNotIn('systemctl reload sshd', text)


if __name__ == '__main__':
    unittest.main()

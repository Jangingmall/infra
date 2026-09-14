"""Validate DB/DR handoff requirements. Does not create cloud/Kubernetes resources."""
import argparse
import json
from pathlib import Path
import re
import sys

KEYS = {'environment', 'backup_bucket', 'backup_prefix', 'recovery_window_days',
        'backup_safety_margin_days', 'glacier_after_days', 'expire_after_days'}


def check_plan(plan, require_complete=False):
    if not isinstance(plan, dict) or set(plan) != KEYS:
        raise ValueError('설정 키를 예제와 동일하게 입력하세요.')
    if plan['environment'] not in ('prod', 'staging'):
        raise ValueError('environment는 prod 또는 staging이어야 합니다.')
    for key in ('recovery_window_days', 'backup_safety_margin_days', 'expire_after_days'):
        if type(plan[key]) is not int or plan[key] < 1:
            raise ValueError(f'{key}는 1 이상의 정수여야 합니다.')
    boundary = plan['recovery_window_days'] + plan['backup_safety_margin_days']
    glacier = plan['glacier_after_days']
    if glacier is not None:
        if type(glacier) is not int or glacier <= boundary:
            raise ValueError('Glacier 전환일은 복구기간 + 안전여유보다 큰 정수여야 합니다.')
    if plan['expire_after_days'] <= max(boundary, glacier or 0):
        raise ValueError('만료일은 복구기간 + 안전여유 및 Glacier 전환일보다 커야 합니다.')
    bucket, prefix = plan['backup_bucket'], plan['backup_prefix']
    if bucket is not None:
        if not isinstance(bucket, str) or not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', bucket):
            raise ValueError('backup_bucket은 버킷명이어야 합니다. URL은 입력하지 마세요.')
    if prefix is not None:
        if not isinstance(prefix, str) or not re.fullmatch(r'[a-zA-Z0-9_-]+(?:/[a-zA-Z0-9_-]+)*', prefix):
            raise ValueError('backup_prefix는 앞뒤 / 없이 확정된 경로를 입력하세요.')
    pending = [key for key in ('backup_bucket', 'backup_prefix') if plan[key] is None]
    if require_complete and pending:
        raise ValueError('미확정 항목: ' + ', '.join(pending))
    return {
        'environment': plan['environment'],
        'input_validation': 'passed',
        'ready_for_handoff': not pending,
        'pending': pending,
        'cnpg_retention_policy_proposal': f"{plan['recovery_window_days']}d",
        'destination_path_proposal': f's3://{bucket}/{prefix}' if not pending else None,
        'lifecycle_requirements': {
            key: plan[key] for key in ('backup_safety_margin_days', 'glacier_after_days', 'expire_after_days')
        },
        'notice': '검증 결과는 입력 정합성만 의미합니다. CNPG 설정과 S3/IAM 적용은 각 담당자가 검토하며, 실제 백업/PITR 검증은 별도입니다.'
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--require-complete', action='store_true')
    args = parser.parse_args()
    try:
        result = check_plan(json.loads(args.config.read_text(encoding='utf-8-sig')), args.require_complete)
    except (ValueError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

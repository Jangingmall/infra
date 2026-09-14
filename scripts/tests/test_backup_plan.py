import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('check_backup_plan', ROOT / 'scripts/check_backup_plan.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def example():
    return json.loads((ROOT / 'config/db-backup.prod.json.example').read_text(encoding='utf-8'))


class BackupPlanTests(unittest.TestCase):
    def test_pending_names_are_not_claimed_ready(self):
        result = checker.check_plan(example())
        self.assertFalse(result['ready_for_handoff'])
        self.assertIsNone(result['destination_path_proposal'])
        with self.assertRaises(ValueError):
            checker.check_plan(example(), require_complete=True)

    def test_complete_handoff_and_retention(self):
        plan = example()
        plan.update(backup_bucket='test-backup-bucket', backup_prefix='cnpg/prod', recovery_window_days=45)
        result = checker.check_plan(plan, require_complete=True)
        self.assertEqual(result['cnpg_retention_policy_proposal'], '45d')
        self.assertEqual(result['destination_path_proposal'], 's3://test-backup-bucket/cnpg/prod')
        self.assertTrue(result['ready_for_handoff'])

    def test_reject_glacier_inside_window_or_margin(self):
        for days in (0, 30, 37, 37.5, True):
            with self.subTest(days=days):
                plan = example()
                plan['glacier_after_days'] = days
                with self.assertRaises(ValueError):
                    checker.check_plan(plan)

    def test_expiration_must_exceed_window_and_transition(self):
        for glacier, expires in ((None, 37), (60, 59), (60, 60)):
            plan = example()
            plan.update(glacier_after_days=glacier, expire_after_days=expires)
            with self.subTest(glacier=glacier, expires=expires), self.assertRaises(ValueError):
                checker.check_plan(plan)

    def test_accept_disabled_or_delayed_transition(self):
        for glacier in (None, 60):
            plan = example()
            plan['glacier_after_days'] = glacier
            self.assertEqual(checker.check_plan(plan)['lifecycle_requirements']['glacier_after_days'], glacier)

    def test_invalid_values_and_unknown_keys(self):
        for key, value in [('environment', 'stg'), ('backup_bucket', 's3://bucket'), ('backup_prefix', '../other'),
                           ('recovery_window_days', 0), ('backup_safety_margin_days', 1.5), ('expire_after_days', True),
                           ('create_irsa_role', True)]:
            plan = example()
            plan[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                checker.check_plan(plan)


if __name__ == '__main__':
    unittest.main()

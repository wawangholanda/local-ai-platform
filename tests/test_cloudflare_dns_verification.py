import unittest
from pathlib import Path

import yaml


class CloudflareDNSVerificationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path("ansible/roles/open_webui_reverse_proxy/tasks/main.yml")
        cls.tasks = yaml.safe_load(path.read_text())
        cls.by_name = {task["name"]: task for task in cls.tasks}

    def test_verification_reads_cloudflare_api_and_checks_success(self):
        task = self.by_name["Verify the Cloudflare DNS records after reconciliation"]
        self.assertEqual(task["ansible.builtin.uri"]["method"], "GET")
        self.assertIn("open_webui_proxy_domain | urlencode",
                      task["ansible.builtin.uri"]["url"])
        self.assertIn("open_webui_proxy_dns_verify.json.success",
                      task["failed_when"])
        self.assertTrue(task["no_log"])

    def test_exact_hostname_is_asserted(self):
        task = self.by_name["Assert Cloudflare returned records for the exact hostname"]
        conditions = task["ansible.builtin.assert"]["that"]
        self.assertTrue(any("open_webui_verified_records" in c for c in conditions)
                        or any("open_webui_proxy_verified_records" in c for c in conditions))
        self.assertTrue(any("open_webui_proxy_domain" in c and "unique" in c
                            for c in conditions))

    def test_conflicting_dns_types_are_rejected_after_reconciliation(self):
        task = self.by_name[
            "Assert no conflicting DNS record types remain"
        ]
        conditions = task["ansible.builtin.assert"]["that"]
        joined = " ".join(conditions)
        self.assertIn("open_webui_proxy_verified_records", joined)
        self.assertIn("CNAME", joined)
        self.assertIn("NS", joined)
        self.assertIn("AAAA", joined)
        self.assertTrue(task["no_log"])

    def test_exactly_one_a_record_is_asserted(self):
        task = self.by_name[
            "Assert exactly one Cloudflare A record exists after reconciliation"
        ]
        conditions = task["ansible.builtin.assert"]["that"]
        self.assertTrue(any(
            "open_webui_proxy_verified_a_records | length == 1" in c
            for c in conditions
        ))

    def test_ip_hostname_and_dns_only_are_asserted(self):
        task = self.by_name[
            "Assert Cloudflare A record matches the Tailscale IPv4 address"
        ]
        conditions = task["ansible.builtin.assert"]["that"]
        joined = " ".join(conditions)
        self.assertIn("open_webui_proxy_verified_a_records[0].name", joined)
        self.assertIn("open_webui_proxy_domain", joined)
        self.assertIn("open_webui_proxy_tailscale_ip", joined)
        self.assertIn("proxied", joined)


if __name__ == "__main__":
    unittest.main()

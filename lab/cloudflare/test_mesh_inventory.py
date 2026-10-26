"""Pure offline tests for the GET-only redacted Cloudflare inventory."""
import unittest

from mesh_inventory import InventoryFailure, NoRedirect, collect, read_paginated, read_profiles, summarize


ACCOUNT = "0123456789abcdef0123456789abcdef"
NODE = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"


def page(rows, page=1, total=None):
    return {
        "success": True,
        "result": rows,
        "result_info": {"page": page, "total_count": len(rows) if total is None else total},
    }


def fake_fetch(path, args):
    if path == "/accounts":
        return page([{"id": ACCOUNT}])
    if path.endswith("/teamnet/routes"):
        return page([{"id": "route-1", "network": "0.0.0.0/0",
                      "tunnel_id": NODE}], page=args["page"])
    if path.endswith("/warp_connector"):
        return page([{"id": NODE, "name": "galaxy-iphone-mesh-node",
                      "status": "healthy"}], page=args["page"])
    if path.endswith("/devices/policies"):
        return {"success": True, "result": [
            {"id": "p1", "enabled": True, "include": [{"address": "100.96.0.0/12"}]}
        ]}
    raise AssertionError("unexpected endpoint " + path)


class InventoryTests(unittest.TestCase):
    def test_get_only_inventory_and_redacted_summary(self):
        out = "\n".join(collect(fake_fetch))
        self.assertIn("IPv4 default routes: **1**", out)
        self.assertIn("Single-client route isolation: **UNKNOWN", out)
        self.assertIn("Exact named node healthy: **true**", out)
        for secret in (ACCOUNT, NODE, "route-1", "p1", "galaxy-iphone-mesh-node",
                       "100.96.0.0/12"):
            self.assertNotIn(secret, out)

    def test_truncated_page_is_rejected(self):
        with self.assertRaises(InventoryFailure):
            read_paginated(lambda _endpoint, _args: page([{"id": "r1"}], total=2),
                           "/accounts/test/teamnet/routes")

    def test_missing_pagination_is_rejected(self):
        with self.assertRaises(InventoryFailure):
            read_paginated(lambda _endpoint, _args: {
                "success": True, "result": [{"id": "r1"}]
            }, "/accounts/test/teamnet/routes")

    def test_duplicate_id_across_pages_is_rejected(self):
        calls = []
        def fetch(_endpoint, args):
            calls.append(args["page"])
            return page([{"id": "r1"}], page=args["page"], total=2)
        with self.assertRaises(InventoryFailure):
            read_paginated(fetch, "/accounts/test/teamnet/routes")
        self.assertEqual(calls, [1, 2])

    def test_valid_zero_route_page(self):
        self.assertEqual(read_paginated(lambda _endpoint, _args: page([]),
                                        "/accounts/test/teamnet/routes"), [])

    def test_incomplete_single_page_profile_rejected(self):
        with self.assertRaises(InventoryFailure):
            read_profiles(lambda _endpoint, _args: {
                "success": True, "result": [{"id": "x"}] * 100
            }, "/accounts/test/devices/policies")

    def test_ambiguous_account_rejected(self):
        def bad(path, args):
            if path == "/accounts":
                return page([{"id": ACCOUNT}], total=2)
            return fake_fetch(path, args)
        with self.assertRaises(InventoryFailure):
            collect(bad)

    def test_bad_network_fail_closed(self):
        with self.assertRaises(InventoryFailure):
            summarize([{"id": "r1", "network": "not-an-ip-range"}], [], [])

    def test_redirect_refused_before_auth_header_forward(self):
        with self.assertRaises(InventoryFailure) as failure:
            NoRedirect().redirect_request(
                None, None, 302, "redirect", {}, "https://untrusted.invalid/"
            )
        self.assertEqual(str(failure.exception), "REDIRECT_REJECTED")

    def test_ambiguous_node_rejected(self):
        with self.assertRaises(InventoryFailure):
            summarize([], [
                {"id": "1", "name": "galaxy-iphone-mesh-node"},
                {"id": "2", "name": "galaxy-iphone-mesh-node"},
            ], [])


if __name__ == "__main__":
    unittest.main()

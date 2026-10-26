#!/usr/bin/env python3
"""Bounded read-only Cloudflare Mesh inventory. All published output is aggregated."""
from __future__ import annotations

import ipaddress
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.cloudflare.com/client/v4"
NODE_NAME = "galaxy-iphone-mesh-node"
PAGE_SIZE = 100
MAX_PAGES = 20


class InventoryFailure(Exception):
    """Never contain API responses, account IDs, tokens or requested URLs."""


def valid_array(payload):
    if not isinstance(payload, dict) or payload.get("success") is not True:
        raise InventoryFailure("INVALID_RESPONSE")
    rows = payload.get("result")
    if not isinstance(rows, list) or not all(isinstance(v, dict) for v in rows):
        raise InventoryFailure("INVALID_ROWS")
    return rows


def result_info(payload, page):
    info = payload.get("result_info")
    if not isinstance(info, dict):
        raise InventoryFailure("PAGINATION_UNKNOWN")
    total = info.get("total_count")
    seen_page = info.get("page")
    if not isinstance(total, int) or isinstance(total, bool) or total < 0:
        raise InventoryFailure("PAGINATION_UNKNOWN")
    if not isinstance(seen_page, int) or isinstance(seen_page, bool) or seen_page != page:
        raise InventoryFailure("PAGINATION_MISMATCH")
    return total


def read_paginated(fetch, endpoint):
    """Routes and Mesh nodes have documented page-based pagination."""
    entries = []
    expected_total = None
    ids = set()
    for page in range(1, MAX_PAGES + 1):
        payload = fetch(endpoint, {"per_page": PAGE_SIZE, "page": page})
        rows = valid_array(payload)
        total = result_info(payload, page)
        if expected_total is None:
            expected_total = total
        if total != expected_total or len(rows) > PAGE_SIZE:
            raise InventoryFailure("PAGINATION_MISMATCH")
        for row in rows:
            identity = row.get("id")
            if not isinstance(identity, str) or not identity or identity in ids:
                raise InventoryFailure("DUPLICATE_OR_MISSING_ID")
            ids.add(identity)
        entries.extend(rows)
        if len(entries) == expected_total:
            return entries
        if not rows or len(entries) > expected_total:
            raise InventoryFailure("PAGINATION_INCOMPLETE")
    raise InventoryFailure("PAGINATION_LIMIT")


def read_profiles(fetch, endpoint):
    """Cloudflare custom-device-policy list is documented as SinglePage."""
    payload = fetch(endpoint, {})
    rows = valid_array(payload)
    info = payload.get("result_info")
    if info is not None:
        if not isinstance(info, dict):
            raise InventoryFailure("PROFILES_UNVERIFIED")
        total = info.get("total_count")
        if not isinstance(total, int) or isinstance(total, bool) or total != len(rows):
            raise InventoryFailure("PROFILES_UNVERIFIED")
    if len(rows) >= PAGE_SIZE and info is None:
        # Never silently assume that a full provider-sized page is complete.
        raise InventoryFailure("PROFILES_UNVERIFIED")
    return rows


def summarize(routes, nodes, profiles):
    """No names, addresses, identities or route rules may leave this function."""
    active_nodes = [node for node in nodes if node.get("deleted_at") in (None, "")]
    matches = [node for node in active_nodes if node.get("name") == NODE_NAME]
    if len(matches) > 1:
        raise InventoryFailure("AMBIGUOUS_NODE")
    node_id = matches[0].get("id") if matches else None
    live_routes = [route for route in routes if route.get("deleted_at") in (None, "")]
    default_v4 = 0
    non_rfc1918 = 0
    node_routes = 0
    ipv4_routes = 0
    private = [ipaddress.ip_network(x) for x in
               ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]
    for route in live_routes:
        try:
            network = ipaddress.ip_network(route["network"], strict=True)
        except (KeyError, TypeError, ValueError) as exc:
            raise InventoryFailure("INVALID_NETWORK") from None
        if node_id is not None and route.get("tunnel_id") == node_id:
            node_routes += 1
        if network.version == 4:
            ipv4_routes += 1
            default_v4 += int(network.prefixlen == 0)
            non_rfc1918 += int(not any(network.subnet_of(block) for block in private))
    enabled = [profile for profile in profiles if profile.get("enabled") is True]
    def includes_default(profile):
        includes = profile.get("include", [])
        if not isinstance(includes, list):
            raise InventoryFailure("INVALID_PROFILE")
        return any(isinstance(entry, dict) and entry.get("address") == "0.0.0.0/0"
                   for entry in includes)
    full_includes = sum(int(includes_default(profile)) for profile in enabled)
    healthy = bool(matches and matches[0].get("status") == "healthy")
    return [
        "### MISH read-only Cloudflare Mesh inventory",
        "",
        "- Provider calls: **GET only**; configuration writes: **none**",
        f"- Active CIDR routes: **{len(live_routes)}**",
        f"- Active IPv4 CIDR routes: **{ipv4_routes}**",
        f"- IPv4 default routes: **{default_v4}**",
        f"- Non-RFC1918-contained IPv4 routes (including special ranges): **{non_rfc1918}**",
        f"- Live Mesh nodes returned: **{len(active_nodes)}**",
        f"- Exact named node matches: **{len(matches)}**",
        f"- Exact named node healthy: **{str(healthy).lower()}**",
        f"- Routes attributed to that node: **{node_routes}**",
        f"- Device profiles returned: **{len(profiles)}**",
        f"- Enabled device profiles: **{len(enabled)}**",
        f"- Enabled profiles with IPv4 default in include list: **{full_includes}**",
        "- Single-client route isolation: **UNKNOWN (not asserted from counts)**",
        "- iPhone source, Linux forwarding and Galaxy UDP: **NOT_RUN**",
        "- Any default-route modification: **NOT_AUTHORIZED**",
    ]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Prevent bearer tokens being forwarded to a redirected host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise InventoryFailure("REDIRECT_REJECTED")


class CloudflareAPI:
    def __init__(self, token):
        if not token:
            raise InventoryFailure("TOKEN_UNAVAILABLE")
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect)

    def __call__(self, path, params):
        if not path.startswith("/accounts") or not isinstance(params, dict):
            raise InventoryFailure("ENDPOINT_INVALID")
        url = API + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        request = urllib.request.Request(
            url, method="GET",
            headers={"Authorization": "Bearer " + self.token, "Accept": "application/json"},
        )
        try:
            with self.opener.open(request, timeout=20) as response:
                content = response.read(4_000_001)
                if len(content) > 4_000_000:
                    raise InventoryFailure("RESPONSE_OVERSIZE")
            return json.loads(content)
        except (OSError, ValueError, urllib.error.URLError):
            raise InventoryFailure("REMOTE_READ_FAILED") from None


def collect(fetch):
    # The protected token must resolve precisely one account, including across all pages.
    accounts_payload = fetch("/accounts", {"per_page": 50, "page": 1})
    accounts = valid_array(accounts_payload)
    if len(accounts) != 1 or result_info(accounts_payload, 1) != 1:
        raise InventoryFailure("ACCOUNT_SCOPE_AMBIGUOUS")
    account = accounts[0].get("id")
    if not isinstance(account, str) or re.fullmatch(r"[0-9a-fA-F]{32}", account) is None:
        raise InventoryFailure("ACCOUNT_SCOPE_INVALID")
    prefix = "/accounts/" + account
    routes = read_paginated(fetch, prefix + "/teamnet/routes")
    nodes = read_paginated(fetch, prefix + "/warp_connector")
    profiles = read_profiles(fetch, prefix + "/devices/policies")
    return summarize(routes, nodes, profiles)


def main():
    try:
        output = collect(CloudflareAPI(os.environ.get("CLOUDFLARE_API_TOKEN", "")))
        print("\n".join(output))
    except InventoryFailure as error:
        # These are constant error codes only; never surface URLs or API response content.
        print("MISH_INVENTORY_FAILURE|" + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

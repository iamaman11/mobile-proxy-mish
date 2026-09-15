#!/usr/bin/env python3
"""Run all fail-closed repository architecture and delivery guards."""

from check_architecture_core import main as check_architecture
from check_ci_product_contract_alignment import main as check_ci_product_contract_alignment
from check_ci_scope_contract import main as check_ci_scope_contract
from check_delivery_contract import main as check_delivery_contract
from check_device_cycle_contract import main as check_device_cycle_contract
from check_diagnostics_contract import main as check_diagnostics_contract


def main() -> None:
    check_architecture()
    check_ci_scope_contract()
    check_ci_product_contract_alignment()
    check_delivery_contract()
    check_device_cycle_contract()
    check_diagnostics_contract()


if __name__ == "__main__":
    main()

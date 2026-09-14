#!/usr/bin/env python3
"""Run all fail-closed repository architecture and delivery guards."""

from check_architecture_core import main as check_architecture
from check_delivery_contract import main as check_delivery_contract


def main() -> None:
    check_architecture()
    check_delivery_contract()


if __name__ == "__main__":
    main()

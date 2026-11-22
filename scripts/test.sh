#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/qr888-tests.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
xcrun swiftc Sources/{LabelPage,PrintSpool,QueueConfiguration,PrinterName}.swift Tests/main.swift -o "$scratch/test"
"$scratch/test"

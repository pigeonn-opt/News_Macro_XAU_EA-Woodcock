#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../backend"
if [ ! -f .env ]; then cp .env.template .env; fi
python -m uvicorn main:app --host 0.0.0.0 --port 8000

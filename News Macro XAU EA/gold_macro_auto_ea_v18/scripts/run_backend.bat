@echo off
cd /d %~dp0\..\backend
if not exist .env copy .env.template .env
python -m uvicorn main:app --host 0.0.0.0 --port 8000

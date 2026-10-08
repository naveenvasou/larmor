"""Larmor's only server: stores what a user CHOOSES to send.

  POST {"kind": "email", "email": "..."}                       optional email at install
  POST {"kind": "feedback", "message": "...", "email": "..."}  "Send feedback" in the menu bar

No usage data, no audio, no transcripts: Larmor never phones home on its own.
Runs as an AWS Lambda with a function URL; items go to the DynamoDB table in TABLE.
"""
import json
import os
import re
import time
import uuid

import boto3

TABLE = boto3.resource("dynamodb").Table(os.environ["TABLE"])
EMAIL = re.compile(r"^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,24}$")


def _resp(code, body):
    return {"statusCode": code, "headers": {"content-type": "application/json"}, "body": json.dumps(body)}


def handler(event, _ctx):
    if event.get("requestContext", {}).get("http", {}).get("method") != "POST":
        return _resp(405, {"error": "POST only"})
    raw = event.get("body") or ""
    if len(raw) > 8000:
        return _resp(413, {"error": "too large"})
    try:
        b = json.loads(raw)
    except ValueError:
        return _resp(400, {"error": "bad json"})
    kind = b.get("kind")
    email = (b.get("email") or "").strip()[:254]
    message = (b.get("message") or "").strip()[:4000]
    if email and not EMAIL.match(email):
        return _resp(400, {"error": "bad email"})
    if kind == "email" and not email:
        return _resp(400, {"error": "email required"})
    if kind == "feedback" and not message:
        return _resp(400, {"error": "message required"})
    if kind not in ("email", "feedback"):
        return _resp(400, {"error": "unknown kind"})
    TABLE.put_item(Item={
        "id": str(uuid.uuid4()), "kind": kind, "email": email, "message": message,
        "version": str(b.get("version") or "")[:40], "ts": int(time.time()),
    })
    return _resp(200, {"ok": True})

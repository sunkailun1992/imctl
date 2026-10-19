"""Direct WeCom API helper for the user's OWN quick validation, without the
proxy: gets an access_token with corpid + secret from environment variables
and creates a group join-way QR and a contact-way QR, downloading both PNGs.

This bypasses the production design (secret stays on the proxy) and only
works when this machine's egress IP is in the app's trusted-IP list. Never
paste the secret on a command line; export it in the shell and unset it after.

  export WECOM_CORP_ID=ww… WECOM_CORP_SECRET=… WECOM_USERID=<员工userid>
  python3 -m imctl_sim.wecom_direct qr --chat-id <seed chat_id> --out ./out
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request

BASE = "https://qyapi.weixin.qq.com/cgi-bin/"


def _post(path: str, token: str, body: dict) -> dict:
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(f"{BASE}{path}?access_token={token}", data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        out = json.loads(resp.read().decode("utf-8"))
    if out.get("errcode", 0) != 0:
        raise SystemExit(f"{path}: errcode {out.get('errcode')} {out.get('errmsg')}")
    return out


def token() -> str:
    corp, secret = os.environ.get("WECOM_CORP_ID"), os.environ.get("WECOM_CORP_SECRET")
    if not corp or not secret:
        raise SystemExit("export WECOM_CORP_ID and WECOM_CORP_SECRET first (app with 客户联系 permission; this machine's IP must be trusted)")
    with urllib.request.urlopen(f"{BASE}gettoken?corpid={corp}&corpsecret={secret}", timeout=20) as resp:
        out = json.loads(resp.read().decode("utf-8"))
    if out.get("errcode", 0) != 0:
        raise SystemExit(f"gettoken: errcode {out.get('errcode')} {out.get('errmsg')} (60020 = this IP is not trusted)")
    return out["access_token"]


def download(url: str, path: str) -> str:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with urllib.request.urlopen(url, timeout=20) as resp, open(path, "wb") as f:
        f.write(resp.read())
    return path


def cmd_groups(args) -> None:
    t = token()
    cursor, rows = "", []
    while True:
        page = _post("externalcontact/groupchat/list", t, {"status_filter": 0, "cursor": cursor, "limit": 100})
        for g in page.get("group_chat_list", []):
            detail = _post("externalcontact/groupchat/get", t, {"chat_id": g["chat_id"], "need_name": 1})["group_chat"]
            rows.append({"chat_id": g["chat_id"], "name": detail.get("name"), "members": len(detail.get("member_list", []))})
        cursor = page.get("next_cursor") or ""
        if not cursor:
            break
    print(json.dumps(rows, ensure_ascii=False, indent=2))


def cmd_qr(args) -> None:
    t = token()
    userid = os.environ.get("WECOM_USERID") or args.userid
    if not userid:
        raise SystemExit("export WECOM_USERID (staff userid for the contact-way QR) or pass --userid")
    os.makedirs(args.out, exist_ok=True)
    if args.chat_id:
        jw = _post("externalcontact/groupchat/add_join_way", t, {
            "scene": 2, "remark": "imctl", "auto_create_room": 1, "room_base_name": args.room_base_name, "room_base_id": 1,
            "chat_id_list": [args.chat_id], "state": args.state})
        got = _post("externalcontact/groupchat/get_join_way", t, {"config_id": jw["config_id"]})["join_way"]
        path = download(got["qr_code"], os.path.join(args.out, f"joinway-{jw['config_id']}.png"))
        print(f"群活码（扫码进群，群满自动建 {args.room_base_name}N）: {path}  config_id={jw['config_id']}")
    cw = _post("externalcontact/add_contact_way", t, {"type": 1, "scene": 2, "remark": "imctl", "skip_verify": True, "state": args.state, "user": [userid]})
    path = download(cw["qr_code"], os.path.join(args.out, f"contactway-{cw['config_id']}.png"))
    print(f"联系我（扫码加人）: {path}  config_id={cw['config_id']}")


def main(argv=None) -> None:
    p = argparse.ArgumentParser(prog="wecom_direct", description="direct WeCom API helper (validation only; production goes through the proxy)")
    sub = p.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("groups", help="list customer groups with names")
    g.set_defaults(fn=cmd_groups)
    q = sub.add_parser("qr", help="create join-way (needs --chat-id) and contact-way QR codes and download them")
    q.add_argument("--chat-id", help="seed group chat_id for the join-way QR")
    q.add_argument("--userid", help="staff userid for the contact-way QR (or WECOM_USERID)")
    q.add_argument("--out", default="./out")
    q.add_argument("--state", default="imctl-ch1")
    q.add_argument("--room-base-name", default="imctl群")
    q.set_defaults(fn=cmd_qr)
    args = p.parse_args(argv)
    args.fn(args)


if __name__ == "__main__":
    main()

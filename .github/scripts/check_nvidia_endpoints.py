#!/usr/bin/env python3
"""Check that the NVIDIA endpoints used by Update-NVIDIADriver.ps1 still behave as expected.

The script relies on three undocumented NVIDIA endpoints. This check runs the
same chain for a few reference GPUs and fails loudly when NVIDIA changes a
format, so the script can be fixed before devices start failing.

Exit codes: 0 all checks passed, 1 at least one check failed.
Writes a Markdown summary to $GITHUB_STEP_SUMMARY when available.
"""

from __future__ import annotations

import os
import re
import sys
import xml.etree.ElementTree as ET
from urllib.parse import unquote

import requests

LOOKUP = "https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID={type_id}"
PROCESS = "https://www.nvidia.com/Download/processDriver.aspx?psid={psid}&pfid={pfid}&osid={osid}&dtcid=1&dtid=1"
AJAX = ("https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/"
        "AjaxDriverService.php?func=GetDownloadDetails&downloadID={download_id}")

# Reference GPUs by name, so the check also notices renamed products.
REFERENCE_GPUS = [
    "NVIDIA GeForce RTX 4070",
    "NVIDIA RTX A2000",
    "Quadro T2000",
]
OS_IDS = {"Windows 11": 135, "Windows 10 64-bit": 57}
TIMEOUT = 60


def lookup(session: requests.Session, type_id: int) -> list[dict]:
    resp = session.get(LOOKUP.format(type_id=type_id), timeout=TIMEOUT)
    resp.raise_for_status()
    root = ET.fromstring(resp.content)
    items = []
    for node in root.iter():
        if node.tag.split("}")[-1] != "LookupValue":
            continue
        fields = {c.tag.split("}")[-1]: (c.text or "").strip() for c in node}
        items.append({
            "name": re.sub(r"\s+", " ", fields.get("Name", "")),
            "parent": int(node.attrib.get("ParentID", 0)),
            "value": int(fields.get("Value", 0) or 0),
        })
    return items


def main() -> int:
    session = requests.Session()
    session.headers["User-Agent"] = "NVIDIA-Driver-AutoUpdate endpoint check (+https://github.com/soulbit-nl/NVIDIA-Driver-AutoUpdate)"
    results: list[tuple[str, bool, str]] = []

    try:
        series = lookup(session, 2)
        products = lookup(session, 3)
        ok = len(series) > 50 and len(products) > 500
        results.append(("Lookup TypeID 2 and 3", ok, f"{len(series)} series, {len(products)} products"))
    except Exception as exc:  # noqa: BLE001 - report every failure the same way
        results.append(("Lookup TypeID 2 and 3", False, f"{type(exc).__name__}: {exc}"))
        products = []

    for gpu in REFERENCE_GPUS:
        matches = [p for p in products if p["name"].lower() in (gpu.lower(), gpu.lower().removeprefix("nvidia "))]
        if not matches:
            results.append((f"{gpu}: product found", False, "not in TypeID 3 list (renamed or removed?)"))
            continue
        product = matches[0]
        for os_name, osid in OS_IDS.items():
            label = f"{gpu} on {os_name}"
            try:
                text = session.get(PROCESS.format(psid=product["parent"], pfid=product["value"], osid=osid),
                                   timeout=TIMEOUT).text.strip()
                m = re.search(r"(?:driverResults\.aspx|/drivers/details)/(\d+)", text)
                if not m:
                    results.append((label, False, f"unexpected processDriver response: {text[:120]!r}"))
                    continue
                data = session.get(AJAX.format(download_id=m.group(1)), timeout=TIMEOUT).json()
                info = data["IDS"][0]["downloadInfo"]
                url = unquote(info.get("DownloadURL", ""))
                version = str(info.get("Version", ""))
                if not re.fullmatch(r"\d{3}\.\d{2}", version):
                    vm = re.search(r"/(\d{3}\.\d{2})/", url)
                    version = vm.group(1) if vm else ""
                ok = url.startswith("https://") and url.endswith(".exe") and bool(version)
                results.append((label, ok, f"{version or 'no version'} {url.rsplit('/', 1)[-1]}"))
            except Exception as exc:  # noqa: BLE001
                results.append((label, False, f"{type(exc).__name__}: {exc}"))

    lines = ["| Check | Result | Detail |", "| --- | --- | --- |"]
    lines += [f"| {name} | {'pass' if ok else 'FAIL'} | {detail} |" for name, ok, detail in results]
    report = "\n".join(lines)
    print(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write("## NVIDIA endpoint check\n\n" + report + "\n")
    return 0 if all(ok for _, ok, _ in results) else 1


if __name__ == "__main__":
    sys.exit(main())

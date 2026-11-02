import base64
import json
import posixpath
import string
from pathlib import Path


ROOT = Path(__file__).parent
MANIFEST = ROOT / "manifest.json"
REVISION = "1ad1df6b72d4c8b0e40e8ced1249ef8a8a6bc0ad"
IDS = {
    "argv.raw-bytes",
    "argv0.dmenu",
    "dmenu.sync",
    "matching.methods",
    "parse-char.hex",
    "matching.negate-byte",
    "diagnostics.exit-dataerr",
}
HEX = set(string.hexdigits)


def fail(message):
    raise AssertionError(message)


def decode(value):
    return base64.b64decode(value, validate=True)


def parse_hex_like_strtol(value):
    text = value.lstrip(" \t\n\r\v\f")
    sign = 1
    if text[:1] in ("+", "-"):
        sign = -1 if text[0] == "-" else 1
        text = text[1:]
    if text[:2].lower() == "0x" and len(text) > 2 and text[2] in HEX:
        text = text[2:]
    digits = ""
    for character in text:
        if character not in HEX:
            break
        digits += character
    number = sign * (int(digits, 16) if digits else 0)
    number = min(max(number, -(1 << 63)), (1 << 63) - 1)
    return number & 0xFF


def validate_contract(contract):
    contract_id = contract["id"]
    if contract["swiftStatus"] not in {"supported", "gap", "mixed"}:
        fail(f"{contract_id}: invalid Swift status")
    for evidence in contract["evidence"]:
        path = evidence.split(":", 1)[0]
        if path.startswith("/") or ".." in Path(path).parts:
            fail(f"{contract_id}: evidence path is not repository-relative")

    cases = contract["cases"]
    if contract_id == "argv.raw-bytes":
        for case in cases:
            argv = [decode(arg) for arg in case["argvBase64"]]
            if len(argv[-1]) != 1 or argv[-2] != b"-sep" or argv[-1][0] != case["expectedSeparatorByte"]:
                fail(f"{contract_id}: raw argv case does not preserve the separator byte")
    elif contract_id == "argv0.dmenu":
        for case in cases:
            actual = posixpath.basename(case["argv0"]) == "dmenu"
            if actual != case["startsDmenuMode"]:
                fail(f"{contract_id}: basename dispatch mismatch")
    elif contract_id == "dmenu.sync":
        expected = {"-sync", "-dump", "-select", "-no-custom", "-only-match", "-auto-select", "-selected-row"}
        if set(cases[0]["syncForcingOptions"]) != expected or not cases[0]["readAllBeforeDialog"]:
            fail(f"{contract_id}: incomplete synchronous-input contract")
    elif contract_id == "matching.methods":
        case = cases[0]
        if case["names"] != ["normal", "regex", "glob", "fuzzy", "prefix"]:
            fail(f"{contract_id}: method names or source order changed")
        if (
            not case["asciiCaseInsensitive"]
            or case["recognizedNameErrorCount"] != 5
            or not case["duplicatesCountTowardLimit"]
            or case["namesAfterLimitChecked"]
        ):
            fail(f"{contract_id}: matching-list limit contract changed")
    elif contract_id == "parse-char.hex":
        for case in cases:
            if parse_hex_like_strtol(case["argument"][2:]) != case["expectedByte"]:
                fail(f"{contract_id}: {case['argument']!r} does not match strtol/char semantics")
    elif contract_id == "matching.negate-byte":
        for case in cases:
            token = decode(case["tokenBase64"])
            invert = bool(token) and token[0] == case["negateByte"]
            pattern = token[1:] if invert else token
            if invert != case["invert"] or pattern != decode(case["patternBase64"]):
                fail(f"{contract_id}: raw-byte negation mismatch")
    elif contract_id == "diagnostics.exit-dataerr":
        case = cases[0]
        if case != {"invalidMatchingWithDisplay": 65, "noDisplayBeforeValidation": 1, "macOSPolicy": 65}:
            fail(f"{contract_id}: exit policy changed")


def main():
    data = json.loads(MANIFEST.read_text())
    if data["schemaVersion"] != 1 or data["upstream"]["revision"] != REVISION:
        fail("manifest is not pinned to the T5 upstream revision")
    contracts = data["contracts"]
    if {contract["id"] for contract in contracts} != IDS:
        fail("manifest does not contain exactly the seven T5 contracts")
    for contract in contracts:
        validate_contract(contract)
    print(f"validated {len(contracts)} T5 CLI contracts at {data['upstream']['shortRevision']}")


if __name__ == "__main__":
    main()

"""Phase 0 artifacts of the mashup platform: tasks.json shape and manifest schema verdicts."""
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "platform" / "packages" / "manifest"


def test_tasks_json_is_well_formed():
    data = json.loads((ROOT / "tasks.json").read_text(encoding="utf-8"))
    ids = [t["id"] for t in data["tasks"]]
    assert len(ids) == len(set(ids)), "duplicate task ids"
    for t in data["tasks"]:
        assert t["status"] in data["statuses"], t["id"]
        assert t["verify"].strip(), f"{t['id']} has no verify step"
        assert isinstance(t["phase"], int) and 0 <= t["phase"] <= 6, t["id"]


def test_manifest_schema_verdicts():
    jsonschema = pytest.importorskip("jsonschema")
    schema = json.loads((MANIFEST / "mashup.schema.json").read_text(encoding="utf-8"))
    jsonschema.Draft202012Validator.check_schema(schema)
    v = jsonschema.Draft202012Validator(schema)
    good = json.loads((MANIFEST / "examples" / "hello-mod" / "mashup.json").read_text(encoding="utf-8"))
    assert not list(v.iter_errors(good))
    bad = json.loads((MANIFEST / "examples" / "bad" / "traversal.json").read_text(encoding="utf-8"))
    failed = {"/".join(map(str, e.path)) for e in v.iter_errors(bad)}
    assert failed == {"ops/0/target", "launch/args/0", "online/mode"}


@pytest.mark.parametrize("target", ["../x", "a/../../x", "C:/Windows/x", "/etc/passwd", "a\\b", "file.txt:ads", "a/.."])
def test_unsafe_targets_rejected(target):
    jsonschema = pytest.importorskip("jsonschema")
    schema = json.loads((MANIFEST / "mashup.schema.json").read_text(encoding="utf-8"))
    rel = dict(schema["$defs"]["relPath"], **{"$defs": schema["$defs"]})
    assert list(jsonschema.Draft202012Validator(rel).iter_errors(target)), target


@pytest.mark.parametrize("target", ["mods/hello/hello.txt", "settings.ini", "Content/Paks/~mods/x.txt", "..hidden/x"])
def test_safe_targets_accepted(target):
    jsonschema = pytest.importorskip("jsonschema")
    schema = json.loads((MANIFEST / "mashup.schema.json").read_text(encoding="utf-8"))
    rel = dict(schema["$defs"]["relPath"], **{"$defs": schema["$defs"]})
    assert not list(jsonschema.Draft202012Validator(rel).iter_errors(target)), target

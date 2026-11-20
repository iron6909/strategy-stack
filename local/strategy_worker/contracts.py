"""Dispatch boundary. Repository paths and executable commands come from operator config."""

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re


class Invalid(ValueError):
    pass


def identifier(value, field):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,95}", value):
        raise Invalid(f"invalid {field}")
    return value


def require_text(obj, key, limit=16000):
    value = obj.get(key)
    if not isinstance(value, str) or not value.strip() or len(value) > limit or "\x00" in value:
        raise Invalid(f"invalid {key}")
    return value


def object_json(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise Invalid(f"duplicate key: {key}")
            result[key] = value
        return result

    value = json.loads(raw, object_pairs_hook=unique)
    if not isinstance(value, dict):
        raise Invalid("expected JSON object")
    return value


def read_object(path, limit=128 * 1024):
    with open(path, "rb") as source:
        raw = source.read(limit + 1)
    if len(raw) > limit:
        raise Invalid("JSON exceeds size limit")
    return object_json(raw)


def compact(data):
    return json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


@dataclass(frozen=True)
class Dispatch:
    body: dict

    @classmethod
    def parse(cls, body):
        required = {"schema_version", "kind", "run_id", "attempt", "ticket",
                    "project", "goal", "done_check", "proof", "known_info", "constraints"}
        optional = {"engine", "model", "options"}
        if required - body.keys() or body.keys() - required - optional:
            raise Invalid("unexpected or missing dispatch fields")
        if type(body["schema_version"]) is not int or body["schema_version"] != 1:
            raise Invalid("unsupported schema_version")
        if body["kind"] not in ("code", "production"):
            raise Invalid("invalid kind")
        for key in ("run_id", "ticket", "project"):
            identifier(body[key], key)
        attempt = body["attempt"]
        if type(attempt) is not int or not 1 <= attempt <= 100000:
            raise Invalid("invalid attempt")
        for key in ("goal", "done_check", "proof", "known_info", "constraints"):
            require_text(body, key)
        for key in ("engine", "model"):
            if key in body:
                require_text(body, key, 128)
        if "engine" in body and body["engine"] not in ("pi", "agy", "codex"):
            raise Invalid("unsupported engine")
        if "model" in body and "engine" not in body:
            raise Invalid("model selection requires engine")
        if not isinstance(body.get("options", {}), dict):
            raise Invalid("options must be an object")
        if "hypothesis_id" in body.get("options", {}):
            identifier(body["options"]["hypothesis_id"], "hypothesis_id")
        return cls(body.copy())

    @property
    def digest(self):
        return hashlib.sha256(compact(self.body).encode()).hexdigest()


def arguments(value, field):
    if not isinstance(value, list) or not value or any(
        not isinstance(item, str) or not item or "\x00" in item for item in value
    ):
        raise Invalid(f"{field} must be a nonempty argv array")
    return value


def relative_path(value, field):
    if not isinstance(value, str) or not value or "\x00" in value:
        raise Invalid(f"invalid {field}")
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise Invalid(f"invalid {field}")
    return path

"""Resolve operator selections to engine, CLI model, and verified provider identity."""

from dataclasses import dataclass
import shutil

from .contracts import Invalid

DEFAULTS = {
    "pi": ("deepseek-v4.1-flash", "muse-1.3"),
    "agy": ("Hydrogen", "Carbon", "Neon"),
    "codex": ("terra", "sol"),
}
ROLES = {
    "code": ("pi", "agy"),
    "production": ("agy",),
    "review": ("codex", "agy", "pi"),
}
FAMILIES = {"codex": "openai", "agy": "google"}


@dataclass(frozen=True)
class Model:
    engine: str
    name: str
    cli_model: str
    vendor: str


def candidates(config, role, engine=None, model=None, exclude=(), order=None):
    engines = config.get("engines", {})
    choices = (engine,) if engine else (order or ROLES[role])
    if isinstance(choices, str):
        raise Invalid("engine order must be an array")
    result = []
    for name in choices:
        if name not in DEFAULTS:
            raise Invalid(f"unsupported engine: {name}")
        settings = engines.get(name, {})
        if not settings.get("enabled", False) or not shutil.which(name):
            continue
        if role == "review" and name == "agy" and not settings.get("isolated_review", False):
            continue
        for label in (model,) if model else DEFAULTS[name]:
            entry = settings.get("models", {}).get(label)
            if not entry or entry.get("enabled", True) is False:
                continue
            cli_model, vendor = entry.get("cli_model"), entry.get("vendor", FAMILIES.get(name))
            if not isinstance(cli_model, str) or not cli_model or not isinstance(vendor, str) or not vendor:
                raise Invalid(f"model {name}/{label} needs cli_model and vendor")
            vendor = vendor.casefold()
            if name in FAMILIES and vendor != FAMILIES[name]:
                raise Invalid(f"inconsistent vendor for {name}/{label}")
            if vendor not in exclude:
                result.append(Model(name, label, cli_model, vendor))
    return result

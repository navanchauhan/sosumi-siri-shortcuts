"""bsiri: Minimal helpers to run macOS Shortcuts and compose them.

This package provides a thin wrapper over the `shortcuts` CLI that ships
with macOS (Monterey and later) and a tiny workflow composer to chain
shortcut executions where each step receives the previous step's output.
"""

from .shortcuts import ShortcutsCLI, run_shortcut, sign_shortcut, SIGN_METHOD_LOCAL, SIGN_METHOD_HUBSIGN
from .workflow import Step, Workflow, chain
from .native_actions import list_native_actions

__all__ = [
    "ShortcutsCLI",
    "run_shortcut",
    "sign_shortcut",
    "Step",
    "Workflow",
    "chain",
    "list_native_actions",
]

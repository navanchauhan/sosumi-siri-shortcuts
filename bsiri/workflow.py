from dataclasses import dataclass, field
from typing import Any, Dict, Iterable, List, Optional

from .shortcuts import ShortcutsCLI


@dataclass
class Step:
    """One workflow step mapping to a Shortcut execution.

    - shortcut: shortcut name or identifier to run.
    - input: explicit input payload for this step (overrides input_from_previous).
    - input_from_previous: if True, pass previous step's parsed output as input.
    - extra: optional dict merged with input payload (useful to pass parameters).
    - input_is_text: set to True to write input as plain text instead of JSON.
    - output_type: UTI for expected output. Examples: 'public.json', 'public.plain-text'.
    """

    shortcut: str
    input: Optional[Any] = None
    input_from_previous: bool = False
    extra: Optional[Dict[str, Any]] = None
    input_is_text: bool = False
    output_type: Optional[str] = None
    id: Optional[str] = None


@dataclass
class Workflow:
    steps: List[Step] = field(default_factory=list)

    def run(self) -> List[Any]:
        cli = ShortcutsCLI()
        results: List[Any] = []
        prev: Optional[Any] = None
        for step in self.steps:
            payload: Optional[Any]
            if step.input is not None:
                payload = step.input
            elif step.input_from_previous:
                payload = prev
            else:
                payload = None

            if step.extra:
                # Merge payload and extra into a single JSON object where possible.
                if payload is None:
                    payload = step.extra
                else:
                    if isinstance(payload, dict):
                        merged = dict(payload)
                        merged.update(step.extra)
                        payload = merged
                    else:
                        payload = {"input": payload, **step.extra}

            parsed, _raw = cli.run(
                step.shortcut,
                input=payload,
                input_is_text=step.input_is_text,
                output_type=step.output_type,
            )
            results.append(parsed)
            prev = parsed
        return results


def chain(steps: Iterable[Step]) -> List[Any]:
    return Workflow(list(steps)).run()

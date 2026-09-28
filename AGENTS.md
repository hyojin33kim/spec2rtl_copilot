# Spec2RTL Copilot MVP Project Rules

## Goal

- Preserve the executable trace:
  Spec → Golden Model → RTL → Test → Evidence.
- Keep the current MVP focused on the TX-credit pilot.
- Do not expand into full Harness, AI design, or root-cause analysis without explicit approval.

## Source of truth

- `requirements/`: atomic requirements.
- `trace/`: Spec–Golden–RTL–Test mapping.
- `manifests/`: source catalog, run schema, and integrity metadata.
- `runs/`: generated verification evidence.
- `app/`: local UI and backend.
- `tests/`: acceptance tests.

## Assets and generated results

- Treat imported files under `assets/` as immutable snapshots.
- Do not manually edit files under `runs/`; regenerate evidence through the runner.
- Do not duplicate trace source data in the UI when a manifest reference is available.
- Preserve reproducibility of generated evidence and record meaningful behavior changes.

## Validation

After functional changes, run:

```bash
python3 -m unittest discover -s tests -v
```

To run the local MVP:

```bash
python3 app/backend/server.py
```

For baseline integrity, run:

```bash
sha256sum --check manifests/SHA256SUMS
```

## UI and documentation

- Preserve the Requirement → Spec → Golden → RTL → Test trace flow.
- Keep Golden and RTL source viewers structurally consistent.
- Use `manifests/catalog.json` as the UI view model.
- When visible UI behavior or terminology changes, update `docs/TRACE_EXPLORER_UI_GUIDE.md`.
- When the current UI screenshot changes, update the README image reference.

## Change policy

- Inspect the current files and Git status before editing.
- Prefer small, reversible changes and avoid unrelated files.
- Keep deferred features explicitly marked as deferred.

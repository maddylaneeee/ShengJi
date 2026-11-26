# CI regression tests

CI runs every test in this directory, followed by Release static analysis. There is no separate CI allowlist.

Keep tests when a regression could silently damage user data or when the behavior is easy to miss during agent development:

| Keep | Reason |
| --- | --- |
| Recovery, file replacement, export collisions, audio ownership | Prevent data loss. |
| Cancellation, late callbacks, job ownership, bounded caches | Catch asynchronous and long-session failures. |
| Consent, credential isolation, redirects, filesystem escapes | Protect privacy and trust boundaries. |
| AI fallback, incomplete streams, source identity and timestamps | Keep generated output from corrupting transcripts. |
| Format round trips, Unicode revisions, localization placeholders | Catch subtle cross-format and platform contracts. |

Remove duplicate happy paths, ordinary preference persistence, UI wording and layout, fixed tuning values, timing benchmarks, and model-dependent experiments. These can be checked during the relevant change without permanent CI coverage.

Use scripted generators, loopback HTTP fixtures, and synthetic media. Keep audio format samples representative rather than exhaustive. Add a test only when its failure would expose a distinct, consequential regression; do not add tests just to mirror an implementation change.

# Session-state compare-and-set fixture hotspot decision

Issue #1605. **Keep the compare-and-set fixture together.** The tests exercise one write contract: match the expected state and perform the update atomically, or leave the record untouched. Type validation, nested paths, race handling, and companion writes use the same isolated state and the same production command.

The original report counted #1339 (field-type enforcement), #1573 (three previously uncovered write shapes), and #1595 (composing a compare-and-set with companion writes). The detector excludes the fixture's creation in #1279. The current window since October 26, 2026, at main `e61985b1` has zero touches. The untruncated detector has no entry for the file, and a direct history check from midnight confirms that no change fell below its reporting floor.

A split into validation and race suites could make those sections easier to find, but it would duplicate setup or introduce a common fixture helper. The compound write tests need the same type and failure guarantees as a single write, so there is no current evidence that moving them would isolate churn. The fixture and its implementation stay unchanged.

Reconsider if the cases develop independent setup or recurring conflicts. The baseline schema requires a minimum count of 2, so the entry uses 2 as a floor and records the measured count of zero separately. Score 4 triggers another decision; a qualifying recorded conflict bypasses that threshold.

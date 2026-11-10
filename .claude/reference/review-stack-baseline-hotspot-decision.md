# Review-stack baseline hotspot decision

Issue #1263. **Keep one baseline document for the drift engine.** It is the
record of expected roles, billed state and caps. The audit reads it as a
single versioned input; commentary on past decisions belongs in the
decision records.

The report at filing counted #1206 (creation), #1221, #1230, #1234, and
#1259, with zero recorded conflicts. The current window since October 26,
2026, shows #1951 only, an 82-file Graphite retirement excluded as a
sweep. The detector counts zero.

Preserve the shipped input and drift reader. Revisit if separate
policy owners or recorded conflict cost warrant an input boundary. The
baseline for churn uses the schema floor of 2, separate from the measured
zero; score 4 triggers another look.

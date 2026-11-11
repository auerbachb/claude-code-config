# One proposal per scan. Keep OCR evidence as data and reject malformed inputs.
def int_between($low; $high):
  type == "number" and floor == . and . >= $low and . <= $high;
def clean($max):
  type == "string" and length <= $max and test("[^[:space:]]")
  and (explode | all(. == 9 or . == 10 or (. >= 32 and . != 127)));

if length != 1 then error("expected one proposal") else .[0] end
| select(type == "object")
| select(.scan_sha | type == "string" and test("^[0-9a-f]{64}$"))
| select(.set_id | type == "string" and test("^[1-9][0-9]{0,17}$"))
| select(.entries | type == "array" and length > 0 and length <= 99)
| select(.entries | all(
    (.id | type == "string" and test("^[DR]-[1-9][0-9]{0,18}$"))
    and (.page | int_between(1; 2147483647))
    and (.position | . == null or int_between(1; 32767))
    and (.option | . == null or int_between(1; 26))
    and (.printed_option | . == null or clean(4000))
    and (.comment | . == null or clean(200))
    and (.unreadable | type == "boolean")
    and (.unreadable or .comment != null or .option != null)
    and ((.option == null) == (.printed_option == null))))
| {scan_sha, set_id, entries: [.entries[] |
    {id, page, position, option, printed_option, comment, unreadable}]}

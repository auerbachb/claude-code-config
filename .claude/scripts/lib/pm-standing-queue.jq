def pm_issue_numbers:
  type == "array" and all(.[]; type == "string" and test("^[1-9][0-9]*$"));

def pm_unique_order:
  reduce .[] as $issue ([]; if index($issue) == null then . + [$issue] else . end);

def pm_queue_record:
  type == "object"
  and (.generation | type == "string" and test("^[0-9]+(:[0-9]+){3}$"))
  and (.issues | pm_issue_numbers and . == pm_unique_order);

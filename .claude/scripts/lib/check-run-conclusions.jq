# Completed-check policy shared by aggregate CI and branch protection.
def required_check_passes:
  IN("success", "neutral", "skipped");

def optional_check_passes:
  required_check_passes or . == "cancelled";

def completed_check:
  .status == "completed";

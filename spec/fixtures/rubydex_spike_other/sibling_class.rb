# frozen_string_literal: true

# This file is in a sibling directory that shares a prefix with rubydex_spike
# but is NOT a subdirectory. This tests Pathname-based containment checking.

class SiblingClass
  def sibling_method
    'sibling_result'
  end
end

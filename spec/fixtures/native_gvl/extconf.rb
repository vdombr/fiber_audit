# frozen_string_literal: true

require 'mkmf'

abort 'ruby/thread.h is unavailable' unless have_header('ruby/thread.h')
abort 'nanosleep is unavailable' unless have_func('nanosleep', 'time.h')

create_makefile('fiber_audit_native_gvl')

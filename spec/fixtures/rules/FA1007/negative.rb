# frozen_string_literal: true

# Wrong methods - should not match
Net::HTTP.get_print('example.com', '/path')
Net::HTTP.post('example.com', '/path', 'data')
Net::HTTP.put('example.com', '/path', 'data')
Net::HTTP.delete('example.com', '/path')

# Wrong receiver constants - should not match
String.get
Array.get_response
Hash.start
Object.request
Thread.open
IO.open

# URI/OpenURI with non-http schemes - should be skipped
URI.open('ftp://example.com/file.txt')
URI.open('file:///tmp/local_file.txt')
URI.open('mailto:user@example.com')
OpenURI.open_uri('ftp://example.com/file.txt')
OpenURI.open_uri('file:///tmp/local_file.txt')

# URI methods that should not match
URI.parse('http://example.com')
URI.join('http://example.com', '/path')
URI.encode('http://example.com')

# OpenURI methods that should not match
OpenURI.some_other_method

# Context filtering - these would match if in request context,
# but fixtures are analyzed without context, so they won't emit
# (The extractor doesn't set execution_context, so these are :unknown)

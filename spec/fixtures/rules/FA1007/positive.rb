# frozen_string_literal: true

# Net::HTTP methods that should trigger findings
Net::HTTP.get('example.com', '/path')
Net::HTTP.get_response('example.com', '/path')
Net::HTTP.start('example.com') { |http| http.request(Net::HTTP::Get.new('/')) }
Net::HTTP.request(Net::HTTP::Get.new('/'))

# URI.open with http/https schemes should trigger findings
URI.open('http://example.com/data')
URI.open('https://example.com/data')

# OpenURI.open_uri with http/https schemes should trigger findings
OpenURI.open_uri('http://example.com/data')
OpenURI.open_uri('https://example.com/data')

# URI.open with variable (unknown) should trigger findings
url = 'http://example.com'
URI.open(url)

# URI.open with no arguments should trigger findings
URI.open

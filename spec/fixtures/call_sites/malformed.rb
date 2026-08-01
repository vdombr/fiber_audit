# This is a malformed Ruby file
class BrokenClass
  def broken_method
    puts 'start'
    # Missing end statement - syntax error
    Open3.capture3('test')


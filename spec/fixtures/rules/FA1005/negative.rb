# frozen_string_literal: true

# Negative fixture for FA1005 - Patterns that should NOT be detected

# Wrong method on IO — should not match
IO.read('file.txt')
IO.copy_stream('src', 'dst')
IO.write('file.txt', 'data')

# Wrong method on Kernel — should not match
Kernel.puts('hello')
Kernel.caller
Kernel.exit

# Wrong receiver — should not match
MyIO.select([read_io])
CustomKernel.select([read_io])
SomeModule.select

# Bare method that is not select — should not match
sleep(1)

#!/usr/bin/env ruby
# Passes MIDI data through, with velocities, note numbers, pitch bend, and CC
# values reversed (unless multiple events are delivered at the same time).
#
# Example: ./bin/midi_invert.rb
# Example: ./bin/midi_invert.rb jack-keyboard:midi_out zynaddsubfx:midi_input

require 'bundler/setup'
require 'mb-sound-jackffi'

jack = MB::Sound::JackFFI[]

input = jack.input(port_type: :midi, port_names: ['midi_in'], connect: ARGV[0])
output = jack.output(port_type: :midi, port_names: ['midi_out'], connect: ARGV[1])

loop do
  event = input.read[0]

  if event.length == 3
    bytes = event.bytes
    case bytes[0]
    when 0x80, 0x90
      # Note On/Note Off
      bytes[1] = 127 - bytes[1] # Note number
      bytes[2] = 127 - bytes[2] # Velocity

    when 0xe0
      # Pitch bend
      bytes[1] = 127 - bytes[1] # Note number
      bytes[2] = 127 - bytes[2] # Velocity

    when 0xb0
      # CC
      bytes[2] = 127 - bytes[2] # CC value
    end

    event = bytes.pack('C*')
  end

  puts event.bytes.inspect
  output.write([event])
end

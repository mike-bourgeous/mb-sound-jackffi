#!/usr/bin/env ruby
# Passes unmodified MIDI data from an input port to an output port.  If
# arguments are given, then the input and output ports will be connected to
# other MIDI ports with the given names.
#
# Example: ./bin/midi_thru.rb jack-keyboard:midi_out zynaddsubfx:midi_input

require 'bundler/setup'
require 'mb-sound-jackffi'

jack = MB::Sound::JackFFI[]

input = jack.input(port_type: :midi, port_names: ['midi_in'], connect: ARGV[0])
output = jack.output(port_type: :midi, port_names: ['midi_out'], connect: ARGV[1])

loop do
  event = input.read
  puts event[0].bytes.inspect
  output.write(event)
end

#!/usr/bin/env ruby
# Passes audio directly from input ports to output ports, with a 180 degree
# phase inversion.

require "bundler/setup"
require 'mb-sound-jackffi'

channels = ARGV[0]&.to_i || 2
puts "Running with #{channels} channels"

jack = MB::Sound::JackFFI['invert']

input = jack.input(channels: channels)
output = jack.output(channels: channels)

loop do
  output.write(input.read.map { |c| -(c.inplace) })
end

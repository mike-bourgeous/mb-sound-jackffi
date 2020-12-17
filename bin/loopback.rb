#!/usr/bin/env ruby
# Passes audio directly from input ports to output ports unmodified.

require "bundler/setup"
require 'mb-sound-jackffi'

channels = ARGV[0]&.to_i || 2
puts "Running with #{channels} channels"

jack = MB::Sound::JackFFI[client_name: 'loopback']

input = jack.input(channels: channels)
output = jack.output(channels: channels)

loop do
  output.write(input.read)
end

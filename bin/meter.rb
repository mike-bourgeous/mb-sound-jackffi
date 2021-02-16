#!/usr/bin/env ruby
# Draws ultra barebones meters on the console.  Specify a client name as the
# first argument, or omit it to try to connect to the system's physical
# recording ports.

require "bundler/setup"
require 'mb-sound-jackffi'

jack = MB::Sound::JackFFI[File.basename($0)]
input = jack.input(connect: ARGV[0] || :physical)

sys_cols = ENV['COLUMNS']&.to_i || 80

puts "\n" * input.channels

loop do
  # One asterisk per decibel, one line per channel
  connections = input.connections
  max_length = connections.flatten.map(&:length).max
  cols = sys_cols - max_length
  bars = input.read.map.with_index { |c, idx|
    name = connections[idx]&.last || '[disconnected]'
    name += '(+)' if connections[idx]&.length > 1
    name.ljust(max_length + 4) + '*' * [(20 * Math.log10(c.abs.max) + cols), 0].max + "\e[K"
  }.join("\n")
  puts "\e[#{input.channels}A#{bars}"
end

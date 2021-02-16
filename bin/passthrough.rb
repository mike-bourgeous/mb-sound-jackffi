#!/usr/bin/env ruby
# Passes unmodified audio directly from input ports to output ports.

require "bundler/setup"
require 'mb-sound-jackffi'

channels = ARGV[0]&.to_i || 2
puts "Running with #{channels} channels"

jack = MB::Sound::JackFFI['passthrough']

input = jack.input(channels: channels)
output = jack.output(channels: channels)

puts "\n" * channels

loop do
  STDOUT.write "\e[#{channels}A"
  input.connections.each.with_index do |in_cnx, idx|
    out_cnx = output.connections[idx]
    puts "#{in_cnx.join(';')} => #{out_cnx.join(';')}\e[K"
  end

  output.write(input.read)
end

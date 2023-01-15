#!/usr/bin/env ruby
# Prints information about a given port by name regex, or about all ports on
# the system if no name is given.
#
# Examples:
#     bin/port_info.rb '.*midi.*'
#     bin/port_info.rb
#     bin/port_info.rb 'system:capture_1'

require 'bundler/setup'
require 'mb-sound-jackffi'
require 'mb-util'

jack = MB::Sound::JackFFI[]
jack.find_ports(ARGV[0] && "^#{ARGV[0]}$", port_type: nil).map(&jack.method(:port_info)).each do |inf|
  puts "\e[1;36m#{inf[:name]}\e[0m"
  inf.each do |k, v|
    case v
    when Array
      puts "    \e[1;35m#{k}\e[22m (#{v.count}):\e[0m\n        #{v.join("\n        ")}".strip

    when Symbol
      puts "    \e[1;35m#{k}:\e[0m #{MB::U.highlight(v)}"

    else
      puts "    \e[1;35m#{k}:\e[0m #{v}"
    end
  end

  puts
end

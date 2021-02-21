module MB
  module Sound
    class JackFFI
      # Returned by JackFFI#input.  E.g. use JackFFI['my client'].input(channels: 2)
      # to get two input ports on the client.
      class Input < IOCommon
        # For an audio input, reads one #buffer_size buffer of frames as an
        # Array of Numo::SFloat.
        #
        # For a MIDI input, reads one MIDI event for each port as an Array of
        # Strings.  MIDI events may arrive faster or slower than audio buffers.
        # It is recommended to create only a single MIDI port per Input object
        # for this reason, as this method blocks until *every* port has data.
        #
        # If +:blocking+ is true (the default), this method blocks until data
        # is available for every port.  If false, nil will be returned for any
        # port that doesn't have any data available.
        #
        # Any frame count parameter is ignored, as JACK operates in lockstep with
        # a fixed buffer size.  The returned Array will have one element for each
        # input port.
        def read(_ignored = nil, blocking: true)
          @jack_ffi.read_ports(@ports, blocking: blocking)
        end

        # Connects this input object's port with the given name or at the given
        # index to the given JACK output port.
        def connect(name_or_index, output_port_name)
          port = get_port(name_or_index)
          raise "Port #{name_or_index} not found on this input object" unless port

          @jack_ffi.connect_ports(output_port_name, port)
        end

        # Connects this input's ports to the output ports on the given client
        # name if given a String, or to the given list of ports (which may
        # contain nested arrays to connect one port to multiple ports, or nil
        # to skip wiring a port).  If there are too many or too few ports, then
        # extra ports on either side will be left unconnected.
        def connect_all(client_name_or_ports)
          case client_name_or_ports
          when String
            raise 'Client name to connect must not include a colon' if client_name_or_ports.include?(':')
            new_ports = @jack_ffi.find_ports("^#{client_name_or_ports}:", port_type: @port_type, output: true)

          when Array
            new_ports = client_name_or_ports

          else
            raise 'Pass an Array of port names (which may contain nested Arrays) or a String client name'
          end

          [new_ports.length, @ports.length].min.times do |idx|
            output = new_ports[idx]
            input = @ports[idx]

            next if output.nil?

            @jack_ffi.connect_ports(output, input)
          end
        end
      end
    end
  end
end

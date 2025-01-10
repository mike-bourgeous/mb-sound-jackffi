module MB
  module Sound
    class JackFFI
      # Returned by JackFFI#output.  E.g. use JackFFI['my client'].output(channels: 2)
      # to get two output ports on the client.
      class Output < IOCommon
        # Indicates to other MB::Sound code that this output can only handle
        # writes of exactly #buffer_size frames.
        def strict_buffer_size
          true
        end

        # Writes the given Array of data arrays (Numo::SFloat recommended for
        # audio ports).  The Array should contain one element for each output
        # port.
        def write(data)
          @jack_ffi.write_ports(@ports, data)
        end

        # Connects this output object's port with the given name or at the
        # given index to the given JACK input port.
        def connect(name_or_index, input_port_name)
          port = get_port(name_or_index)
          raise "Port #{name_or_index} not found on this output object" unless port

          @jack_ffi.connect_ports(port, input_port_name)
        end

        # Connects this output's ports to the input ports on the given client
        # name if given a String, or to the given list of ports (which may
        # contain nested arrays to connect one port to multiple ports, or nil
        # to skip wiring a port).  If there are too many or too few ports, then
        # extra ports on either side will be left unconnected.
        def connect_all(client_name_or_ports)
          case client_name_or_ports
          when String
            raise 'Client name to connect must not include a colon' if client_name_or_ports.include?(':')
            new_ports = @jack_ffi.find_ports("^#{client_name_or_ports}:", port_type: @port_type, input: true)

          when Array
            new_ports = client_name_or_ports

          else
            raise 'Pass an Array of port names (which may contain nested Arrays) or a String client name'
          end

          [new_ports.length, @ports.length].min.times do |idx|
            output = @ports[idx]
            input = new_ports[idx]

            next if input.nil?

            @jack_ffi.connect_ports(output, input)
          end
        end
      end
    end
  end
end

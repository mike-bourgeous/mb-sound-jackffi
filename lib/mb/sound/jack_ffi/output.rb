module MB
  module Sound
    class JackFFI
      # Returned by JackFFI#output.  E.g. use JackFFI[client_name: 'my
      # client'].output(channels: 2) to get two output ports on the client.
      class Output
        extend Forwardable

        def_delegators :@jack_ffi, :buffer_size, :rate

        attr_reader :channels, :ports

        # Called by JackFFI to initialize an audio output handle.  You generally
        # won't use this constructor directly.  Instead use JackFFI#output.
        #
        # +:jack_ffi+ - The JackFFI instance that contains this output.
        # +:ports+ - An Array of JACK port names.
        def initialize(jack_ffi:, ports:)
          @jack_ffi = jack_ffi
          @ports = ports
          @channels = ports.length
        end

        # Removes this output object's ports from the client.
        def close
          @jack_ffi.remove(self)
        end

        # Writes the given Array of data (Numo::SFloat recommended).  The Array
        # should contain one element for each output port.
        def write(data)
          @jack_ffi.write_ports(@ports, data)
        end
      end
    end
  end
end

module MB
  module Sound
    class JackFFI
      # Returned by JackFFI#input.  E.g. use JackFFI[client_name: 'my
      # client'].input(channels: 2) to get two input ports on the client.
      class Input
        extend Forwardable

        def_delegators :@jack_ffi, :buffer_size, :rate

        attr_reader :channels, :ports

        # Called by JackFFI to initialize an audio input handle.  You generally
        # won't use this constructor directly.  Instead use JackFFI#input.
        #
        # +:jack_ffi+ - The JackFFI instance that contains this input.
        # +:ports+ - An Array of JACK port names.
        def initialize(jack_ffi:, ports:)
          @jack_ffi = jack_ffi
          @ports = ports
          @channels = ports.length
        end

        # Removes this input object's ports from the client.
        def close
          @jack_ffi.remove(self)
        end

        # Reads one #buffer_size buffer of frames as an Array of Numo::SFloat.
        # Any frame count parameter is ignored, as JACK operates in lockstep with
        # a fixed buffer size.  The returned Array will have one element for each
        # input port.
        def read(_ignored = nil)
          @jack_ffi.read_ports(@ports)
        end
      end

    end
  end
end

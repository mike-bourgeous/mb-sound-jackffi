module MB
  module Sound
    class JackFFI
      # Common code between Input and Output that is unlikely to change or
      # diverge.
      class IOCommon
        extend Forwardable

        def_delegators :@jack_ffi, :buffer_size, :rate
        attr_reader :channels, :ports

        # Called by JackFFI to initialize an input or output.  You generally
        # won't use this constructor directly.  Instead use JackFFI#input and
        # JackFFI#output.
        #
        # +:jack_ffi+ - The JackFFI instance that contains this output.
        # +:ports+ - An Array of JACK port names.
        def initialize(jack_ffi:, ports:)
          @jack_ffi = jack_ffi
          @ports = ports
          @channels = ports.length
          @closed = false
        end

        # Removes this input or output object's ports from the client.
        def close
          @closed = true
          @jack_ffi.remove(self)
        end

        # Returns true if this input or output has been closed.
        def closed?
          @closed
        end

        # Returns the name of the port with the given +name_or_index+, which is
        # either a String for a named port, or an Integer for a port index
        # within this Input.  Returns nil if the name or index wasn't found.
        def get_port(name_or_index)
          if name_or_index.is_a?(Integer)
            @ports[name_or_index]
          else
            @ports.find(name_or_index)
          end
        end
      end
    end
  end
end

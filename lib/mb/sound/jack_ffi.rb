require 'forwardable'
require 'numo/narray'

require_relative 'jack_ffi/jack'
require_relative 'jack_ffi/input'
require_relative 'jack_ffi/output'

module MB
  module Sound
    # This is the base connection to JACK, representing a client_name/server_name
    # pair.  Multiple input and output instances may be created for a single
    # client, which will show up as ports on a single JACK client.
    #
    # Examples (see the README for more examples):
    #
    #     # Create two unconnected input ports (unless JACKFFI_INPUT_CONNECT is set)
    #     MB::Sound::JackFFI[].input(channels: 2)
    #
    #     # TODO: examples, and make sure they work
    #
    # Environment variables:
    #
    # JACK_DEFAULT_SERVER - The name of the JACK server to use ('default') (handled by libjack).
    # JACKFFI_CLIENT_NAME - Overrides the default client name if set.
    # JACKFFI_INPUT_CONNECT - A port connection string to override inputs' +connect+ parameter,
    #                         when +connect+ is nil or :physical.  See #env_or_connect.
    # JACKFFI_OUTPUT_CONNECT - A port connection string to override outputs' +connect+
    #                          parameter, when +connect+ is nil or :physical.
    class JackFFI
      # The default size of the buffer queues for communicating between Ruby and
      # JACK.  This is separate from JACK's own internal buffers.  The
      # :queue_size parameter to #input and #output allows overriding these
      # defaults.
      DEFAULT_QUEUE_SIZE = {
        :JackPortIsInput => {
          Jack::AUDIO_TYPE => 2,
          Jack::MIDI_TYPE => 1000,
        },
        :JackPortIsOutput => {
          Jack::AUDIO_TYPE => 2,
          Jack::MIDI_TYPE => 1000,
        },
      }

      # Retrieves a base client instance for the given client name and server
      # name.
      #
      # Note that if there is already a client with the given name connected to
      # JACK, the client name will be changed by JACK.  Use JackFFI#client_name
      # to get the true client name if needed.  The default client name is
      # based on the application name from +$0+.
      #
      # The JACK_DEFAULT_SERVER environment variable will be used by libjack to
      # select a different server if +server_name+ is not specified.
      #
      # The JACKFFI_CLIENT_NAME environment variable may be used to override the
      # default auto-generated client name.
      def self.[](client_name = nil, server_name: nil)
        client_name ||= ENV['JACKFFI_CLIENT_NAME'] || File.basename($0).gsub(':', '_')
        @instances ||= {}
        @instances[name] ||= new(client_name: client_name, server_name: server_name)
      end

      # Internal API called by JackFFI#close.  Removes an instance of JackFFI
      # that is no longer functioning, so that future calls to JackFFI[] will
      # create a new connection.
      def self.remove(jack_ffi)
        @instances.reject! { |k, v| v == jack_ffi }
      end

      attr_reader :client_name, :server_name, :buffer_size, :rate, :inputs, :outputs

      # An optional object that responds to Logger-style methods like #info and
      # #error.
      attr_accessor :logger

      # Generally you don't need to create a JackFFI instance yourself.  Instead,
      # use JackFFI[] (the array indexing operator) to retrieve a connection, and
      # JackFFI#input and JackFFI#output to get an input or output object with a
      # read or write method.
      #
      # You might want to use this class directly if you want to override the
      # #process method to run custom code in the JACK realtime thread instead of
      # reading and writing data through JackFFIInput and JackFFIOutput.
      #
      # Every JackFFI instance lives until the Ruby VM exits, because JACK's
      # callback APIs cause invalid memory accesses (and thus crashes) in the FFI
      # library when the JACK C client is shut down.
      def initialize(client_name: 'ruby', server_name: nil)
        @client_name = client_name || 'ruby'
        @server_name = server_name

        @run = true

        # Port maps use the port name as key, with a Hash as value.  See #create_io.
        @input_ports = {}
        @output_ports = {}

        @inputs = []
        @outputs = []

        # Monotonically increasing indices used to number prefix-named ports.
        @port_indices = {
          JackPortIsInput: 1,
          JackPortIsOutput: 1,
        }

        @init_mutex = Mutex.new

        @init_mutex.synchronize {
          status = Jack::JackStatusWrapper.new
          @client = Jack.jack_client_open(
            client_name,
            server_name ? :JackServerName : 0,
            status,
            :string, server_name
          )

          if @client.nil? || @client.null?
            raise "Failed to open JACK client; status: #{status[:status]}"
          end

          if status[:status].include?(:JackServerStarted)
            log "Server was started as a result of trying to connect"
          end

          @client_name = Jack.jack_get_client_name(@client)
          if status[:status].include?(:JackNameNotUnique)
            log "Server assigned a new client name (replacing #{client_name.inspect}): #{@client_name.inspect}"
          end

          @buffer_size = Jack.jack_get_buffer_size(@client)
          @rate = Jack.jack_get_sample_rate(@client)
          @zero = Numo::SFloat.zeros(@buffer_size)

          @process_handle = method(:process) # Assigned to variable to prevent GC
          result = Jack.jack_set_process_callback(@client, @process_handle, nil)
          raise "Error setting JACK process callback: #{result}" if result != 0

          @shutdown_handle = method(:shutdown)
          Jack.jack_on_shutdown(@client, @shutdown_handle, nil)

          # TODO: Maybe set a buffer size callback

          result = Jack.jack_activate(@client)
          raise "Error activating JACK client: #{result}" if result != 0
        }

      rescue Exception
        close if @client
        raise
      end

      # Returns a new JackFFI::Input and creates corresponding new input ports on
      # the JACK client.
      #
      # If +:port_names+ is a String, then it is used as a prefix to create
      # +:channels+ numbered ports.  If +:port_names+ is an Array of Strings,
      # then those port names will be created directly without numbering.
      #
      # If +:connect+ is specified, then +:channels+ may be omitted and the
      # number of connection ports will be used as the number of channels to
      # create.  If an Array of port names is specified, then all of those
      # ports will be created regardless of the number of +:connect+ ports.
      #
      # Port names must be unique across all inputs and outputs.
      #
      # See the JackFFI class documentation for examples.
      #
      # +:channels+ - The number of ports to create if +:port_names+ is a
      #               String.  This may be omitted if :connect is provided.
      # +:port_names+ - A String (without a trailing underscore) to create
      #                 prefixed and numbered ports, or an Array of Strings to
      #                 create a list of ports directly by name.
      # +:connect+ - A String with a single port name like "client:port", a
      #              String with a client name like "system", an Array of port
      #              name strings like +["system:playback_1",
      #              "system:playback_4"]+, or the Symbol :physical to connect
      #              to all available physical recording ports.  If this is nil
      #              or :physical, then the JACKFFI_INPUT_CONNECT environment
      #              variable may be used to provide a different connection
      #              String.
      # +:queue_size+ - Optional: number of audio buffers to hold between Ruby
      #                 and the JACK thread (higher means more latency but less
      #                 risk of dropouts).  See DEFAULT_QUEUE_SIZE for
      #                 defaults.  Sane values range from 1 to 4 for audio.
      def input(channels: nil, port_names: 'in', port_type: :audio, connect: nil, queue_size: nil)
        create_io(
          channels: channels,
          port_names: port_names,
          connect: env_or_connect(connect, true),
          portmap: @input_ports,
          port_type: port_type,
          jack_direction: :JackPortIsInput,
          queue_size: queue_size,
          io_class: Input
        ).tap { |io| @inputs << io }
      end

      # Returns a new JackFFI::Input and creates corresponding new input ports on
      # the JACK client.
      #
      # Parameters are the same as for #input, but with the default for
      # +:queue_size+ being OUTPUT_QUEUE_SIZE, and with :connect connecting to
      # playback ports (instead of recording ports) for the special value
      # :physical.  As with #input, the JACKFFI_OUTPUT_CONNECT environment
      # variable will override connections when +connect+ is either nil or
      # :physical.
      #
      # See the JackFFI class documentation for examples.
      def output(channels: nil, port_names: 'out', port_type: :audio, connect: nil, queue_size: nil)
        create_io(
          channels: channels,
          port_names: port_names,
          connect: env_or_connect(connect, false),
          portmap: @output_ports,
          port_type: port_type,
          jack_direction: :JackPortIsOutput,
          queue_size: queue_size,
          io_class: Output
        ).tap { |io| @outputs << io }
      end

      # Finds audio ports with names matching the given regular expression, and
      # having the given set of JACK port flags.  If the +name_regex+ is nil or
      # an empty string, then all ports matching the given flags will be
      # returned.  If +flags+ is 0, an empty array, or nil, then all ports
      # matching the given regex will be returned.
      #
      # Returns an Array of Strings with port names, sorted by client name
      # (JACK's port order within a client will be preserved).  The Array will
      # be empty if there were no matching ports found (or if JACK encountered
      # an error).
      #
      # JACK full port names look like "client_name:port_name".
      #
      # +name_regex+ - A regular expression (as String) to use for filtering
      #                port names, or nil to skip filtering by name.
      # +:port_type+ - A regular expression (as String) to use for filtering
      #                port types, or nil to return all types.  You may also
      #                pass :audio for audio, or :midi for MIDI.  Defaults to
      #                :audio.  See Jack::PORT_TYPES.
      # +:input+ - If true, will only return input ports.
      # +:output+ - If true, will only return output ports.  If both :input and
      #             :output are true, then no ports will be returned.
      # +:physical+ - If true, will only return physical ports.  This may be
      #               combined with :input to get playback ports, or :output to
      #               get recording ports.
      #
      # Examples:
      #
      #     # Find all physical playback ports (they are "inputs" within JACK,
      #     # outputs on the hardware)
      #     MB::Sound::JackFFI[].find_ports(input: true, physical: true)
      #     # => ["system:playback_1", ...]
      #
      #     # Find all ports on a named client
      #     MB::Sound::JackFFI[].find_ports('^some_client_name:')
      #     # => ["some_client_name:in_1", ...]
      #
      #     # Find all ports
      #     MB::Sound::JackFFI[].find_ports
      #     # => [...]
      def find_ports(name_regex = nil, port_type: :audio, input: nil, output: nil, physical: nil)
        flags = []
        flags << :JackPortIsInput if input
        flags << :JackPortIsOutput if output
        flags << :JackPortIsPhysical if physical

        if port_type.is_a?(Symbol)
          type_regex = Jack::PORT_TYPES[port_type] || raise("Invalid port type #{port_type}")
        else
          type_regex = port_type
        end

        port_names = Jack.jack_get_ports(@client, name_regex, type_regex, flags)
        return [] if port_names.nil? || port_names.null?

        ports = []

        current_name = FFI::Pointer.new(port_names)
        while !current_name.read_pointer.null?
          ports << current_name.read_pointer.read_string
          current_name += FFI::Type::POINTER.size
        end

        ports.sort_by! { |name| name.split(':', 2)[0] }
      ensure
        Jack.jack_free(port_names) unless port_names.nil? || port_names.null?
      end

      # Connects any JACK input port (not just from this client) to any output
      # port by name.  If names do not include a client name (if they do not
      # contain a colon ':' character), then they will be prefixed with the
      # name of this client.  Either parameter may be an Array to specify more
      # than one port.  If both parameters are Arrays, then every source port
      # will be wired to every destination port.
      def connect_ports(source_port, destination_port)
        if source_port.is_a?(Array)
          source_port.each do |src|
            connect_ports(src, destination_port)
          end
        elsif destination_port.is_a?(Array)
          destination_port.each do |dest|
            connect_ports(source_port, dest)
          end
        else
          source_port = "#{@client_name}:#{source_port}" unless source_port.include?(':')
          destination_port = "#{@client_name}:#{destination_port}" unless destination_port.include?(':')
          result = Jack.jack_connect(@client, source_port, destination_port)
          raise "Error connecting #{source_port.inspect} to #{destination_port.inspect}: #{result}" if result != 0
        end
      end

      # TODO: Disconnection?  Need to think about ideal API

      # Internal API used by JackFFI::Input#close and JackFFI::Output#close.
      # Removes all of a given input's or output's ports from the client.
      def remove(input_or_output)
        case input_or_output
        when Input
          portmap = @input_ports
          @inputs.delete(input_or_output)

        when Output
          portmap = @output_ports
          @outputs.delete(input_or_output)
        end

        input_or_output.ports.each do |name|
          port_info = portmap.delete(name)
          if port_info
            result = Jack.jack_port_unregister(@client, port_info[:port_id])
            error "Error unregistering port #{port_info[:name]}: #{result}" if result != 0
          end
        end
      end

      # This generally doesn't need to be called.  This method stops background
      # processing, but the JACK thread continues to run because stopping it
      # often causes Ruby to crash with SIGSEGV (Valgrind shows invalid reads
      # when FFI invokes the process callback after jack_deactivate starts).
      def close
        @init_mutex&.synchronize {
          @closed = true
          @run = false
          JackFFI.remove(self)
        }
      end

      # Used internally by JackFFI::Output.
      #
      # Writes the given +data+ to the ports represented by the given Array of
      # port names.  Returns the number of samples written per channel for
      # audio ports, or however many groups of MIDI events were written to the
      # first port for MIDI ports.
      def write_ports(ports, data)
        raise "JACK connection is closed" unless @run

        check_for_processing_error

        # TODO: Maybe support different write sizes by writing into big ring buffers
        raise 'Must supply the same number of data arrays as ports' unless ports.length == data.length

        ports.each_with_index do |name, idx|
          info = @output_ports[name]
          raise "Output port not found: #{name}" unless info

          d = data[idx].not_inplace!
          if info[:port_type] == Jack::AUDIO_TYPE
            raise "Output buffer must be #{@buffer_size} samples long" if d.length != @buffer_size
            d = Numo::SFloat.cast(d) unless d.is_a?(Numo::SFloat) # must pass 32-bit floats to JACK
          end

          info[:queue].push(d)
        end

        data[0].length
      end

      # This is generally for internal use by the JackFFI::Input class.
      #
      # For audio, reads one buffer_size chunk of data for the given Array of
      # port IDs.  For MIDI, reads one raw MIDI event as a String (which may
      # contain multiple MIDI messages) for each port.
      #
      # If +:blocking+ is false, then nil will be returned for any ports that
      # have no data available.  If +:blocking+ is true (the default), then
      # this method will wait for every port to have data available.
      def read_ports(ports, blocking: true)
        raise "JACK connection is closed" unless @run

        check_for_processing_error

        ports.map { |name|
          queue = @input_ports[name][:queue]
          queue.pop(!blocking) if blocking || !queue.empty?
        }
      end

      private

      # If +connect+ is nil or :physical, returns the value of the
      # JACKFFI_(INPUT|OUTPUT)_CONNECT environment variable for the given
      # direction (+is_input+).  If the environment variable is not set, then
      # +connect+ is always returned.
      #
      # Semicolons may be used in the environment variables to separate the
      # connections for individual ports.  Commas may be used to separate
      # multiple connections for a single port.
      def env_or_connect(connect, is_input)
        env = ENV[is_input ? 'JACKFFI_INPUT_CONNECT' : 'JACKFFI_OUTPUT_CONNECT']
        if env && (connect == :physical || connect.nil?)
          if env.include?(',') || env.include?(';')
            return env.split(';').map { |port|
              port.split(',')
            }
          end

          return env
        end

        connect
      end

      # Common code for creating ports tied to IO objects, shared by #input and
      # #output.  API subject to change.
      def create_io(channels:, port_names:, connect:, portmap:, port_type:, jack_direction:, queue_size:, io_class:)
        port_type = Jack::PORT_TYPES[port_type] || port_type || Jack::AUDIO_TYPE

        queue_size ||= DEFAULT_QUEUE_SIZE[jack_direction][port_type]
        raise "Queue size must be positive" if queue_size <= 0

        # Find the number of connections, if given, in case channel count wasn't specified
        is_input = jack_direction == :JackPortIsInput
        case connect
        when :physical
          # Connect to all physical ports
          connect = find_ports(physical: true, input: !is_input, output: is_input)

        when /:/
          # Connect to a single port
          connect = [connect]

        when String
          # Connect to as many ports as possible on a named client
          connect = find_ports("^#{connect}:", input: !is_input, output: is_input)

        when Array, nil
          # Array of port names or no connections; do nothing

        else
          raise ":connect must be a String or an Array, or the special value :physical"
        end

        channels ||= connect&.count

        case port_names
        when Array
          raise "Do not specify :channels when an array of port names is given" if channels && !connect

        when String
          raise ":channels or :connect must be given for prefix-named ports" unless channels.is_a?(Integer)

          port_names = channels.times.map { |c|
            "#{port_names}_#{@port_indices[jack_direction]}".tap { @port_indices[jack_direction] += 1 }
          }

        else
          raise "Pass a String or an Array of Strings for :port_names (received #{port_names.class})"
        end

        if port_names.empty?
          raise "No ports were provided, no connections were possible, and/or no channel count was given"
        end

        port_names.each do |name|
          raise "A port named #{name.inspect} already exists" if @input_ports.include?(name) || @output_ports.include?(name)
        end

        # Use a separate array so that ports can be cleaned up if a later port
        # fails to initialize.
        ports = []

        # TODO: if having one SizedQueue per port is too slow, maybe have one SizedQueue per IO object

        io = io_class.new(jack_ffi: self, ports: port_names)

        port_names.each do |name|
          port_id = Jack.jack_port_register(@client, name, port_type, jack_direction, 0)
          if port_id.nil? || port_id.null?
            ports.each do |p|
              Jack.jack_port_unregister(@client, p[:port])
            end

            raise "Error creating port #{name}"
          end

          ports << {
            name: name,
            io: io,
            port_id: port_id,
            port_type: port_type,
            direction: jack_direction,
            queue: SizedQueue.new(queue_size),
            drops: -1
          }
        end

        ports.each do |port_info|
          portmap[port_info[:name]] = port_info
        end

        io.connect_all(connect) if connect

        io
      end

      def log(msg)
        msg = "JackFFI(#{@server_name}/#{@client_name}): #{msg}"
        if @logger
          @logger.info(msg)
        else
          puts msg
        end
      end

      def error(msg)
        msg = "JackFFI(#{@server_name}/#{@client_name}): Error: #{msg}"
        if @logger
          @logger.error(msg)
        else
          puts "\e[1;31m#{msg}\e[0m"
        end
      end

      def check_for_processing_error
        if @processing_error
          # Re-raise the error so we can set it as the cause on another error
          e = @processing_error
          @processing_error = nil
          begin
            raise e
          rescue
            raise "An error occurred in the processing thread: #{e.message}"
          end
        end
      end

      # Called by JACK within its realtime thread when new audio data should be
      # read and written.  Only the bare minimum of processing should be done
      # here (and really, Ruby itself is not ideal for realtime use).
      def process(frames, user_data)
        @init_mutex&.synchronize {
          return unless @run && @client && @input_ports && @output_ports

          start_frame = Jack.jack_last_frame_time(@client)

          @input_ports.each do |name, port_info|
            # FIXME: Avoid allocation in this function; use a buffer pool or something
            buf = Jack.jack_port_get_buffer(port_info[:port_id], frames)

            queue = port_info[:queue]

            if queue.length == queue.max
              log "Input port #{name} buffer queue is full" if port_info[:drops] == 0
              queue.pop rescue nil
              port_info[:drops] += 1 unless port_info[:drops] < 0
            else
              log "Input port #{name} buffer queue recovered after #{port_info[:drops]} dropped buffers" if port_info[:drops] > 0
              port_info[:drops] = 0
            end

            # TODO: Move conditions outside of loop if this is slow
            case port_info[:port_type]
            when Jack::AUDIO_TYPE
              queue.push(Numo::SFloat.from_binary(buf.read_bytes(frames * 4)), true)

            when Jack::MIDI_TYPE
              Jack.jack_midi_get_event_count(buf).times do |t|
                event = Jack::JackMidiEvent.new
                result = Jack.jack_midi_event_get(event, buf, t)
                # TODO: push time with events
                queue.push(event.data) if result == 0
              end

            else
              raise "Unsupported port type: #{port_info[:port_type]}"
            end
          end

          @output_ports.each do |name, port_info|
            buf = Jack.jack_port_get_buffer(port_info[:port_id], frames)

            queue = port_info[:queue]

            case port_info[:port_type]
            when Jack::AUDIO_TYPE
              data = queue.pop(true) rescue nil unless queue.empty?

              if data.nil? && port_info[:port_type] == Jack::AUDIO_TYPE
                # Only audio has to be written every cycle
                log "Output port #{name} ran out of data to write" if port_info[:drops] == 0
                port_info[:drops] += 1 unless port_info[:drops] < 0
                data = @zero
              else
                log "Output port #{name} recovered after #{port_info[:drops]} missed buffers" if port_info[:drops] > 0
                port_info[:drops] = 0
              end

              buf.write_bytes(data.to_binary)

            when Jack::MIDI_TYPE
              Jack.jack_midi_clear_buffer(buf)

              # TODO: use actual sample offsets instead of just counting up by one sample per event
              current_frame = 0
              while !queue.empty? && current_frame < @buffer_size && Jack.jack_midi_max_event_size(buf) > 200
                event = queue.pop
                result = Jack.jack_midi_event_write(buf, current_frame, event, event.length)
                raise "Could not deliver MIDI event: #{SystemCallError.new(result.abs)}" if result != 0
                #current_frame += 1
              end

            else
              raise "Unsupported port type: #{port_info[:port_type]}"
            end
          end
        }
      rescue Exception => e
        @processing_error = e
        error "Error processing: #{e}"
      end

      # Called when either the JACK server is shut down, or a severe enough
      # client error occurs that JACK kicks the client out of the server.
      def shutdown(user_data)
        return unless @client

        log "JACK is shutting down"
        @run = false

        # Can't close JACK from within its own shutdown callback
        Thread.new do sleep 0.25; close end
      rescue
        nil
      end
    end
  end
end

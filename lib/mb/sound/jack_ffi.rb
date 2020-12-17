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
    # Examples:
    #
    #     # Create two unconnected input ports
    #     MB::Sound::JackFFI[].input(channels: 2)
    #
    #     # TODO: examples, and make sure they work
    #
    # TODO: Maybe support environment variables for client name, server name, port names, etc.
    # TODO: Support connecting ports after creating them
    class JackFFI
      # The default size of the buffer queues for communicating between Ruby and
      # JACK.  This is separate from JACK's own internal buffers.  The
      # :queue_size parameter to #input and #output allows overriding these
      # defaults.
      INPUT_QUEUE_SIZE = 2
      OUTPUT_QUEUE_SIZE = 2

      # Retrieves a base client instance for the given client name and server
      # name.
      #
      # Note that if there is already a client with the given name connected to
      # JACK, the client name will be changed by JACK.  Use JackFFI#client_name
      # to get the true client name if needed.
      def self.[](client_name: 'ruby', server_name: nil)
        @instances ||= {}
        @instances[name] ||= new(client_name: client_name, server_name: server_name)
      end

      # Internal API called by JackFFI#close.  Removes an instance of JackFFI
      # that is no longer functioning, so that future calls to JackFFI[] will
      # create a new connection.
      def self.remove(jack_ffi)
        @instances.reject! { |k, v| v == jack_ffi }
      end

      attr_reader :client_name, :server_name, :buffer_size, :rate

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

        # Montonically increasing indices used to number prefix-named ports.
        @port_indices = {
          JackPortIsInput: 0,
          JackPortIsOutput: 0,
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
      # +channels+ numbered ports.  If +:port_names+ is an Array of Strings, then
      # those port names will be created directly without numbering.
      #
      # Port names must be unique.
      #
      # +:channels+ - The number of ports to create if +:port_names+ is a String.
      # +:port_names+ - A String (without a trailing underscore) to create
      #                 prefixed and numbered ports, or an Array of Strings to
      #                 create a list of ports directly by name.
      # +:connections+ - TODO (maybe String client name, maybe list of ports)
      # +:queue_size+ - Optional: number of audio buffers to hold between Ruby
      #                 and the JACK thread (higher means more latency but less
      #                 risk of dropouts).  Default is INPUT_QUEUE_SIZE.  Sane
      #                 values range from 1 to 4.
      def input(channels: nil, port_names: 'in', connections: nil, queue_size: nil)
        create_io(
          channels: channels,
          port_names: port_names,
          connections: connections,
          portmap: @input_ports,
          jack_direction: :JackPortIsInput,
          queue_size: queue_size || INPUT_QUEUE_SIZE,
          io_class: Input
        )
      end

      # Returns a new JackFFI::Input and creates corresponding new input ports on
      # the JACK client.
      #
      # Parameters are the same as for #input, with the default for +:queue_size+
      # being OUTPUT_QUEUE_SIZE.
      def output(channels: nil, port_names: 'out', connections: nil, queue_size: nil)
        create_io(
          channels: channels,
          port_names: port_names,
          connections: connections,
          portmap: @output_ports,
          jack_direction: :JackPortIsOutput,
          queue_size: queue_size || OUTPUT_QUEUE_SIZE,
          io_class: Output
        )
      end

      # Internal API used by JackFFI::Input#close and JackFFI::Output#close.
      # Removes all of a given input's or output's ports from the client.
      def remove(input_or_output)
        case input_or_output
        when Input
          portmap = @input_ports

        when Output
          portmap = @output_ports
        end

        input_or_output.ports.each do |name|
          port_info = portmap.delete(name)
          if port_info
            result = Jack.jack_port_unregister(@client, port_info[:port_id])
            log "Error unregistering port #{port_info[:name]}: #{result}" if result != 0
          end
        end
      end

      # This generally doesn't need to be called.  This method stops background
      # processing, but the JACK thread continues to run because stopping it
      # often causes Ruby to crash with SIGSEGV (Valgrind shows invalid reads
      # when FFI invokes the process callback after jack_deactivate starts).
      def close
        @init_mutex&.synchronize {
          @run = false
          JackFFI.remove(self)
        }
      end

      # Writes the given +data+ to the ports represented by the given Array of
      # port IDs.  Used internally by JackFFI::Output.
      def write_ports(ports, data)
        raise "JACK connection is closed" unless @run

        check_for_processing_error

        # TODO: Maybe support different write sizes by writing into big ring buffers
        raise 'Must supply the same number of data arrays as ports' unless ports.length == data.length
        raise "Output buffer must be #{@buffer_size} samples long" unless data.all? { |c| c.length == @buffer_size }

        ports.each_with_index do |name, idx|
          @output_ports[name][:queue].push(data[idx])
        end

        nil
      end

      # Reads one buffer_size chunk of data for the given Array of port IDs.
      # This is generally for internal use by the JackFFI::Input class.
      def read_ports(ports)
        raise "JACK connection is closed" unless @run

        check_for_processing_error

        ports.map { |name|
          @input_ports[name][:queue].pop
        }
      end

      private

      # Common code for creating ports shared by #input and #output.  API subject to change.
      def create_io(channels:, port_names:, connections:, portmap:, jack_direction:, queue_size:, io_class:)
        raise "Queue size must be positive" if queue_size <= 0

        case port_names
        when Array
          raise "Do not specify a channel count when an array of port names is given" if channels

        when String
          raise "Channel count must be given for prefix-named ports" unless channels.is_a?(Integer)

          port_names = channels.times.map { |c|
            "#{port_names}_#{@port_indices[jack_direction]}".tap { @port_indices[jack_direction] += 1 }
          }

        else
          raise "Pass a String or an Array of Strings for :port_names (received #{port_names.class})"
        end

        port_names.each do |name|
          raise "Port #{name} already exists" if portmap.include?(name)
        end

        # Use a separate array so that ports can be cleaned up if a later port
        # fails to initialize.
        ports = []

        # TODO: if having one SizedQueue per port is too slow, maybe have one SizedQueue per IO object

        io = io_class.new(jack_ffi: self, ports: port_names)

        port_names.each do |name|
          port_id = Jack.jack_port_register(@client, name, Jack::AUDIO_TYPE, jack_direction, 0)
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
            queue: SizedQueue.new(queue_size),
            drops: 0
          }
        end

        ports.each do |port_info|
          portmap[port_info[:name]] = port_info
        end

        # TODO Connections
        raise NotImplementedError if connections

        io
      end

      def log(msg)
        puts "JackFFI(#{@server_name}/#{@client_name}): #{msg}"
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

          @input_ports.each do |name, port_info|
            # FIXME: Avoid allocation in this function; use a buffer pool or something
            buf = Jack.jack_port_get_buffer(port_info[:port_id], frames)

            queue = port_info[:queue]

            if queue.length == queue.max
              log "Input port #{name} buffer queue is full" if port_info[:drops] == 0
              queue.pop rescue nil
              port_info[:drops] += 1
            else
              log "Input port #{name} buffer queue recovered after #{port_info[:drops]} dropped buffers" if port_info[:drops] > 0
              port_info[:drops] = 0
            end

            queue.push(Numo::SFloat.from_binary(buf.read_bytes(frames * 4)), true)
          end

          @output_ports.each do |name, port_info|
            queue = port_info[:queue]
            data = queue.pop(true) rescue nil unless queue.empty?
            if data.nil?
              log "Output port #{name} ran out of data to write" if port_info[:drops] == 0
              port_info[:drops] += 1
              data = @zero
            else
              log "Output port #{name} recovered after #{port_info[:drops]} dropped buffers" if port_info[:drops] > 0
              port_info[:drops] = 0
            end

            buf = Jack.jack_port_get_buffer(port_info[:port_id], frames)
            buf.write_bytes(data.to_binary)
          end
        }
      rescue => e
        @processing_error = e
        log "Error processing: #{e}"
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

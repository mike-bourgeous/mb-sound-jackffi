require 'ffi'

module MB
  module Sound
    class JackFFI
      # Raw FFI interface to JACK.  Don't use this directly; instead use
      # JackFFI[] to retrieve a connection, and JackFFI#input or JackFFI#output
      # to create input or output ports.
      #
      # References:
      #
      # https://github.com/jackaudio/jack2/blob/b2ba349a4eb4c9a5a51dbc7a7af487851ade8cba/example-clients/simple_client.c
      # https://jackaudio.org/api/simple__client_8c.html#a0ddf1224851353fc92bfbff6f499fa97
      # https://github.com/ffi/ffi/blob/6d31bf845e6527cc7f67d236a95c0161df969b12/lib/ffi/library.rb#L515
      # https://github.com/ffi/ffi/blob/f7c5b607e07b7f00e3c7a46f427c76cad65fbb78/ext/ffi_c/FunctionInfo.c
      # https://github.com/ffi/ffi/wiki/Pointers
      module Jack
        extend FFI::Library
        ffi_lib ['jack', 'libjack.so.0.1.0', 'libjack.so.0']

        AUDIO_TYPE = "32 bit float mono audio"
        MIDI_TYPE = "8 bit raw midi"

        PORT_TYPES = {
          audio: AUDIO_TYPE,
          midi: MIDI_TYPE,
        }

        PORT_TYPES_BY_NAME = {
          AUDIO_TYPE => :audio,
          MIDI_TYPE => :midi,
        }

        @blocking = true

        bitmask :jack_options_t, [
          :JackNoStartServer,
          :JackUseExactName,
          :JackServerName,
          :JackLoadName,
          :JackLoadInit,
          :JackSessionID,
        ]

        bitmask :jack_status_t, [
          :JackFailure,
          :JackInvalidOption,
          :JackNameNotUnique,
          :JackServerStarted,
          :JackServerFailed,
          :JackServerError,
          :JackNoSuchClient,
          :JackLoadFailure,
          :JackInitFailure,
          :JackShmFailure,
          :JackVersionError,
          :JackBackendError,
          :JackClientZombie,
        ]

        # jack_port_register accepts "unsigned long" for some reason, so make sure this is the right size
        bitmask FFI::Type::ULONG, :jack_port_flags, [
          :JackPortIsInput,
          :JackPortIsOutput,
          :JackPortIsPhysical,
          :JackPortCanMonitor,
          :JackPortIsTerminal,
        ]

        typedef :uint32_t, :jack_nframes_t

        class JackStatusWrapper < FFI::Struct
          layout :status, :jack_status_t
        end

        class JackMidiEvent < FFI::Struct
          layout :time, :jack_nframes_t,
            :size, :size_t,
            :buffer, :pointer

          def time
            self[:time]
          end

          def size
            self[:size]
          end

          def data
            self[:buffer].read_bytes(self[:size])
          end
        end

        # Client management functions
        # Note: jack_deactivate, or if you don't call that, jack_client_close,
        # cause Ruby/FFI to perform invalid reads often, and sometimes crash.
        # It's probably okay to leave the connection to JACK open and let the
        # OS clean up when the application exits.
        typedef :pointer, :jack_client
        attach_function :jack_client_open, [:string, :jack_options_t, JackStatusWrapper.by_ref, :varargs], :jack_client
        attach_function :jack_client_close, [:jack_client], :int
        attach_function :jack_get_client_name, [:jack_client], :string
        attach_function :jack_activate, [:jack_client], :int
        attach_function :jack_deactivate, [:jack_client], :int

        # Server status functions
        attach_function :jack_get_buffer_size, [:jack_client], :jack_nframes_t
        attach_function :jack_get_sample_rate, [:jack_client], :jack_nframes_t
        attach_function :jack_cpu_load, [:jack_client], :float

        # System callback functions
        typedef :pointer, :jack_user_data
        callback :jack_process_callback, [:jack_nframes_t, :jack_user_data], :void
        callback :jack_shutdown_callback, [:jack_user_data], :void
        attach_function :jack_set_process_callback, [:jack_client, :jack_process_callback, :jack_user_data], :int
        attach_function :jack_on_shutdown, [:jack_client, :jack_shutdown_callback, :jack_user_data], :void

        # Port callback functions
        typedef :uint32_t, :jack_port_id
        callback :jack_port_connect_callback, [:jack_port_id, :jack_port_id, :int, :jack_user_data], :void
        callback :jack_port_registration_callback, [:jack_port_id, :int, :jack_user_data], :void
        callback :jack_port_rename_callback, [:jack_port_id, :string, :string, :jack_user_data], :void
        attach_function :jack_set_port_connect_callback, [:jack_client, :jack_port_connect_callback, :jack_user_data], :int
        attach_function :jack_set_port_registration_callback, [:jack_client, :jack_port_registration_callback, :jack_user_data], :int
        attach_function :jack_set_port_rename_callback, [:jack_client, :jack_port_rename_callback, :jack_user_data], :int

        # Port management functions
        typedef :pointer, :jack_port
        typedef :uint64, :jack_uuid
        attach_function :jack_port_register, [:jack_client, :string, :string, :jack_port_flags, :ulong], :jack_port
        attach_function :jack_port_unregister, [:jack_client, :jack_port], :int
        attach_function :jack_port_get_buffer, [:jack_port, :jack_nframes_t], :pointer
        attach_function :jack_get_ports, [:jack_client, :string, :string, :jack_port_flags], :pointer
        attach_function :jack_port_by_id, [:jack_client, :jack_port_id], :jack_port
        attach_function :jack_port_by_name, [:jack_client, :string], :jack_port
        attach_function :jack_port_get_all_connections, [:jack_client, :jack_port], :pointer
        attach_function :jack_port_name, [:jack_port], :string
        attach_function :jack_port_short_name, [:jack_port], :string
        attach_function :jack_port_type, [:jack_port], :string
        attach_function :jack_port_uuid, [:jack_port], :jack_uuid
        attach_function :jack_port_get_aliases, [:jack_port, :pointer], :int
        attach_function :jack_port_name_size, [], :int
        attach_function :jack_port_type_size, [], :int
        attach_function :jack_connect, [:jack_client, :string, :string], :int
        attach_function :jack_disconnect, [:jack_client, :string, :string], :int

        # MIDI functions
        attach_function :jack_midi_get_event_count, [:pointer], :jack_nframes_t
        attach_function :jack_midi_event_get, [JackMidiEvent.by_ref, :pointer, :uint32_t], :int
        attach_function :jack_midi_clear_buffer, [:pointer], :void
        attach_function :jack_midi_max_event_size, [:pointer], :size_t
        attach_function :jack_midi_event_write, [:pointer, :jack_nframes_t, :pointer, :size_t], :int
        attach_function :jack_midi_get_lost_event_count, [:pointer], :uint32_t

        # Time functions
        attach_function :jack_last_frame_time, [:jack_client], :jack_nframes_t

        # Other functions
        attach_function :jack_free, [:pointer], :void

        # Returns a Ruby Array of Strings from the given char** pointer.
        # Returns an empty array if +pointer+ is Ruby nil, or points to C NULL.
        #
        # This function does not call free() or jack_free().
        def self.get_string_array(pointer)
          list = []

          return list if pointer.nil? || pointer.null?

          current = FFI::Pointer.new(pointer)
          while !current.read_pointer.null?
            list << current.read_pointer.read_string&.force_encoding('UTF-8')
            current += FFI::Type::POINTER.size
          end

          list
        end
      end
    end
  end
end

# mb-sound-jackffi

An *UNSTABLE* (as in it occasionally crashes, hangs, or drops audio) Ruby FFI
interface for the [JACK Audio Connection Kit][1].  I've only tested this on
Linux.

This FFI interface can be used by my [mb-sound][2] gem, a companion library to
an [educational video series I'm making about sound][0].

## Rationale

The [mb-sound][2] gem uses standalone command line tools for playing and
recording audio, via `popen`.  This works well enough, but has high and
unpredictable latency.  Some of the things I want to do with audio and video
will require tighter control over latency and synchronization between audio and
video.

There was another FFI interface for JACK, but the homepage no longer exists and
it hasn't been updated in ages.

## Installation

There are some base packages you'll probably want first, though they might not
be required for your system:

```bash
# Debian-/Ubuntu-based Linux (macOS/Arch/CentOS will differ)
sudo apt-get install libffi-dev
```

Then you'll want to install Ruby 2.7.2 or newer (I recommend
[RVM](https://rvm.io)).

Finally, you can add the Gem (via Git) to your Gemfile:

```ruby
# your-project/Gemfile
gem 'mb-sound-jackffi', git: 'git@github.com:mike-bourgeous/mb-sound-jackffi.git'
```

## Examples

The `MB::Sound::JackFFI` class represents a connection to a JACK server with a
specific client name.  Its `input` and `output` instance methods will create
input or output ports on the JACK client.

```ruby
require 'mb-sound-jackffi' # Or 'mb/sound/jack_ffi'

# Enjoy silence
out = MB::Sound::JackFFI[client_name: 'my app'].output(port_names: ['left', 'right'])
loop do
  out.write([Numo::SFloat.zeros(out.buffer_size)] * out.channels)
end
```

Also check out `bin/loopback.rb` and `bin/invert.rb`.

## Testing

Testing is mostly manual.  I might eventually figure out a way to install jackd
in a CI environment and run loopback tests.  If that happens, you will be able
to run the integrated test suite with `rspec`, but not yet.

## Contributing

Pull requests are welcome.

## License

This project is released under a 2-clause BSD license.  See the LICENSE file.


[0]: https://www.youtube.com/playlist?list=PLpRqC8LaADXnwve3e8gI239eDNRO3Nhya
[1]: https://jackaudio.org
[2]: https://github.com/mike-bourgeous/mb-sound

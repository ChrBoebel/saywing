#!/usr/bin/env ruby
# Real installed worker check. Fixed public text/audio stay in memory only.
require 'open3'
require 'json'
require 'base64'
require 'timeout'
require_relative 'worker_sandbox'

# Default: the Debug development installation. Pass an app's Contents/Resources/Speech folder
# to check a bundled runtime, e.g. /Applications/Saywing.app/Contents/Resources/Speech.
abort 'Usage: ruby scripts/verify-supertonic-worker.rb [SPEECH_ROOT]' if ARGV.length > 1
root = File.expand_path(ARGV[0] || File.join(Dir.home, 'Library/Application Support/OpenScreenReader'))
runtime = File.join(root, 'SupertonicRuntime')
model = File.join(root, 'DevelopmentModels/supertonic-3-3cadd1ee')
# Same layout, sandbox and environment as SpeechRuntimeConfiguration and SpeechWorkerSession.
bundled = File.executable?(File.join(runtime, 'python/bin/python3'))
python = File.join(runtime, bundled ? 'python/bin/python3' : 'venv/bin/python3')
sandbox = WorkerSandbox.command(resources: root, executable: python)
abort 'Missing speech runtime' unless sandbox
environment = { 'PATH' => '/usr/bin:/bin', 'HF_HUB_OFFLINE' => '1', 'HF_HUB_DISABLE_TELEMETRY' => '1' }
options = { unsetenv_others: true, chdir: File.dirname(python) }
base = sandbox + ['-I', '-B']
worker = base + [File.join(runtime, 'worker.py'), '--model', model]
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
first_audio = nil
frames = 0
peak = 0.0
ready = false
complete = false
Open3.popen3(environment, *worker, **options) do |input, output, error, process|
  begin
    Timeout.timeout(90) do
      input.puts(JSON.generate(text: 'Hallo Welt. Dies ist ein lokaler Sprachtest.', language: 'de'))
      input.flush
      while (line = output.gets(140_002))
        abort 'Oversized/truncated packet' if line.bytesize > 140_001 || !line.end_with?("\n")
        packet = JSON.parse(line)
        case packet.fetch('kind')
        when 'ready'
          abort 'Invalid ready' if ready || packet['sampleRate'] != 44_100
          ready = true
        when 'audio'
          abort 'Invalid audio format' unless ready && packet['sampleRate'] == 44_100
          first_audio ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          pcm = Base64.strict_decode64(packet.fetch('pcm'))
          abort 'Invalid PCM size' if pcm.empty? || pcm.bytesize > 96_000 || pcm.bytesize % 4 != 0
          samples = pcm.unpack('e*')
          abort 'Non-finite PCM' unless samples.all?(&:finite?)
          frames += samples.length
          abort 'Exceeded fixture audio bound' if frames > 44_100 * 120
          peak = [peak, samples.map(&:abs).max].max
          input.puts('next')
          input.flush
        when 'end'
          complete = true
          break
        else
          abort "Worker failure: #{packet['code']}"
        end
      end
      input.close
      abort 'Incomplete/silent worker' unless complete && ready && peak > 0.0001 && process.value.success?
      abort 'Unexpected content diagnostics' unless error.read.empty?
    end
  ensure
    Process.kill('KILL', process.pid) if process.alive?
  end
end
puts JSON.generate(first_audio_seconds: first_audio.round(3), audio_seconds: (frames / 44_100.0).round(3), peak: peak.round(4))

invalid_output, invalid_error, status = Open3.capture3(environment, *worker, **options, stdin_data: "{\"text\":\"Private test sentinel\",\"language\":\"invalid\"}\n")
abort 'Invalid request leaked or succeeded' unless !status.success? && invalid_error.empty? && JSON.parse(invalid_output) == {'kind' => 'error', 'code' => 'invalid_request'}

# Verify enforcement, not just the existence of a sandbox profile. No forbidden
# operation transmits content; the connection target is loopback and the read
# target is this script, which lies outside the runtime and model folders.
probe = <<~PYTHON
  import os, socket, sys
  for operation in (
      lambda: socket.create_connection(('127.0.0.1', 9), timeout=1),
      lambda: open('/private/tmp/osr-supertonic-forbidden-write', 'xb'),
      lambda: open(sys.argv[1], 'rb'),
      lambda: os.posix_spawn('/bin/echo', ['/bin/echo'], {}),
  ):
      try:
          operation()
      except PermissionError:
          continue
      raise RuntimeError('Sandbox did not deny operation')
  print('PASS: network, file writes, reads outside the runtime and child processes denied')
PYTHON
abort 'Privacy probe failed' unless system(environment, *base, '-c', probe, File.expand_path(__FILE__), **options)
puts 'PASS: real Supertonic PCM, bounded protocol, coded errors, and privacy enforcement'

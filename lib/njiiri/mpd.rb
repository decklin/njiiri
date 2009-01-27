require 'thread'
require 'rubygems'
require 'librmpd'

class MPD
  def add(path)
    send_command "add \"#{path.gsub('"', '\\"')}\""
  end
  def lsinfo(path = '/', type = :files)
    response = send_command "lsinfo \"#{path}\""
    case type
      when :files
        filter_response response, /\Afile: /i
      when :directories
        filter_response response, /\Adirectory: /i
      when :playlists
        filter_response response, /\Aplaylist: /i
    end
  end
  def listallinfo(path=nil)
    songs(path)
  end
  def playlist_len
    status['playlistlength'].to_i
  end
  def current_time
    status['time'].split(':').collect {|x| x.to_i } rescue [0, 0]
  end
  class Song
    def id; self['id']; end
  end
end

class Server < Struct.new(:host, :port, :password)
  def to_s
    port == 6600 ? host : "#{host}:#{port}"
  end
end

class Njiiri
  # when the librmpd callback thread runs anything below, we don't
  # want it to call into GTK (which is a pain to make thread-safe. You
  # could do it; you could also eat soup with a fork. A good fork). So
  # this stuff just queues up some blocks to be actually executed in
  # the GTK thread. This allows us to cheat (I mean, optimize) a
  # little by only responding to the last event of a given type (in
  # the "slot", which is simply not a list) if several come down the
  # wire between runs of our timer back in the main loop.
  #
  # Still a botch, but I've no time to write a new MPD library. Yet.

  @@callbacks = []

  def schedule(slot, &block)
    @mutex.synchronize { @tasks[slot] = block }
  end

  def pending
    @mutex.synchronize do
      blocks = @@callbacks.collect {|n, t, cb| @tasks[n] }.compact
      @tasks.clear
      return blocks
    end
  end

  def wake
    pending.each {|block| block.call }
  end

  def self.def_cb(name, tag, &block)
    cb = "_cb_#{tag}"
    @@callbacks << [name, tag, cb]
    class_eval do
      define_method name, &block
      define_method cb do |*args|
        schedule(name) do
          begin
            self.send(name, *args)
          rescue RuntimeError => e
            STDERR.puts "Stale callback: #{e}"
          end
        end
      end
    end
  end

  # yes, the order of these is important. unfortunately.

  def_cb :got_connection, MPD::CONNECTION_CALLBACK do |up|
    up ? connected : disconnected('reset by peer')
  end

  def_cb :got_time, MPD::TIME_CALLBACK do |elapsed, total|
    refresh_pos(elapsed, total)
  end

  def_cb :got_song, MPD::CURRENT_SONG_CALLBACK do |current|
    if @cue_next and current
      @mpd.pause = true
      @mpd.seek(current['pos'].to_i, 0)
    end
    @cue_next = @widgets.cue_btn.active = false
    schedule(:got_time) {}
    refresh_info(current)
    refresh_playlist
    refresh_pos(*@mpd.current_time)
    refresh_state(@mpd.status['state'])
  end

  def_cb :got_state, MPD::STATE_CALLBACK do |state|
    refresh_state(state)
  end

  def_cb :got_playlist, MPD::PLAYLIST_CALLBACK do |version|
    rebuild_playlist(version)
    refresh_playlist
    refresh_detail
  end

  def_cb :got_volume, MPD::VOLUME_CALLBACK do |vol|
    @widgets.volume_scale.value = vol
    schedule(:got_volume) {}
  end

  def_cb :got_random, MPD::RANDOM_CALLBACK do |random|
    @widgets.random_btn.active = random
  end

  def_cb :got_repeat, MPD::REPEAT_CALLBACK do |repeat|
    @widgets.repeat_btn.active = repeat
  end
end
